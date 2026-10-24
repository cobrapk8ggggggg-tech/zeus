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
target.product_name = 'ZEUSBrowser'
target.product_reference.path = 'libZEUSBrowser.a'
group = project.main_group.new_group('ZEUS Browser Source')
files = Dir.glob((browser + 'ZEUSNext/**/*.swift').to_s).reject do |path|
  Pathname.new(path).relative_path_from(browser + 'ZEUSNext').to_s.start_with?('OpenMinis/') || %w[BrowserAgent.swift BrowserAgentTransport.swift ZEUSNextApp.swift].include?(File.basename(path))
end
raise 'Browser source inventory unexpectedly empty' if files.length < 40
files += Dir.glob((browser + '.openminis/build/*.swift').to_s)
files.each { |path| target.source_build_phase.add_file_reference(group.new_file(path)) }
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_MODULE_NAME' => 'ZEUSBrowser', 'PRODUCT_NAME' => 'ZEUSBrowser', 'DEFINES_MODULE' => 'YES',
    'SWIFT_VERSION' => '5.0', 'SWIFT_STRICT_CONCURRENCY' => 'minimal',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) ZEUS_NATIVE_HOST',
    'SWIFT_ENABLE_BARE_SLASH_REGEX' => 'YES', 'ENABLE_TESTABILITY' => 'YES',
    'CODE_SIGNING_ALLOWED' => 'NO', 'GENERATE_INFOPLIST_FILE' => 'YES'
  })
end
app.add_dependency(target)
app.frameworks_build_phase.add_file_reference(target.product_reference)
# Strip the actual binaries/dependency graph, not just visible media buttons.
project.targets.each do |item|
  [item.source_build_phase, item.resources_build_phase, item.frameworks_build_phase, *item.copy_files_build_phases].each do |phase|
    phase.files.to_a.each do |build_file|
      path = build_file.file_ref&.path.to_s
      product = build_file.respond_to?(:product_ref) ? build_file.product_ref&.product_name.to_s : ''
      if path.match?(/(?:FFmpegOffload\.m|FFmpeg\.framework|libav\w*\.framework|libsw\w*\.framework|jieba\.dict\.utf8|hmm_model\.utf8)$/) || product == 'RealTimeCutVADLibrary'
        phase.remove_build_file(build_file)
      end
    end
  end
  item.package_product_dependencies.to_a.each do |dependency|
    dependency.remove_from_project if dependency.product_name == 'RealTimeCutVADLibrary'
  end
  item.build_configurations.each do |config|
    config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
    config.build_settings['INFOPLIST_KEY_CFBundleDevelopmentRegion'] = 'ar'
    config.build_settings['LD_GENERATE_MAP_FILE'] = 'YES'
    config.build_settings['LD_MAP_FILE_PATH'] = '$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-LinkMap-$(CURRENT_ARCH).txt'
  end
end
%w[ZEUSNativeIntegration.swift ZeusToolPermissions.swift ZeusDefaultSkills.swift ZeusAgentSchemas.swift ZeusPatch.swift ZeusAgentHarness.swift ZeusConnections.swift ZeusGitHubAuthorization.swift ZeusProjectContract.swift ZeusGitHubTools.swift ZeusStorageExplorer.swift ZeusTaskDashboard.swift].each do |name|
  bridge = project.main_group.new_file((native + 'src/ios' + name).to_s)
  app.source_build_phase.add_file_reference(bridge)
end

skills = project.main_group.new_file((browser + '.openminis/ZEUSDefaultSkills').to_s)
skills.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(skills)

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

simulator_entitlements = native + 'src/ios/ZeusSimulator.entitlements'
Xcodeproj::Plist.write_to_path({
  'application-identifier' => 'tools.rea.ZEUSBrowserAnalysis',
  'keychain-access-groups' => ['tools.rea.ZEUSBrowserAnalysis']
}, simulator_entitlements)
app.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = 'ZeusSimulator.entitlements'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'tools.rea.ZEUSBrowserAnalysis'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.1'
  config.build_settings['MARKETING_VERSION'] = '3.1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '26'
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'ZEUS'
end
# A device `build` (unlike archive/install) did not strip the original app's
# 49 MB symbol-name table. Keep debug symbols in the separate dSYM, not the IPA.
([app, target] + project.targets.select { |item| item.product_type == 'com.apple.product-type.app-extension' }).each do |item|
  item.build_configurations.select { |config| config.name == 'Release' }.each do |config|
    config.build_settings.merge!({
      'SWIFT_OPTIMIZATION_LEVEL' => '-Osize', 'GCC_OPTIMIZATION_LEVEL' => 's',
      'DEAD_CODE_STRIPPING' => 'YES', 'COPY_PHASE_STRIP' => 'YES',
      'STRIP_INSTALLED_PRODUCT' => 'YES', 'STRIP_STYLE' => 'all',
      'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
      'CLANG_ENABLE_CODE_COVERAGE' => 'NO', 'GCC_GENERATE_TEST_COVERAGE_FILES' => 'NO',
      'GCC_INSTRUMENT_PROGRAM_FLOW_ARCS' => 'NO', 'ENABLE_TESTABILITY' => 'NO'
    })
  end
end
project.targets.each do |other|
  next unless other.product_type == 'com.apple.product-type.app-extension'
  other.build_configurations.each do |config|
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'tools.rea.ZEUSBrowserAnalysis.' + other.name
  end
end
tests = project.new_target(:unit_test_bundle, 'ZEUSBrowserIntegrationTests', :ios, '26.2')
tests.product_name = 'ZEUSBrowserIntegrationTests'
tests.product_reference.path = 'ZEUSBrowserIntegrationTests.xctest'
tests.add_dependency(app)
tests.add_dependency(target)
tests.frameworks_build_phase.add_file_reference(target.product_reference)
tests.source_build_phase.add_file_reference(group.new_file((browser + '.openminis/Host/NativeBrowserIntegrationTests.swift').to_s))
tests.source_build_phase.add_file_reference(group.new_file((browser + '.openminis/Host/NativeProjectContractTests.swift').to_s))
tests.build_configurations.each do |config|
  app_config = app.build_configurations.find { |candidate| candidate.name == config.name }
  %w[HEADER_SEARCH_PATHS FRAMEWORK_SEARCH_PATHS LIBRARY_SEARCH_PATHS].each do |key|
    config.build_settings[key] = app_config.build_settings[key] if app_config.build_settings[key]
  end
  config.build_settings.merge!({
    'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'tools.zeus.native.tests',
    'PRODUCT_NAME' => 'ZEUSBrowserIntegrationTests', 'PRODUCT_MODULE_NAME' => 'ZEUSBrowserIntegrationTests',
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
