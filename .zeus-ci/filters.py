"""Build-time conversion only: no third-party converter code is linked into ZEUS."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

VERSION = '4.3.1'
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

binary = fetch(f'https://github.com/AdguardTeam/SafariConverterLib/releases/download/v{VERSION}/ConverterTool', 8_000_000)
assert hashlib.sha256(binary).hexdigest() == DIGEST, 'Converter checksum mismatch'
tool = work / 'ConverterTool'
tool.write_bytes(binary)
tool.chmod(0o700)
rules = []
source_hashes = {}
for url in SOURCES:
    data = fetch(url, 12_000_000)
    source_hashes[url] = hashlib.sha256(data).hexdigest()
    rules.append(data.decode('utf-8'))
inputs = work / 'rules.txt'
inputs.write_text('\n'.join(rules), encoding='utf-8')
output = resources / 'safari-rules.json'
subprocess.run([str(tool), 'convert', '--input-path', str(inputs), '--safari-version', '18', '--advanced-blocking', 'false', '--safari-rules-json-path', str(output)], check=True)
parsed = json.loads(output.read_text())
assert isinstance(parsed, list) and 1_000 < len(parsed) < 149_000
assert all(row.get('action', {}).get('type') in ['block', 'block-cookies', 'css-display-none', 'ignore-previous-rules', 'make-https'] for row in parsed)
metadata = {'converter': f'AdguardTeam/SafariConverterLib v{VERSION}', 'converter_sha256': DIGEST, 'source_hashes': source_hashes, 'rules': len(parsed), 'advanced_scriptlets': False, 'safari_version': 18}
(resources / 'filter-metadata.json').write_text(json.dumps(metadata, indent=2))
Path('results/filter-metadata.json').write_text(json.dumps(metadata, indent=2))
# Retain the original filter licenses and notices together with every distributed build.
(resources / 'FILTER-NOTICES.txt').write_text('Build-time converter: https://github.com/AdguardTeam/SafariConverterLib (GPL-3.0). The converter is not linked into the app.\nFiltering lists: EasyList and EasyPrivacy, GPL-3.0 / CC BY-SA as stated in their headers. Sources and hashes: filter-metadata.json.\nOnly rules representable by Safari content blocking are included; no scriptlets are executed.\n\n' + '\n\n'.join('\n'.join(line for line in text.splitlines()[:40] if line.startswith('!')) for text in rules))
print(json.dumps(metadata))
