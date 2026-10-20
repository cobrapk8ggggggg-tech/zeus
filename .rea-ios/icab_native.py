"""Reproduce the targeted analysis of the user's supplied, already decrypted IPA.

Extract Payload/iCabMobile.app/iCabMobile yourself. This does not run it.
Install the pinned REA runtime from runtime/package-lock.json and set
GHIDRA_INSTALL_DIR to Ghidra 12.1.4 (with Java 21 on PATH).
"""
import argparse
import hashlib
import os
from pathlib import Path
from mcp_transport import MCP

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
expected = 'fa388346982ff8d9fa9a717b8a992abc832b1dd3dceb2350965778ffd79fbfc2'
if hashlib.sha256(args.binary.read_bytes()).hexdigest() != expected:
    parser.error('Binary hash differs; these addresses apply only to the recorded supplied executable.')
os.environ.setdefault('GHIDRA_HEADLESS_MAXMEM', '4G')
os.environ.setdefault('REA_GHIDRA_STARTUP_TIMEOUT_MS', '3600000')
os.environ['REA_GHIDRA_DISABLED_ANALYZERS'] = 'Objective-C Message Analyzer,Stack,Decompiler Switch Analysis'
client = MCP(args.output.resolve())
addresses = ['0x100043c5c', '0x10004212c', '0x1001ba578', '0x1001c30a8']
try:
    client.call('open_binary', {'path': str(args.binary.resolve()), 'provider_id': 'ghidra'})
    client.call('binary_overview')
    for index, address in enumerate(addresses):
        client.call('analyze_function', {'procedure': address}, label=f'function-{index}')
    client.export()
    client.call('close_binary')
finally:
    client.close()
