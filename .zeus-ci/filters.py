"""Build-time conversion only: no third-party converter code is linked into ZEUS."""
import hashlib
import gzip
import json
import os
import platform
import shutil
from pathlib import Path
import subprocess
import tempfile
import urllib.request

VERSION = '4.3.1'
SOURCE_SHA = '1cfdcaf042880a5e0027a8fc6f7ebf9ee667acc9'
DIGEST = '2a02d7fc6adc74198b0572cd7012d0371e608c2330969210c3dc53ecca47d865'
SOURCES = ['https://easylist-downloads.adblockplus.org/easylist.txt', 'https://easylist-downloads.adblockplus.org/easyprivacy.txt']
resources = Path('ZEUSNext/Resources')
work = Path(tempfile.mkdtemp(prefix='zeus-filters-'))

def fetch(url, maximum):
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('Input exceeds the conversion size limit')
    return data

cache = Path.home() / '.cache' / 'zeus-filter-converter' / SOURCE_SHA / platform.machine()
cache.mkdir(parents=True, exist_ok=True)
tool = cache / 'ConverterTool'
# SwiftPM-generated executables locate the PublicSuffixList bundle beside the
# executable. Cache the bundle as well as the binary or the converter traps.
bundle = cache / 'swift-psl_PublicSuffixList.bundle'
needs_build = not tool.is_file() or (platform.machine() != 'arm64' and not bundle.is_dir())
if needs_build:
    if platform.machine() == 'arm64':
        binary = fetch(f'https://github.com/AdguardTeam/SafariConverterLib/releases/download/v{VERSION}/ConverterTool', 8_000_000)
        assert hashlib.sha256(binary).hexdigest() == DIGEST, 'Converter checksum mismatch'
        tool.write_bytes(binary)
        tool.chmod(0o700)
    else:
        source = work / 'converter-source'
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', 'v' + VERSION, 'https://github.com/AdguardTeam/SafariConverterLib.git', str(source)], check=True)
        actual_sha = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        assert actual_sha == SOURCE_SHA, 'Converter source revision mismatch'
        subprocess.run(['swift', 'build', '--package-path', str(source), '-c', 'release', '--product', 'ConverterTool'], check=True, timeout=1200)
        built = source / '.build' / 'release' / 'ConverterTool'
        tool.write_bytes(built.read_bytes())
        tool.chmod(0o700)
        bundles = list((source / '.build').rglob('swift-psl_PublicSuffixList.bundle'))
        assert bundles, 'SwiftPM PublicSuffixList resource bundle missing after build'
        shutil.copytree(bundles[0], bundle, dirs_exist_ok=True)
if platform.machine() != 'arm64':
    assert bundle.is_dir(), 'Missing PublicSuffixList bundle beside cached ConverterTool'
actual_digest = hashlib.sha256(tool.read_bytes()).hexdigest()
rules = []
source_hashes = {}
for entry in json.loads(Path('.zeus-ci/filter-sources/sources.json').read_text()):
    data = gzip.decompress(Path('.zeus-ci/filter-sources', entry['name'] + '.txt.gz').read_bytes())
    assert hashlib.sha256(data).hexdigest() == entry['sha256'], 'Filter snapshot checksum mismatch'
    source_hashes[entry['source']] = entry['sha256']
    rules.append(data.decode('utf-8'))
inputs = work / 'rules.txt'
inputs.write_text('\n'.join(rules), encoding='utf-8')
output = resources / 'safari-rules.json'
subprocess.run([str(tool), 'convert', '--input-path', str(inputs), '--safari-version', '18', '--advanced-blocking', 'false', '--safari-rules-json-path', str(output)], check=True)
parsed = json.loads(output.read_text())
assert isinstance(parsed, list) and 1_000 < len(parsed) < 149_000
assert all(row.get('action', {}).get('type') in ['block', 'block-cookies', 'css-display-none', 'ignore-previous-rules', 'make-https'] for row in parsed)
metadata = {'converter': f'AdguardTeam/SafariConverterLib v{VERSION}', 'converter_sha256': actual_digest, 'converter_source_sha': SOURCE_SHA, 'source_hashes': source_hashes, 'rules': len(parsed), 'advanced_scriptlets': False, 'safari_version': 18}
(resources / 'filter-metadata.json').write_text(json.dumps(metadata, indent=2))
Path('results/filter-metadata.json').write_text(json.dumps(metadata, indent=2))
# Retain the original filter licenses and notices together with every distributed build.
(resources / 'FILTER-NOTICES.txt').write_text('Build-time converter: https://github.com/AdguardTeam/SafariConverterLib (GPL-3.0). The converter is not linked into the app.\nFiltering lists: EasyList and EasyPrivacy, GPL-3.0 / CC BY-SA as stated in their headers. Sources and hashes: filter-metadata.json.\nOnly rules representable by Safari content blocking are included; no scriptlets are executed.\n\n' + '\n\n'.join('\n'.join(line for line in text.splitlines()[:40] if line.startswith('!')) for text in rules))
print(json.dumps(metadata))
