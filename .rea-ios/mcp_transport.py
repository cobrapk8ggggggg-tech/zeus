"""Dependency-free stdio MCP transport; does not execute the analysis target."""
import json
from pathlib import Path
import queue
import subprocess
import threading
import time


class MCP:
    def __init__(self, output):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.log = (self.output / 'server.stderr.log').open('w')
        server = Path(__file__).parent / 'runtime/node_modules/rea-agents/scripts/rea.mjs'
        self.process = subprocess.Popen(
            ['node', str(server.resolve()), 'mcp'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1,
        )
        self.messages = queue.Queue()
        self.transcript = []
        self.sequence = 0
        threading.Thread(target=self._read, daemon=True).start()
        identity = self.request('initialize', {
            'protocolVersion': '2025-11-25', 'capabilities': {},
            'clientInfo': {'name': 'zeus-ios-macos-analysis', 'version': '1.0.0'},
        })
        self.save('identity', identity)
        self.request('notifications/initialized', notification=True)

    def _read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                self.messages.put({'unexpected_stdout': line})
        self.messages.put({'eof': True})

    def save(self, label, data):
        (self.output / (label + '.json')).write_text(json.dumps(data, ensure_ascii=False, indent=2))

    def request(self, method, params=None, notification=False, timeout=1200):
        message = {'jsonrpc': '2.0', 'method': method}
        if params is not None:
            message['params'] = params
        if not notification:
            self.sequence += 1
            message['id'] = self.sequence
        self.transcript.append({'direction': 'client', 'message': message})
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()
        if notification:
            return
        deadline = time.monotonic() + timeout
        while True:
            response = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            self.transcript.append({'direction': 'server', 'message': response})
            if response.get('eof'):
                raise RuntimeError('REA exited; inspect server.stderr.log')
            if response.get('id') == message['id']:
                if 'error' in response:
                    raise RuntimeError(response['error'])
                return response['result']

    def call(self, name, arguments=None, label=None, optional=False):
        reply = self.request('tools/call', {'name': name, 'arguments': arguments or {}})
        self.save(label or name, reply)
        if reply.get('isError'):
            if optional:
                print(f'{name}: unavailable; result retained', flush=True)
                return None
            raise RuntimeError(json.dumps(reply, ensure_ascii=False))
        print(name + ': OK', flush=True)
        result = reply.get('structuredContent')
        if result is None:
            result = next(json.loads(c['text']) for c in reply['content'] if c['type'] == 'text')
        return result

    def export(self):
        return self.call('export_evidence_bundle', {
            'path': str((self.output / 'evidence-bundle.json').resolve()), 'overwrite': True,
        })

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()
        self.save('transcript', self.transcript)
