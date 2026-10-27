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
from .terminal import protocol_result
from .tools import SERVER_TOOLS, TOOLS, INSTRUCTIONS, builtin_instructions
from .history import History
from .resources import instructions as resource_instructions

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

    def aliases(self, owner, root):
        if self.child_uid is None: return
        base = Path("/var/minis"); base.mkdir(exist_ok=True, mode=0o755)
        targets = {"workspace": root}
        for scope in ["attachments", "offloads", "browser"]:
            target = root / "__zeus_inputs__" / scope; target.mkdir(parents=True, exist_ok=True, mode=0o700)
            targets[scope] = target
        for scope in ["shared", "skills", "memory"]: targets[scope] = self.spaces.path(owner, GLOBAL_WORKSPACE) / scope
        for name, target in targets.items():
            link = base / name
            if link.exists() and not link.is_symlink(): raise ValueError("Unexpected runtime mount destination")
            link.unlink(missing_ok=True); link.symlink_to(target, target_is_directory=True)
        self.own(root)

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
                self.aliases(owner, root)
                provider = self.vault.open(owner, run["provider"])
                saved = await self.store.get(owner, "conversation", conversation)
                run["_context_archives"] = (saved or {}).get("archives", [])[:]
                run["_native_session"] = run.get("native_session") or (saved or {}).get("native_session")
                messages = (saved or {}).get("messages", run.get("history", []))[:]
                if not run.get("resume_approval") and not run.get("resume_device"): messages.append({"role": "user", "content": run["prompt"]})
                await self.save_conversation(run, messages, (saved or {}).get("title", run["prompt"][:120]))
                await self.store.event(owner, identifier, "state", {"status": "running"})
                async with asyncio.timeout(run.get("max_seconds", 7200)):
                    if run.get("resume_device"):
                        device = await self.store.get(owner, "approval", run["resume_device"])
                        pending = run.get("pending_calls", [])
                        if not device or device.get("status") != "completed" or not pending or device["call"] != pending[0]:
                            raise ValueError("Device tool result does not match the saved operation")
                        call, result = pending[0], dict(device["result"])
                        if result.get("image"):
                            import base64, hashlib
                            image = result["image"]; extension = {"image/jpeg":"jpg","image/png":"png","image/webp":"webp"}[image["mime"]]
                            name = hashlib.sha256(call["id"].encode()).hexdigest()[:20] + "." + extension
                            await asyncio.to_thread(write_regular, root, "__zeus_inputs__/browser/"+name, base64.b64decode(image["data"], validate=True))
                            self.own(root)
                            result["output"] += "\nCloud image file: /var/minis/browser/" + name

                        messages.append({"role": "tool", "tool_call_id": call["id"], "content": result["output"], **({"image": result["image"]} if result.get("image") else {})})
                        await self.store.event(owner, identifier, "tool_result", {"id": call["id"], "output": result["output"], "success": result["success"]})
                        await self.save_conversation(run, messages, (saved or {}).get("title", run["prompt"][:120]))
                        await self.store.update_run(owner, identifier, resume_device=None, pending_device=None, pending_calls=[])
                        if len(pending) > 1: await self.perform_calls(run, pending[1:], root, grant, command_ids, messages)

                    if run.get("resume_approval"):
                        approval = await self.store.get(owner, "approval", run["resume_approval"])
                        pending = run.get("pending_calls", [])
                        if not approval or not pending or approval["call"] != pending[0] or approval["status"] not in {"allowed", "denied"}:
                            raise ValueError("Approval cannot be applied to this saved tool call")
                        await self.perform_calls(run, pending, root, grant, command_ids, messages, approval["status"] == "allowed")
                        await self.store.update_run(owner, identifier, resume_approval=None, pending_calls=[])
                    from .tool_protocol import candidate, repair
                    repair_count = run.get("tool_text_repairs", 0)
                    for _ in range(100):
                        text, calls, buffered = "", [], ""
                        thinking, thinking_count = "", 0
                        thinking_flush = time.monotonic()
                        last_flush = time.monotonic()
                        flushed = False
                        async for event in self.models.stream(provider, messages, self.catalog(run), run.get("instructions", "") + "\n" + INSTRUCTIONS + resource_instructions() + builtin_instructions()):
                            if event["kind"] == "text":
                                text += event["text"]; buffered += event["text"]
                                if len(text) > 512_000: raise ValueError("Reply exceeds the configured limit")
                                possible_protocol = text.lstrip().startswith(("{", "<tool_call>")) and len(text) <= 12000
                                throttle = .2 if len(text) < 500 else .3 if len(text) < 2000 else .5 if len(text) < 32000 else 1 if len(text) < 64000 else 1.5 if len(text) < 128000 else 2
                                if not possible_protocol and (not flushed or time.monotonic() - last_flush >= throttle):
                                    await self.store.event(owner, identifier, "text", {"delta": buffered}); buffered = ""; last_flush = time.monotonic(); flushed = True
                            elif event["kind"] == "tool": calls.append(event)
                            elif event["kind"] == "thinking":
                                thinking += event["text"]
                                thinking_count += len(event["text"])
                                if thinking_count > 512_000: raise ValueError("Reasoning exceeds the configured limit")
                                if len(thinking) >= 2048 or time.monotonic() - thinking_flush >= 0.5:
                                    await self.store.event(owner, identifier, "thinking", {"delta": thinking})
                                    thinking = ""; thinking_flush = time.monotonic()
                        malformed = candidate(text, self.catalog(run)) if not calls else None
                        if buffered and not malformed: await self.store.event(owner, identifier, "text", {"delta": buffered})
                        if thinking: await self.store.event(owner, identifier, "thinking", {"delta": thinking})
                        if not text.strip() and not calls: raise ValueError("The model returned an empty response; no completion was inferred")
                        message = {"role": "assistant", "content": text}
                        if calls: message["tool_calls"] = [{"id": c["id"], "type": "function", "function": {"name": c["name"], "arguments": json.dumps(c["arguments"])}} for c in calls]
                        messages.append(message)
                        await self.save_conversation(run, messages, (saved or {}).get("title", run["prompt"][:120]))
                        if malformed:
                            repair_count += 1
                            await self.store.update_run(owner, identifier, tool_text_repairs=repair_count)
                            if repair_count > 2: raise ValueError("أرسل المزود طلب الأداة كنص وتعذّر تصحيح بروتوكوله بعد محاولتين. لم يُنفذ هذا النص؛ اختر نموذجًا يدعم الأدوات ثم أعد المحاولة.")
                            messages.append({"role": "user", "content": repair(malformed)})
                            continue
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
                try:
                    await self.history.archive_events(owner, identifier)
                    await self.history.archive_run_payload(owner, identifier)
                except Exception: pass  # Keep hot rows if archival fails; never discard unverified events.

    @staticmethod
    def catalog(run):
        # The app sends its canonical registry, including enabled MCP tools.
        # Cloud adds only durable-history support; it does not replace that list.
        entries = run.get("tools")
        if entries is None: entries = TOOLS
        result = {}
        for entry in entries:
            name = entry.get("name", "")
            if not isinstance(name, str) or not name or len(name) > 200 or not isinstance(entry.get("parameters"), dict):
                raise ValueError("Invalid canonical tool catalog")
            result[name] = {k: entry[k] for k in ["name", "description", "parameters"]}
        if entries: result.setdefault("history_read", TOOLS[-1])
        return list(result.values())

    async def perform_calls(self, run, calls, root, grant, command_ids, messages, first_approval=None):
        owner, identifier, conversation = run["owner"], run["id"], run["conversation"]
        for index, call in enumerate(calls):
            if run.get("tools") is not None and call["name"] not in {t["name"] for t in self.catalog(run)}: raise ValueError("The tool is disabled or absent from this conversation registry")
            approved = first_approval if index == 0 else None
            device_path = str(call["arguments"].get("path", "")).startswith(("/var/minis/mounts/", "minis://mounts/"))
            if call["name"] not in SERVER_TOOLS or device_path:
                if call["name"] not in {t["name"] for t in self.catalog(run)}: raise ValueError("The model requested an unregistered tool")
                if any(self.terminals.active(owner, key) for key in command_ids): raise ValueError("Finish the active command before waiting for the device")
                await self.checkpoint(owner, conversation, grant)
                key = str(uuid.uuid4())
                await self.store.put(owner, "approval", key, {"type": "device", "run": identifier, "call": call, "status": "pending"})
                await self.store.update_run(owner, identifier, status="waiting_user", pending_calls=calls[index:], pending_device=key)
                await self.store.event(owner, identifier, "tool_start", {"id": call["id"], "name": call["name"], "input": call["arguments"]})
                await self.store.event(owner, identifier, "device_required", {"id": key, "call": call, "notice": "هذه الأداة تستخدم الجهاز الأصلي. المهمة محفوظة وتنتظر اتصاله؛ لا يعمل متصفح على Railway."})
                raise WaitingForUser()

            if approved is None and (run.get("permission_mode") == "ask_all" or call["name"] in {"exec_command", "shell_execute", "file_write", "file_edit", "apply_patch", "memory_write"} and run.get("permission_mode") != "unrestricted"):
                # A live command cannot be suspended into a portable approval.
                for key in command_ids:
                    if self.terminals.active(owner, key):
                        raise ValueError("Finish the active command before requesting another consequential action")
                await self.checkpoint(owner, conversation, grant)
                await self.approve(run, call, calls[index:])
            await self.store.event(owner, identifier, "tool_start", {"id": call["id"], "name": call["name"], "input": call["arguments"]})
            successful = approved is not False
            try:
                output = "User declined this action; it was not executed" if approved is False else await self.tool(run, call, root, command_ids)
                if successful and call["name"] in {"shell_execute", "exec_command", "write_stdin"}:
                    exit_code = json.loads(output).get("exit_code")
                    successful = exit_code is None or exit_code == 0
            except (ValueError, KeyError, OSError, UnicodeDecodeError) as error:
                successful = False
                output = "Tool error: " + str(error)[:2000]
            if successful and (call["name"] in {"file_write", "file_edit", "apply_patch", "memory_write"} or call["name"] in {"exec_command", "shell_execute", "write_stdin"} and not any(self.terminals.active(owner, key) for key in command_ids)):
                await self.checkpoint(owner, conversation, grant)
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": output[:32_000]})
            await self.store.event(owner, identifier, "tool_result", {"id": call["id"], "output": output[:32_000], "success": successful})
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
        latest = await self.store.get(run["owner"], "conversation", run["conversation"]) or {}
        newer_submission = latest.get("latest_created", 0) > run["created"]
        await self.store.put(run["owner"], "conversation", run["conversation"], {"messages": messages, "title": title,
            "latest_run": latest.get("latest_run") if newer_submission else run["id"],
            "latest_created": max(latest.get("latest_created", 0), run["created"]), "archives": run.get("_context_archives", []),
            "native_session": latest.get("native_session") if newer_submission else run.get("_native_session")})

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
            if value.startswith("/var/minis/workspace/"): value = value[len("/var/minis/workspace/"):]
            if value.startswith("@builtin-skills/"):
                if name != "file_read": raise ValueError("Built-in skills are read-only; save custom skills under @skills")
                return Path("/opt/zeus/builtin-skills"), value[len("@builtin-skills/"):]
            for scope in ["attachments", "offloads", "browser"]:
                if value.startswith("/var/minis/" + scope + "/"): value = "__zeus_inputs__/" + scope + "/" + value[len("/var/minis/" + scope + "/"):]
            for scope in ["shared", "skills", "memory"]:
                if value.startswith("/var/minis/" + scope + "/"): value = "@" + scope + "/" + value[len("/var/minis/" + scope + "/"):]
                if value.startswith("@" + scope + "/"):
                    return self.spaces.path(owner, GLOBAL_WORKSPACE) / scope, value[len(scope) + 2:]
            return root, value
        if name == "apply_patch":
            from .patches import apply_patch
            if any(self.terminals.active(owner, key) for key in command_ids): raise ValueError("Finish the active command before applying a patch")
            result = await asyncio.to_thread(apply_patch, root, str(args.get("patch", args.get("input", ""))))
            self.own(root); return result
        if name in {"memory_get", "memory_write"}:
            import datetime
            memory = self.spaces.path(owner, GLOBAL_WORKSPACE) / "memory"
            if name == "memory_get":
                keyword = str(args.get("keywords", "")).casefold()
                content = []
                for path, _, _, _ in await asyncio.to_thread(inventory, memory):
                    with open_regular(memory, path) as file: text = file.read(32000).decode(errors="replace")
                    if not keyword or keyword in text.casefold() or keyword in path.casefold(): content.append(path + "\n" + text)
                    if sum(map(len, content)) > 32000: break
                return "\n".join(content)[:32000] or "No matching account memory"
            name = "file_write"
            args = {"path": "@memory/" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d.md"), "content": str(args["content"]) + "\n", "append": True}
        if name == "file_edit":
            selected, path = scoped_path(args["path"])
            with open_regular(selected, path) as file: data = file.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024: raise ValueError("Use a script to edit files larger than 1 MiB")
            text = data.decode(); old = str(args["old_string"])
            if not old or text.count(old) == 0 or not args.get("replace_all") and text.count(old) != 1:
                raise ValueError("old_string must match exactly once unless replace_all is enabled; file was not changed")
            changed = text.replace(old, str(args["new_string"]), -1 if args.get("replace_all") else 1)
            await asyncio.to_thread(write_regular, selected, path, changed.encode())
            self.own(selected); return "File edited"
        if name == "shell_execute":
            delay = min(max(float(args.get("delay", 0)), 0), 900)
            if delay: await asyncio.sleep(delay)
            terminal = await self.terminals.start(owner, conversation, root, str(args["command"]), self.child_uid,
                min(max(int(args.get("timeout", 900)), 1), 7200), self.spaces.path(owner, GLOBAL_WORKSPACE))
            command_ids.add(terminal.id)
            offset, sent, last_flush = 0, 0, time.monotonic()
            while self.terminals.active(owner, terminal.id):
                await asyncio.sleep(0.2)
                if time.monotonic() - last_flush >= 0.5 and sent < 32000:
                    value = self.terminals.read(owner, terminal.id, offset)
                    if value["output"]:
                        delta = value["output"][:32000-sent]; sent += len(delta); offset = value["next_offset"]
                        await self.store.event(owner, run["id"], "tool_output", {"id": call["id"], "delta": delta})
                    last_flush = time.monotonic()
            return protocol_result(self.terminals.read(owner, terminal.id))
        if name == "file_read":
            def read():
                selected, path = scoped_path(args["path"])
                with open_regular(selected, path) as file: return file.read(32_001)
            data = await asyncio.to_thread(read)
            text = data.decode(errors="replace"); lines = text.splitlines(keepends=True)
            count = min(max(int(args.get("lines", len(lines))), 1), 10000)
            offset = max(int(args.get("offset", 1)) - 1, 0)
            selected = lines[-count:] if args.get("direction") == "tail" else lines[offset:offset + count]
            limit = min(max(int(args.get("max_length", 15000)), 1), 32000)
            text = "".join(selected)
            return text[:limit] + ("\n[truncated]" if len(text) > limit or len(data) > 32000 else "")
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
            if args.get("append"):
                try:
                    with open_regular(selected, path) as current: previous = current.read(128 * 1024 * 1024 + 1)
                except FileNotFoundError: previous = b""
                if len(previous) + len(data) > 128 * 1024 * 1024: raise ValueError("Workspace file size limit reached")
                data = previous + data
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
            if args.get("action") == "save" or "note" in args:
                await self.store.update_run(owner, run["id"], checkpoint=str(args.get("note", ""))[:16000])
            current = await self.store.run(owner, run["id"])
            return json.dumps({"checkpoint": current.get("checkpoint", ""), "status": current["status"]}, ensure_ascii=False)
        if name == "exec_command":
            selected_root = root
            if args.get("workdir") and args["workdir"] not in {"/var/minis/workspace", "/var/minis/workspace/", "."}:
                parent, relative = scoped_path(str(args["workdir"]))
                selected_root = contained(parent, relative)
                if not selected_root.is_dir(): raise ValueError("workdir does not exist in the selected project")
            terminal = await self.terminals.start(owner, conversation, selected_root, args["cmd"], self.child_uid,
                                                   min(max(int(args.get("timeout_seconds", 300)), 1), 7200), self.spaces.path(owner, GLOBAL_WORKSPACE))
            command_ids.add(terminal.id)
            await asyncio.sleep(min(max(int(args.get("yield_time_ms", 1000)), 0), 10_000) / 1000)
            return protocol_result(self.terminals.read(owner, terminal.id))
        if name == "write_stdin":
            identifier = args["session_id"]
            if identifier not in command_ids: raise ValueError("Command does not belong to this run")
            if args.get("terminate"): await self.terminals.stop(owner, identifier)
            elif args.get("chars"): self.terminals.input(owner, identifier, args["chars"])
            else: await asyncio.sleep(0.5)
            return protocol_result(self.terminals.read(owner, identifier, int(args.get("offset", 0))))
        raise ValueError("This tool is unavailable on the cloud server; device/browser tools require the iPad")

    async def shutdown(self):
        self._stopping = True; self.wakeup.set()
        if self.running: self.running.cancel(); await asyncio.gather(self.running, return_exceptions=True)
        await self.terminals.close()
