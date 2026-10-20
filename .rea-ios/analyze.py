"""REA source and compiled-artifact investigations, with explicit provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import textwrap

from mcp_transport import MCP


def native_selectors(binary):
    """Read original thin Mach-O entry/symbol addresses, without executing it."""
    data = binary.read_bytes()
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a little-endian 64-bit Mach-O analysis build')
    count = struct.unpack_from('<I', data, 16)[0]
    offset, entry, symbols, segments = 32, None, None, []
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Invalid Mach-O load command')
        if command == 0x80000028:
            entry = struct.unpack_from('<Q', data, offset + 8)[0]
        elif command == 0x19:
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, offset + 24)
            segments.append((vmaddr, fileoff, filesize))
        elif command == 2:
            symbols = struct.unpack_from('<IIII', data, offset + 8)
        offset += size
    targets = []
    if entry is not None:
        for vmaddr, fileoff, filesize in segments:
            if fileoff <= entry < fileoff + filesize:
                targets.append({'name': 'LC_MAIN entry', 'address': hex(vmaddr + entry - fileoff)})
                break
    wanted = ['performSearch', 'createContentBlockerRules', 'syncCookiesToWebView']
    if symbols:
        symoff, nsyms, stroff, strsize = symbols
        for index in range(nsyms):
            strx, kind, section, desc, value = struct.unpack_from('<IBBHQ', data, symoff + 16 * index)
            if not (kind & 0xe) == 0xe or not value or strx >= strsize:
                continue
            end = data.find(b'\0', stroff + strx, stroff + strsize)
            if end == -1:
                continue
            name = data[stroff + strx:end].decode('utf-8', errors='replace')
            for marker in list(wanted):
                if marker in name:
                    targets.append({'name': name, 'address': hex(value)})
                    wanted.remove(marker)
    if not targets:
        raise ValueError('No file-backed entry or selected Swift symbol found')
    return targets


def source_analysis(client, archive, work):
    client.call('open_binary', {'path': str(archive.resolve())})
    inventory = client.call('inspect_artifact')
    extraction = client.call('extract_artifact')['normalized_result']
    extracted = Path(extraction['output_root'])
    for item in extraction['artifacts']:
        data = (extracted / item['relative_path']).read_bytes()
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise RuntimeError('Extracted artifact hash mismatch: ' + item['relative_path'])
    project = work / 'Source'
    shutil.copytree(extracted / 'ZEUS Browser.swiftpm', project)
    for number, path in enumerate(sorted(project.rglob('*.plist'))):
        client.call('inspect_plist', {'path': str(path.resolve())}, label=f'original-plist-{number}')
    js = work / 'embedded-javascript'
    js.mkdir()
    mapping = []
    escapes = {'\\': '\\', '"': '"', 'n': '\n', 'r': '\r', 't': '\t', '0': '\x00'}
    for path in sorted(project.glob('*.swift')):
        content = path.read_text()
        for index, match in enumerate(re.finditer(r'"""(.*?)"""', content, re.S), 1):
            raw = match.group(1)
            row = {'source': path.name, 'start_line': content[:match.start(1)].count('\n') + 1,
                   'end_line': content[:match.end(1)].count('\n') + 1,
                   'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            if '\\(' in raw or any(m.group(1) not in escapes for m in re.finditer(r'\\(.)', raw, re.S)):
                row['status'] = 'excluded-dynamic-interpolation-or-unsupported-escape'
            else:
                body = re.sub(r'\\([\\"nrt0])', lambda m: escapes[m.group(1)], textwrap.dedent(raw).strip('\n'))
                target = js / f'{path.stem.strip()}-{index}.js'
                target.write_text(body + '\n')
                row.update({'status': 'prepared-static-excerpt', 'output': target.name,
                            'output_sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
            mapping.append(row)
    client.save('source-map', mapping)
    analysis = client.call('analyze_javascript_application', {'input_path': str(js.resolve()), 'detail': 'summary'})
    client.call('trace_application_feature', {
        'application': {'kind': 'retained-evidence', 'evidence_id': analysis['normalized_result']['parent_evidence_id']},
        'seed': {'kind': 'module', 'value': 'ReaderFeature-1.js', 'match': 'exact'},
        'direction': 'both',
    })
    client.save('source-provenance', {
        'repository': 'cobrapk8ggg-netizen/Ios',
        'commit': '0542beb72680458cac6fcf365c1247324b4b2402',
        'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'extracted_files': len(extraction['artifacts']),
        'build_method': 'Original Swift sources with a generated XcodeGen project; original Package.swift retained but not compiled.',
    })


def native_analysis(client, binary, deep):
    arguments = {'path': str(binary.resolve())}
    if deep:
        arguments['provider_id'] = 'ghidra'
    client.call('open_binary', arguments)
    client.call('binary_session', label='active-session')
    if deep:
        client.call('binary_overview')
        targets = native_selectors(binary)
        client.save('selected-native-addresses', targets)
        for number, target in enumerate(targets):
            client.call('analyze_function', {'procedure': target['address']},
                        label=f'function-{number}', optional=number > 0)
    else:
        client.call('inspect_artifact', {'detail': 'summary'})
        client.call('inspect_plist', {'path': str((binary / 'Info.plist').resolve())})
        client.call('inspect_macho', {'detail': 'summary'})
        client.call('inspect_signature', optional=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['source', 'metadata', 'deep'])
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    client = MCP(args.output)
    try:
        client.call('binary_session', label='initial-session')
        if args.mode == 'source':
            args.work.mkdir(parents=True, exist_ok=True)
            source_analysis(client, args.target, args.work)
        else:
            native_analysis(client, args.target, args.mode == 'deep')
        client.export()
        client.call('close_binary')
    except Exception:
        try:
            client.export()
        except Exception:
            pass
        raise
    finally:
        client.close()


if __name__ == '__main__':
    main()
