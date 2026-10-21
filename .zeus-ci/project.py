import json
from pathlib import Path

settings = {
    'PRODUCT_BUNDLE_IDENTIFIER': 'tools.rea.ZEUSBrowserAnalysis',
    'SWIFT_VERSION': '5.0', 'SWIFT_STRICT_CONCURRENCY': 'minimal',
    'GENERATE_INFOPLIST_FILE': 'YES', 'CODE_SIGNING_ALLOWED': 'NO',
    'CODE_SIGNING_REQUIRED': 'NO', 'TARGETED_DEVICE_FAMILY': '1,2',
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
    'MARKETING_VERSION': '2.2.1', 'CURRENT_PROJECT_VERSION': '6',
    'CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]': '.zeus-ci/Simulator.entitlements',
}
spec = {
    'name': 'ZEUSNext', 'options': {'deploymentTarget': {'iOS': '18.1'}, 'developmentLanguage': 'ar'},
    'settings': {'base': {'SWIFT_VERSION': '5.0', 'CODE_SIGNING_ALLOWED': 'NO'}},
    'targets': {
        'ZEUSNext': {
            'type': 'application', 'platform': 'iOS', 'sources': [{'path': 'ZEUSNext', 'excludes': ['Resources/safari-rules.json', 'Resources/filter-metadata.json']}],
            'settings': {'base': settings},
            'info': {'path': '.zeus-ci/Generated-Info.plist', 'properties': {
                'CFBundleDisplayName': 'ZEUS', 'UILaunchScreen': {},
                'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
                'NSLocalNetworkUsageDescription': 'نقل نسخة الحساب عبر Wi-Fi بين أجهزتك عند تشغيلك المشاركة المحلية.',
                'NSFaceIDUsageDescription': 'حماية المساحات التي تختار قفلها ببصمة الوجه.',
                'NSCameraUsageDescription': 'التقاط صورة للبروفايل أو استخدام الكاميرا في موقع تختاره.',
                'NSMicrophoneUsageDescription': 'استخدام الميكروفون عند طلبك من موقع داخل المتصفح.',
                'NSPhotoLibraryUsageDescription': 'اختيار صورة للبروفايل أو رفع صور إلى الموقع الذي تستخدمه.',
                'NSPhotoLibraryAddUsageDescription': 'إضافة الصور التي تختار حفظها إلى ألبوم الجهاز.',
                'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
                'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
                'UIApplicationSupportsIndirectInputEvents': True,
            }},
        },
        'ZEUSNextTests': {
            'type': 'bundle.unit-test', 'platform': 'iOS', 'sources': ['ZEUSNextTests'],
            'dependencies': [{'target': 'ZEUSNext'}],
            'settings': {'base': {'GENERATE_INFOPLIST_FILE': 'YES', 'PRODUCT_BUNDLE_IDENTIFIER': 'tools.zeus.tests', 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/ZEUSNext.app/ZEUSNext', 'BUNDLE_LOADER': '$(TEST_HOST)'}},
        },
        'ZEUSNextUITests': {
            'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': ['ZEUSNextUITests'],
            'dependencies': [{'target': 'ZEUSNext'}],
            'settings': {'base': {'GENERATE_INFOPLIST_FILE': 'YES', 'PRODUCT_BUNDLE_IDENTIFIER': 'tools.zeus.uitests', 'TEST_TARGET_NAME': 'ZEUSNext'}},
        },
    },
    'schemes': {'ZEUSNext': {'build': {'targets': {'ZEUSNext': 'all'}}, 'test': {'targets': ['ZEUSNextTests', 'ZEUSNextUITests'], 'gatherCoverageData': False}}},
}
Path('zeus-project.json').write_text(json.dumps(spec, ensure_ascii=False, indent=2))
