"""Small provider adapters; model calls and tool loops live on the server."""
import ipaddress
import json
from urllib.parse import urlsplit
import httpx


def provider_url(value):
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Use a public HTTPS provider URL without embedded credentials")
    host = parsed.hostname.lower()
    if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
        raise ValueError("Internal provider endpoints are unavailable")
    try:
        if not ipaddress.ip_address(host).is_global: raise ValueError("Internal provider endpoints are unavailable")
    except ValueError as error:
        if "Internal" in str(error): raise
    return value.rstrip("/")


class Models:
    def __init__(self, client=None):
        self.client = client or httpx.AsyncClient(timeout=httpx.Timeout(1800, connect=20), follow_redirects=False)

    async def stream(self, provider, messages, tools, instructions):
        base = provider_url(provider["base_url"])
        kind = provider["kind"]
        if kind == "openai":
            url = base if base.endswith("/chat/completions") else base + "/chat/completions"
            headers = {"Authorization": "Bearer " + provider["api_key"]}
            body = {"model": provider["model"], "messages": [{"role": "system", "content": instructions}] + messages,
                    "stream": True, "tools": [{"type": "function", "function": t} for t in tools],
                    "max_completion_tokens": provider.get("max_tokens", 4096)}
        elif kind == "anthropic":
            url = base if base.endswith("/messages") else base + "/messages"
            headers = {"x-api-key": provider["api_key"], "anthropic-version": "2023-06-01"}
            converted = []
            for message in messages:
                role, content = message["role"], message.get("content") or ""
                if role == "tool":
                    converted.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": message["tool_call_id"], "content": content}]})
                elif role == "assistant" and message.get("tool_calls"):
                    parts = [{"type": "text", "text": content}] if content else []
                    for tool in message["tool_calls"]:
                        parts.append({"type": "tool_use", "id": tool["id"], "name": tool["function"]["name"], "input": json.loads(tool["function"]["arguments"])})
                    converted.append({"role": role, "content": parts})
                elif role in {"assistant", "user"}: converted.append({"role": role, "content": content})
            body = {"model": provider["model"], "messages": converted, "system": instructions, "stream": True,
                    "max_tokens": provider.get("max_tokens", 4096),
                    "tools": [{"name": t["name"], "description": t["description"], "input_schema": t["parameters"]} for t in tools]}
        else: raise ValueError("This provider protocol is not available in cloud mode yet")
        if len(json.dumps(body).encode()) > 2 * 1024 * 1024: raise ValueError("Cloud context limit reached; compact the conversation before continuing")
        calls = {}; ended = False
        async with self.client.stream("POST", url, json=body, headers=headers) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                if len(line) > 512_000: raise ValueError("Provider event exceeds limit")
                if not line.startswith("data:"): continue
                raw = line[5:].strip()
                if raw == "[DONE]": ended = True; break
                data = json.loads(raw)
                if data.get("error"): raise ValueError("The model provider returned an error")
                if kind == "openai":
                    choices = data.get("choices", [])
                    if not choices: continue
                    item = choices[0]; delta = item.get("delta", {})
                    if delta.get("content"): yield {"kind": "text", "text": delta["content"]}
                    if delta.get("reasoning_content"): yield {"kind": "thinking", "text": delta["reasoning_content"]}
                    for call in delta.get("tool_calls", []):
                        current = calls.setdefault(call["index"], {"id": "", "name": "", "arguments": ""})
                        current["id"] += call.get("id", "")
                        current["name"] += call.get("function", {}).get("name", "")
                        current["arguments"] += call.get("function", {}).get("arguments", "")
                        if len(current["arguments"]) > 256_000: raise ValueError("Tool arguments exceed limit")
                    if item.get("finish_reason"): ended = True
                else:
                    event = data.get("type")
                    if event == "content_block_start" and data["content_block"]["type"] == "tool_use":
                        block = data["content_block"]
                        calls[data["index"]] = {"id": block["id"], "name": block["name"], "arguments": ""}
                    elif event == "content_block_delta":
                        delta = data["delta"]
                        if delta["type"] == "text_delta": yield {"kind": "text", "text": delta["text"]}
                        elif delta["type"] == "thinking_delta": yield {"kind": "thinking", "text": delta["thinking"]}
                        elif delta["type"] == "input_json_delta":
                            current = calls[data["index"]]; current["arguments"] += delta["partial_json"]
                            if len(current["arguments"]) > 256_000: raise ValueError("Tool arguments exceed limit")
                    elif event == "message_stop": ended = True
        if not ended: raise ValueError("Provider stream ended without a final event; saved partial output can be inspected")
        for index in sorted(calls):
            call = calls[index]
            if not call["id"] or not call["name"]: raise ValueError("Incomplete tool call")
            arguments = json.loads(call["arguments"] or "{}")
            if not isinstance(arguments, dict): raise ValueError("Tool arguments must be an object")
            yield {"kind": "tool", "id": call["id"], "name": call["name"], "arguments": arguments}

    async def close(self): await self.client.aclose()
