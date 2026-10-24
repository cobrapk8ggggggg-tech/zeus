"""Capture the actual app window using OpenMinis' existing DEBUG endpoint.

Avoid routing every UI snapshot through CoreSimulator's separate screen-capture
service. This captures the original rendered window, not a reconstructed view.
"""
import base64
import struct


def capture(rpc, destination):
    result = rpc("debug.screenshot", {"scale": 1.0})
    data = base64.b64decode(result["base64"], validate=True)
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) < 1000:
        raise RuntimeError("The native window did not produce a valid screenshot")
    width, height = struct.unpack(">II", data[16:24])
    if min(width, height) < 100:
        raise RuntimeError("The native window screenshot is unexpectedly small")
    destination.write_bytes(data)
