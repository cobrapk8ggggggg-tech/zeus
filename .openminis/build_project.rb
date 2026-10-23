# Keep the original app target, resources, native code, provider dependencies,
# build scripts and extension targets. Add the browser as a separate Swift module.
require 'xcodeproj'
require 'pathname'
require 'json'
require 'fileutils'

native = Pathname.new(ARGV.fetch(0)).realpath
browser = Pathname.new(ARGV.fetch(1)).realpath
project = Xcodeproj::Project.open(native + 'src/ios/Minis.xcodeproj')
app = project.targets.find { |target| target.name == 'Minis' }
raise 'Original app target missing' unless app
raise 'Already embedded' if project.targets.any? { |target| target.name == 'ZEUSBrowser' }
target = project.new_target(:static_library, 'ZEUSBrowser', :ios, '18.1')
group = project.main_group.new_group('ZEUS Browser Source')
files = Dir.glob((browser + 'ZEUSNext/**/*.swift').to_s).reject do |path|
  path.include?('/OpenMinis/') || %w[BrowserAgent.swift BrowserAgentTransport.swift ZEUSNextApp.swift].include?(File.basename(path))
end
files += Dir.glob((browser + '.openminis/build/*.swift').to_s)
files.each { |path| target.source_build_phase.add_file_reference(group.new_file(path)) }
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_MODULE_NAME' => 'ZEUSBrowser', 'DEFINES_MODULE' => 'YES',
    'SWIFT_VERSION' => '5.0', 'SWIFT_STRICT_CONCURRENCY' => 'minimal',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) ZEUS_NATIVE_HOST',
    'SWIFT_ENABLE_BARE_SLASH_REGEX' => 'YES', 'ENABLE_TESTABILITY' => 'YES',
    'CODE_SIGNING_ALLOWED' => 'NO', 'GENERATE_INFOPLIST_FILE' => 'YES'
  })
end
app.add_dependency(target)
app.frameworks_build_phase.add_file_reference(target.product_reference)
bridge = project.main_group.new_file((native + 'src/ios/ZEUSNativeIntegration.swift').to_s)
app.source_build_phase.add_file_reference(bridge)

# Browser resources are resolved by Bundle.main from inside the static module.
Dir.glob((browser + 'ZEUSNext/Resources/*').to_s).each do |path|
  next if %w[safari-rules.json filter-metadata.json Assets.xcassets].include?(File.basename(path))
  app.resources_build_phase.add_file_reference(group.new_file(path))
end

# Keep native visual assets; use the browser's application icon for its identity.
icons = browser + '.openminis/build/NativeAssets.xcassets'
FileUtils.rm_rf(icons)
FileUtils.cp_r(native + 'src/ios/Assets.xcassets', icons)
Dir.glob((browser + 'ZEUSNext/Resources/Assets.xcassets/*').to_s).each do |path|
  destination = icons + File.basename(path)
  FileUtils.cp_r(path, destination) unless destination.exist?
end
FileUtils.rm_rf(icons + 'AppIcon.appiconset')
FileUtils.cp_r(browser + 'ZEUSNext/Resources/Assets.xcassets/AppIcon.appiconset', icons + 'AppIcon.appiconset')
original_assets = project.files.find { |ref| ref.path == 'Assets.xcassets' }
raise 'Original asset catalog missing' unless original_assets
original_assets.path = icons.to_s
original_assets.source_tree = '<absolute>'

app.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'tools.rea.ZEUSBrowserAnalysis'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.1'
  config.build_settings['MARKETING_VERSION'] = '2.7.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '11'
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'ZEUS'
end
project.targets.each do |other|
  next unless other.product_type == 'com.apple.product-type.app-extension'
  other.build_configurations.each do |config|
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'tools.rea.ZEUSBrowserAnalysis.' + other.name
  end
end
tests = project.new_target(:unit_test_bundle, 'ZEUSBrowserIntegrationTests', :ios, '26.2')
tests.add_dependency(app)
tests.add_dependency(target)
tests.frameworks_build_phase.add_file_reference(target.product_reference)
tests.source_build_phase.add_file_reference(group.new_file((browser + '.openminis/Host/NativeBrowserIntegrationTests.swift').to_s))
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'tools.zeus.native.tests',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/Minis.app/Minis',
    'BUNDLE_LOADER' => '$(TEST_HOST)', 'CODE_SIGNING_ALLOWED' => 'NO',
    'SWIFT_ENABLE_BARE_SLASH_REGEX' => 'YES'
  })
end
scheme_path = native + 'src/ios/Minis.xcodeproj/xcshareddata/xcschemes/Minis.xcscheme'
scheme = Xcodeproj::XCScheme.new(scheme_path)
scheme.add_test_target(tests)
scheme.save_as(native + 'src/ios/Minis.xcodeproj', 'Minis', true)
project.save

# Display name and file import/sharing capabilities of the browser.
plist = native + 'src/ios/Info.plist'
info = Xcodeproj::Plist.read_from_path(plist)
info['CFBundleDisplayName'] = 'ZEUS'
info['UIFileSharingEnabled'] = true
info['LSSupportsOpeningDocumentsInPlace'] = true
info['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads' => true}
Xcodeproj::Plist.write_to_path(info, plist)
puts "Original native app retained; browser module contains #{files.length} Swift source files."
