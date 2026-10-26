"""Server-owned agent loop. Disconnecting a client does not own/cancel a run."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import shutil
import time
import uuid
from cryptography.fernet import Fernet
from .files import contained, inventory, open_regular, write_regular, GLOBAL_WORKSPACE
from .tools import TOOLS, INSTRUCTIONS
from .history import History

TERMINAL = {"completed", "failed", "cancelled", "interrupted"}

class WaitingForUser(Exception): pass


class Vault:
    def __init__(self, key): self.cipher = Fernet(key)
    def seal(self, owner, value): return self.cipher.encrypt(json.dumps({"owner": owner, "value": value}).encode()).decode()
    def open(self, owner, value):
        decoded = json.loads(self.cipher.decrypt(value.encode()))
        if decoded["owner"] != owner: raise ValueError("Credential belongs to another owner")
        return decoded["value"]


class Engine:
    def __init__(self, store, spaces, models, terminals, vault, child_uid=10001):
        self.store, self.spaces, self.models, self.terminals, self.vault = store, spaces, models, terminals, vault
        self.child_uid = child_uid
        self.running = None
        self.wakeup = asyncio.Event()
        self.approvals = {}
        self._stopping = False
        self.execution_gate = asyncio.Lock()
        self.history = History(store, spaces.gateway, vault)

    async def loop(self):
        while not self._stopping:
            await self.wakeup.wait(); self.wakeup.clear()
            while not self._stopping:
                try:
                    async with self.execution_gate:
                        if any(t.process.returncode is None or t.reader and not t.reader.done() for t in self.terminals.sessions.values()): break
                        run = await self.store.claim()
                        if run: self.running = asyncio.create_task(self.execute(run), name=run["id"])
                except Exception:
                    await self.store.close()
                    break  # Retry on an actual client request, not an idle poll.
                if not run: break
                try: await self.running
                except asyncio.CancelledError:
                    if self._stopping: break
                except Exception:
                    # A database failure may prevent persisting a final state.
                    # Do not replay an uncertain command or kill the queue loop.
                    await self.store.close()
                    break
                finally: self.running = None

    def own(self, root):
        if self.child_uid is None: return
        if os.geteuid() != 0: raise RuntimeError("This runtime requires an unprivileged shell boundary")
        os.chmod(self.spaces.root, 0o711); os.chmod(root.parent, 0o711)
        for folder, directories, files in os.walk(root, followlinks=False):
            os.chown(folder, self.child_uid, self.child_uid)
            for name in files + directories: os.chown(Path(folder, name), self.child_uid, self.child_uid, follow_symlinks=False)

    async def execute(self, run):
        owner, identifier, conversation = run["owner"], run["id"], run["conversation"]
        grant = self.vault.open(owner, run["grant"])
        command_ids = set()
        try:
            async with self.store.active():
                root = await self.spaces.restore(owner, conversation, grant); self.own(root)
                global_root = await self.spaces.restore(owner, GLOBAL_WORKSPACE, grant)
                for folder in ["shared", "skills", "memory"]: (global_root / folder).mkdir(exist_ok=True)
                self.own(global_root)
                provider = self.vault.open(owner, run["provider"])
                saved = await self.store.get(owner, "conversation", conversation)
                run["_context_archives"] = (saved or {}).get("archives", [])[:]
                run["_native_session"] = run.get("native_session") or (saved or {}).get("native_session")
                messages = (saved or {}).get("messages", run.get("history", []))[:]
                if not run.get("resume_approval"): messages.append({"role": "user", "content": run["prompt"]})
                await self.save_conversation(run, messages, (saved or {}).get("title", run["prompt"][:120]))
                await self.store.event(owner, identifier, "state", {"status": "running"})
                async with asyncio.timeout(run.get("max_seconds", 7200)):
                    if run.get("resume_approval"):
                        approval = await self.store.get(owner, "approval", run["resume_approval"])
                        pending = run.get("pending_calls", [])
                        if not approval or not pending or approval["call"] != pending[0] or approval["status"] not in {"allowed", "denied"}:
                            raise ValueError("Approval cannot be applied to this saved tool call")
                        await self.perform_calls(run, pending, root, grant, command_ids, messages, approval["status"] == "allowed")
                        await self.store.update_run(owner, identifier, resume_approval=None, pending_calls=[])
                    for _ in range(100):
                        text, calls, buffered = "", [], ""
                        last_flush = time.monotonic()
                        async for event in self.models.stream(provider, messages, TOOLS, INSTRUCTIONS):
                            if event["kind"] == "text":
                                text += event["text"]; buffered += event["text"]
                                if len(text) > 512_000: raise ValueError("Reply exceeds the configured limit")
                                if len(buffered) >= 2048 or time.monotonic() - last_flush >= 0.5:
                                    await self.store.event(owner, identifier, "text", {"delta": buffered}); buffered = ""; last_flush = time.monotonic()
                            elif event["kind"] == "tool": calls.append(event)
                        if buffered: await self.store.event(owner, identifier, "text", {"delta": buffered})
                        if not text.strip() and not calls: raise ValueError("The model returned an empty response; no completion was inferred")
                        message = {"role": "assistant", "content": text}
                        if calls: message["tool_calls"] = [{"id": c["id"], "type": "function", "function": {"name": c["name"], "arguments": json.dumps(c["arguments"])}} for c in calls]
                        messages.append(message)
                        await self.save_conversation(run, messages, (saved or {}).get("title", run["prompt"][:120]))
                        if not calls:
                            if any(self.terminals.active(owner, key) for key in command_ids):
                                messages.append({"role": "user", "content": "Runtime: your command is still active. Poll it with write_stdin and verify its result before finishing."})
                                continue
                            await self.checkpoint(owner, conversation, grant)
                            await self.store.update_run(owner, identifier, status="completed")
                            await self.store.event(owner, identifier, "state", {"status": "completed"})
                            break
                        await self.perform_calls(run, calls, root, grant, command_ids, messages)
                    else: raise ValueError("Cloud turn limit reached; the checkpoint remains available")
        except WaitingForUser:
            pass  # No suspended worker/Atlas pool is retained for an approval.
        except asyncio.CancelledError:
            for key in command_ids:
                try: await self.terminals.stop(owner, key)
                except KeyError: pass
            try:
                if self.spaces.path(owner, conversation).is_dir(): await self.checkpoint(owner, conversation, grant)
            except Exception: pass  # Retain unverified recovery files, never replay commands.
            await self.store.update_run(owner, identifier, status="interrupted" if self._stopping else "cancelled")
            await self.store.event(owner, identifier, "state", {"status": "interrupted" if self._stopping else "cancelled"})
        except Exception as error:
            # Do not log provider objects, tokens or plaintext tool credentials.
            reason = "Storage/model connection failed" if type(error).__module__.startswith("httpx") else str(error)[:1000]
            await self.store.update_run(owner, identifier, status="failed", error=reason)
            await self.store.event(owner, identifier, "state", {"status": "failed", "error": reason})
        finally:
            for key in command_ids:
                try: await self.terminals.stop(owner, key)
                except KeyError: pass
            # Keep a failed/unverified workspace for inspection. A successful
            # cloud checkpoint is required before releasing ephemeral files.
            current = await self.store.run(owner, identifier)
            if current and current.get("status") in TERMINAL | {"waiting_user"} and self.spaces.path(owner, conversation).is_dir():
                try:
                    await self.checkpoint(owner, conversation, grant)
                    await asyncio.to_thread(shutil.rmtree, self.spaces.path(owner, conversation), True)
                    await asyncio.to_thread(shutil.rmtree, self.spaces.path(owner, GLOBAL_WORKSPACE), True)
                except Exception: pass  # Never remove failed/unverified recovery data.
            if current and current.get("status") in TERMINAL:
                try: await self.history.archive_events(owner, identifier)
                except Exception: pass  # Keep hot rows if archival fails; never discard unverified events.

    async def perform_calls(self, run, calls, root, grant, command_ids, messages, first_approval=None):
        owner, identifier, conversation = run["owner"], run["id"], run["conversation"]
        for index, call in enumerate(calls):
            approved = first_approval if index == 0 else None
            if approved is None and (run.get("permission_mode") == "ask_all" or call["name"] in {"exec_command", "file_write"} and run.get("permission_mode") != "unrestricted"):
                # A live command cannot be suspended into a portable approval.
                for key in command_ids:
                    if self.terminals.active(owner, key):
                        raise ValueError("Finish the active command before requesting another consequential action")
                await self.checkpoint(owner, conversation, grant)
                await self.approve(run, call, calls[index:])
            await self.store.event(owner, identifier, "tool_start", {"id": call["id"], "name": call["name"], "input": call["arguments"]})
            output = "User declined this action; it was not executed" if approved is False else await self.tool(run, call, root, command_ids)
            if approved is not False and (call["name"] == "file_write" or call["name"] in {"exec_command", "write_stdin"} and not any(self.terminals.active(owner, key) for key in command_ids)):
                await self.checkpoint(owner, conversation, grant)
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": output[:32_000]})
            await self.store.event(owner, identifier, "tool_result", {"id": call["id"], "output": output[:32_000], "success": approved is not False})
            await self.save_conversation(run, messages, run["prompt"][:120])

    async def checkpoint(self, owner, conversation, grant):
        await self.spaces.checkpoint(owner, conversation, grant)
        global_root = self.spaces.path(owner, GLOBAL_WORKSPACE)
        if global_root.is_dir(): await self.spaces.checkpoint(owner, GLOBAL_WORKSPACE, grant)

    async def save_conversation(self, run, messages, title):
        if len(json.dumps(messages, ensure_ascii=False)) > 180_000:
            # Start the retained suffix at a complete user/assistant message,
            # never in the middle of a tool-result batch.
            half = len(messages) // 2
            cut = next((i for i in range(half, len(messages) - 2) if messages[i].get("role") in {"user", "assistant"}), 0)
            if cut:
                grant = self.vault.open(run["owner"], run["grant"])
                ref = await self.history.put(run["owner"], grant, messages[:cut])
                run["_context_archives"].append(ref)
                checkpoint = (await self.store.run(run["owner"], run["id"])) or {}
                messages[:cut] = [{"role": "user", "content": "Earlier conversation context was encrypted and archived without deletion. Use history_read to inspect it. Current request: " + run["prompt"][:4000] + "\nProgress checkpoint: " + checkpoint.get("checkpoint", "")}]
                await self.store.event(run["owner"], run["id"], "context_archived", {"pages": len(run["_context_archives"])})
        await self.store.put(run["owner"], "conversation", run["conversation"], {"messages": messages, "title": title, "latest_run": run["id"], "archives": run.get("_context_archives", []), "native_session": run.get("_native_session")})

    async def approve(self, run, call, pending):
        key = str(uuid.uuid4()); owner, identifier = run["owner"], run["id"]
        request = {"run": identifier, "call": call, "status": "pending"}
        await self.store.put(owner, "approval", key, request)
        await self.store.update_run(owner, identifier, status="waiting_user", pending_calls=pending, pending_approval=key)
        await self.store.event(owner, identifier, "approval", {"id": key, "call": call})
        raise WaitingForUser()

    async def tool(self, run, call, root, command_ids):
        owner, conversation = run["owner"], run["conversation"]
        name, args = call["name"], call["arguments"]
        def scoped_path(value):
            for scope in ["shared", "skills", "memory"]:
                if value.startswith("@" + scope + "/"):
                    return self.spaces.path(owner, GLOBAL_WORKSPACE) / scope, value[len(scope) + 2:]
            return root, value
        if name == "file_read":
            def read():
                selected, path = scoped_path(args["path"])
                with open_regular(selected, path) as file: return file.read(32_001)
            data = await asyncio.to_thread(read)
            return data[:32_000].decode(errors="replace") + ("\n[truncated]" if len(data) > 32_000 else "")
        if name == "history_read":
            record = await self.store.get(owner, "conversation", conversation) or {}
            archives = record.get("archives", [])
            if "page" not in args: return json.dumps({"pages": len(archives), "instruction": "Use page (zero based) and offset to read a 32K-character window."})
            page, offset = int(args["page"]), max(0, int(args.get("offset", 0)))
            if not 0 <= page < len(archives): raise ValueError("History page not found")
            value = await self.history.get(owner, self.vault.open(owner, run["grant"]), archives[page])
            data = json.dumps(value, ensure_ascii=False)
            return data[offset:offset + 32_000] + ("\n[more: increase offset]" if len(data) > offset + 32_000 else "")
        if name == "file_write":
            data = args["content"].encode()
            if len(data) > 256_000: raise ValueError("File tool payload too large")
            selected, path = scoped_path(args["path"])
            await asyncio.to_thread(write_regular, selected, path, data)
            self.own(root); self.own(self.spaces.path(owner, GLOBAL_WORKSPACE))
            return "File written and checkpoint verified"
        if name == "file_list":
            scope = args.get("scope", "workspace")
            if scope not in {"workspace", "shared", "skills", "memory"}: raise ValueError("Invalid file scope")
            selected = root if scope == "workspace" else self.spaces.path(owner, GLOBAL_WORKSPACE) / scope
            prefix = "" if scope == "workspace" else "@" + scope + "/"
            return json.dumps([{"path": prefix + p, "bytes": n} for p, n, _, _ in await asyncio.to_thread(inventory, selected)], ensure_ascii=False)
        if name == "task_checkpoint":
            note = str(args["note"])[:4000]
            await self.store.update_run(owner, run["id"], checkpoint=note); return "Progress note saved"
        if name == "exec_command":
            terminal = await self.terminals.start(owner, conversation, root, args["cmd"], self.child_uid,
                                                   min(max(int(args.get("timeout_seconds", 300)), 1), 7200), self.spaces.path(owner, GLOBAL_WORKSPACE))
            command_ids.add(terminal.id)
            await asyncio.sleep(min(max(int(args.get("yield_time_ms", 1000)), 0), 10_000) / 1000)
            return json.dumps(self.terminals.read(owner, terminal.id), ensure_ascii=False)
        if name == "write_stdin":
            identifier = args["session_id"]
            if identifier not in command_ids: raise ValueError("Command does not belong to this run")
            if args.get("terminate"): await self.terminals.stop(owner, identifier)
            elif args.get("chars"): self.terminals.input(owner, identifier, args["chars"])
            else: await asyncio.sleep(0.5)
            return json.dumps(self.terminals.read(owner, identifier, int(args.get("offset", 0))), ensure_ascii=False)
        raise ValueError("This tool is unavailable on the cloud server; device/browser tools require the iPad")

    async def shutdown(self):
        self._stopping = True; self.wakeup.set()
        if self.running: self.running.cancel(); await asyncio.gather(self.running, return_exceptions=True)
        await self.terminals.close()
