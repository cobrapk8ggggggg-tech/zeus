"""Repair malformed provider output without executing tool-shaped prose."""
import re

MARKER = "ZEUS_TOOL_REPAIR_REQUIRED:"


def pending_call_prefix(text):
    # Hold only a still-ambiguous tool envelope. Ordinary JSON replies must
    # stream as soon as their first key distinguishes them from tool_calls.
    prefix = re.sub(r"\s+", "", text[:80])
    return bool(prefix) and any(marker.startswith(prefix) or prefix.startswith(marker) for marker in ('{"tool_calls":', '<tool_call>'))


def candidate(text, tools):
    value = text[:12000].strip()
    if not value.startswith(("{", "<tool_call>")): return None
    if '"tool_calls"' not in value and "<tool_call>" not in value: return None
    match = re.search(r'"name"\s*:\s*"([a-zA-Z0-9_]+)"', value)
    return match[1] if match and match[1] in {t["name"] for t in tools} else None


def forced(messages, tools):
    last = messages[-1] if messages else {}
    text = last.get("content", "")
    if last.get("role") != "user" or not isinstance(text, str) or not text.startswith(MARKER): return None
    name = text[len(MARKER):].split("\n", 1)[0]
    return name if name in {t["name"] for t in tools} else None


def repair(name):
    return MARKER + name + "\nThe preceding tool-shaped JSON was visible text and WAS NOT EXECUTED. Send a real structured provider function call now. Do not repeat any previously executed write. Preserve the user's approved plan and report no false success."
