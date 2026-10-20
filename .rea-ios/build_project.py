"""Generate a build harness for the unchanged Swift Playgrounds sources."""
import json
from pathlib import Path
import sys

work = Path(sys.argv[1]).resolve()
spec = {
    'name': 'ZEUSAnalysis',
    'options': {'deploymentTarget': {'iOS': '18.1'}},
    'packages': {'Kingfisher': {'url': 'https://github.com/onevcat/Kingfisher', 'exactVersion': '8.6.2'}},
    'targets': {'ZEUSBrowser': {
        'type': 'application', 'platform': 'iOS',
        'sources': [{'path': 'Source', 'excludes': ['Package.swift', 'Package.resolved', '.swiftpm']}],
        'dependencies': [{'package': 'Kingfisher'}],
        'settings': {'base': {
            'PRODUCT_BUNDLE_IDENTIFIER': 'tools.rea.ZEUSBrowserAnalysis',
            'SWIFT_VERSION': '5.0', 'GENERATE_INFOPLIST_FILE': 'YES',
            'INFOPLIST_KEY_CFBundleDisplayName': 'ZEUS Browser',
            'INFOPLIST_KEY_NSUserTrackingUsageDescription': 'نحتاج إلى هذا الإذن لتقديم تجربة مخصصة وتحسين أداء خدمات Firebase،  google studio.',
            'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
            'TARGETED_DEVICE_FAMILY': '1,2', 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
            'CODE_SIGNING_ALLOWED': 'NO', 'CODE_SIGNING_REQUIRED': 'NO',
            'STRIP_INSTALLED_PRODUCT': 'NO', 'COPY_PHASE_STRIP': 'NO',
            'STRIP_STYLE': 'non-global', 'DEAD_CODE_STRIPPING': 'NO',
        }},
    }},
}
(work / 'project.json').write_text(json.dumps(spec, ensure_ascii=False, indent=2))
