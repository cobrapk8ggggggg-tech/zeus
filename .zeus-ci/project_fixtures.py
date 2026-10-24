"""Local HTTP fixtures for native GitHub REST/Actions contract verification."""
import json
import io
import struct
import zlib
import zipfile
import base64
import hashlib
from threading import Lock
from urllib.parse import urlparse, parse_qs

RECORDS = []
LOCK = Lock()
SHA = '1' * 40
BLOBS = {}
SOURCES = {}


def screenshot_zip():
    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)
    pixels = b''.join(b'\0' + bytes([12, 110, 220, 255]) * 32 for _ in range(32))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive: archive.writestr('home.png', png)
    return data.getvalue()


def github_response(handler, method, body=None):
    parsed = urlparse(handler.path)
    if not parsed.path.startswith('/github-rest-fixture/'):
        return False
    path = parsed.path[len('/github-rest-fixture'):]
    token = handler.headers.get('Authorization', '')
    if path.startswith('/download/'):
        data = ((b'Build log header\n' + b'ordinary compiler output\n' * 3000 + b'FINAL_COMPILER_ERROR: fix App.swift line 12') if path.endswith('large.log') else (b'Build failed: App.swift:12: missing symbol\nRepair the source and rerun the workflow.' if path.endswith('.log') else screenshot_zip())) if not token else b'Credentials must not be forwarded to the download'
        handler.send_response(200 if not token else 400)
        handler.send_header('Content-Type', 'application/zip'); handler.send_header('Content-Length', str(len(data))); handler.end_headers()
        handler.wfile.write(data)
        return True
    status, result, headers = 200, {}, {}
    if token not in ['Bearer fixture-first', 'Bearer fixture-second']:
        status, result = 401, {'message': 'Fixture account authorization missing'}
    else:
        with LOCK:
            RECORDS.append({'method': method, 'path': path, 'body': body, 'account': token.rsplit('-', 1)[-1]})
        parts = path.strip('/').split('/')
        repo = '/'.join(parts[1:3]) if len(parts) >= 3 and parts[0] == 'repos' else ''
        if path == '/user':
            result = {'login': 'fixture-owner' if token.endswith('first') else 'other-owner'}
        elif path == '/denied':
            status, result = 403, {'message': 'Resource not accessible with this account permission'}
        elif path == '/redirect':
            status, headers = 302, {'Location': 'https://untrusted.example/private-log'}
        elif path == '/requests':
            with LOCK: result = {'requests': list(RECORDS)}
        elif method == 'POST' and path == '/user/repos':
            status, result = 201, {'id': 100, 'full_name': 'fixture-owner/' + body.get('name', '')}
        elif method == 'GET' and '/contents/' in path:
            source = SOURCES.get((repo, path.split('/contents/', 1)[1]), '')
            result = {'type': 'file', 'encoding': 'base64', 'sha': SHA, 'content': base64.b64encode(source.encode()).decode()}
        elif method == 'GET' and '/git/trees/' in path:
            result = {'sha': 'a' * 40, 'truncated': False, 'tree': [
                {'path': 'AGENTS.md', 'type': 'blob', 'sha': 'b' * 40, 'size': 100},
                {'path': 'Package.swift', 'type': 'blob', 'sha': 'c' * 40, 'size': 200},
                {'path': 'Sources', 'type': 'tree', 'sha': 'd' * 40}]}
        elif method == 'GET' and '/compare/' in path:
            result = {'status': 'ahead', 'files': [{'filename': 'Sources/App.swift', 'status': 'modified', 'additions': 2, 'deletions': 1, 'patch': '+' + 'real-source-change' * 100}]}
        elif method == 'POST' and path.endswith('/git/blobs'):
            if body.get('encoding') != 'utf-8':
                status, result = 400, {'message': 'Source commits must use native plain UTF-8 text'}
            else:
                digest = hashlib.sha1(body['content'].encode()).hexdigest()
                BLOBS[digest] = body['content']; result = {'sha': digest}
        elif method == 'POST' and path.endswith('/git/trees'):
            for item in body['tree']:
                if 'content' in item:
                    assert 'sha' not in item, 'Git tree content and sha are mutually exclusive'
                    SOURCES[(repo, item['path'])] = item['content']
                elif item.get('sha') is None: SOURCES.pop((repo, item['path']), None)
                else: SOURCES[(repo, item['path'])] = BLOBS[item['sha']]
            result = {'sha': 'fixture-tree'}
        elif method == 'POST' and path.endswith('/git/commits'):
            result = {'sha': SHA}
        elif method == 'GET' and '/git/commits/' in path:
            result = {'sha': SHA, 'tree': {'sha': 'fixture-base-tree'}}
        elif method == 'PATCH' and '/git/refs/heads/' in path:
            if body.get('force') is not False:
                status, result = 400, {'message': 'Never force the fixture ref'}
            else: result = {'object': {'sha': SHA}}
        elif method == 'PUT' and '/contents/' in path:
            status, result = 201, {'content': {'path': path.split('/contents/', 1)[1], 'sha': SHA}, 'commit': {'sha': SHA}}
        elif method == 'POST' and path.endswith('/git/refs'):
            status, result = 201, {'ref': body.get('ref'), 'object': {'sha': SHA}}
        elif method == 'POST' and path.endswith('/dispatches'):
            status = 204
        elif '/actions/jobs/' in path and path.endswith('/logs'):
            status, headers = 302, {'Location': 'http://' + handler.headers['Host'] + '/github-rest-fixture/download/' + ('large.log' if '/124/' in path else 'job.log')}
        elif '/git/ref/heads/' in path:
            result = {'ref': 'refs/heads/feature/project', 'object': {'sha': '2' * 40 if repo.endswith('/stale') else SHA}}
        elif '/actions/artifacts/' in path:
            suffix = path.split('/actions/artifacts/', 1)[1].split('/')
            artifact_id = int(suffix[0])
            if len(suffix) > 1 and suffix[1] == 'zip':
                status, headers = 302, {'Location': 'http://' + handler.headers['Host'] + '/github-rest-fixture/download/' + str(artifact_id) + '.zip'}
            else:
                result = {'id': artifact_id, 'name': 'ui-screenshots' if artifact_id == 2 else 'app-bundle', 'size_in_bytes': len(screenshot_zip()), 'expired': False,
                          'workflow_run': {'id': 42, 'head_sha': SHA, 'head_branch': 'feature/project'}}
        elif '/actions/runs/' in path:
            suffix = path.split('/actions/runs/', 1)[1].split('/')
            run = int(suffix[0])
            if len(suffix) == 1:
                result = {'id': run, 'repository': {'full_name': repo}, 'head_sha': '2' * 40 if run == 43 else SHA,
                          'head_branch': 'feature/project', 'path': '.github/workflows/wrong.yml' if run == 45 else '.github/workflows/ci.yml',
                          'status': 'completed', 'conclusion': 'failure' if run == 44 else 'success'}
            elif suffix[1] == 'jobs':
                result = {'jobs': [{'name': 'verify', 'conclusion': 'success', 'steps': [
                    {'name': 'Build app', 'conclusion': 'success'}, {'name': 'Test features', 'conclusion': 'success'},
                    {'name': 'Review screenshots', 'conclusion': 'skipped' if run == 47 else 'success'}]}]}
            elif suffix[1] == 'artifacts':
                artifacts = [{'id': 1, 'name': 'app-bundle', 'size_in_bytes': 1000, 'expired': False}, {'id': 2, 'name': 'ui-screenshots', 'size_in_bytes': 500, 'expired': False}]
                result = {'artifacts': artifacts[1:] if run == 48 else artifacts}
            else:
                status, result = 404, {'message': 'Unknown fixture run endpoint'}
        elif repo:
            result = {'full_name': repo, 'default_branch': 'main', 'permissions': {'push': True}}
        else:
            status, result = 404, {'message': 'Unknown fixture API path'}
    data = b'' if status == 204 else json.dumps(result).encode()
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Content-Length', str(len(data)))
    for name, value in headers.items(): handler.send_header(name, value)
    handler.end_headers()
    if method != 'HEAD': handler.wfile.write(data)
    return True


def backend_proposal(model, check):
    return {'title': 'Native project fixture ' + model[-8:], 'objective': 'Create, test, repair and verify actual project files',
            'platform': 'backend', 'features': [{'id': 'file-value', 'title': 'Project stores and verifies the correct value'}],
            'architecture': ['value.txt: project value', 'README.md: project description'], 'steps': ['Implement and verify'],
            'checks': [{'id': 'build', 'title': 'Project files exist', 'kind': 'build', 'covers': [], 'command': 'test -s README.md'},
                       {'id': 'value', 'title': 'Actual value is correct', 'kind': 'functional', 'covers': ['file-value'], 'command': check}],
            'deliverables': ['Verified project files'], 'assumptions': ['Small local acceptance fixture'], 'build_route': 'local'}
