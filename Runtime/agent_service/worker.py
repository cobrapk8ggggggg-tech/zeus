import asyncio
import json
import os
from pathlib import Path
import shutil
import time
import uuid
from .codex import CodexRPC

TERMINAL = {"completed", "needs_verification", "failed", "cancelled", "interrupted", "exhausted"}


async def command(arguments, cwd, env=None, timeout=120):
    process = await asyncio.create_subprocess_exec(*arguments, cwd=cwd, env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, start_new_session=True)
    try:
        async def drain():
            output = bytearray()
            while chunk := await process.stdout.read(65536):
                output.extend(chunk)
                if len(output) > 200_000:
                    del output[:-200_000]
            await process.wait()
            return bytes(output)
        output = await asyncio.wait_for(drain(), timeout)
    except BaseException:
        try:
            import signal
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await process.wait()
        raise
    return process.returncode, output.decode(errors="replace")[-200_000:]


class Worker:
    def __init__(self, store, connections, codex_binary="codex"):
        self.store, self.connections, self.codex_binary = store, connections, codex_binary
        self.running, self.approvals = {}, {}

    def recover(self):
        # Do not replay an uncertain command after a server crash. The saved
        # thread and Git tree remain available for an explicit inspect/resume.
        for task in self.store.all("task"):
            if task["status"] not in TERMINAL and task["status"] != "queued":
                self.store.update("task", task["id"], status="interrupted", error="Worker restarted; inspect and resume the saved task.")
        for approval in self.store.all("approval"):
            if approval["status"] == "pending":
                self.store.update("approval", approval["id"], status="expired")

    async def loop(self):
        while True:
            if not self.running:
                queued = [t for t in self.store.all("task") if t["status"] == "queued"]
                if queued:
                    task = queued[-1]
                    runner = asyncio.create_task(self.run(task["id"]))
                    self.running[task["id"]] = runner
                    runner.add_done_callback(lambda _, key=task["id"]: self.running.pop(key, None))
            await asyncio.sleep(0.25)

    async def shutdown(self):
        for runner in list(self.running.values()):
            runner.cancel()
        await asyncio.gather(*self.running.values(), return_exceptions=True)

    async def approve(self, task, method, params, _):
        policy = task["permission_mode"]
        if method == "item/tool/requestUserInput":
            kind = "question"
        elif method in {"item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval", "item/permissions/requestApproval"}:
            if policy == "unrestricted":
                return self.decision(method, True, params)
            kind = "approval"
        else:
            kind = "elicitation"
        identifier = str(uuid.uuid4())
        item = {"id": identifier, "task_id": task["id"], "kind": kind, "method": method,
            "details": params, "status": "pending", "created": time.time()}
        self.store.put("approval", item)
        self.store.update("task", task["id"], status="waiting_user")
        self.store.event(task["id"], "approval", item)
        future = asyncio.get_running_loop().create_future()
        self.approvals[identifier] = future
        try:
            answer = await future
            self.store.update("task", task["id"], status="running")
            if kind == "question":
                return {"answers": answer.get("answers", {})}
            if kind == "elicitation":
                return {"action": "accept" if answer["allowed"] else "decline", "content": answer.get("content")}
            return self.decision(method, answer["allowed"], params)
        finally:
            self.approvals.pop(identifier, None)
            if self.store.get("approval", identifier)["status"] == "pending":
                self.store.update("approval", identifier, status="expired")

    @staticmethod
    def decision(method, allowed, params=None):
        if method == "item/permissions/requestApproval":
            return {"permissions": (params or {}).get("permissions", {}) if allowed else {}, "scope": "turn"}
        if method in {"execCommandApproval", "applyPatchApproval"}:
            return {"decision": "approved" if allowed else "denied"}
        return {"decision": "accept" if allowed else "decline"}

    async def run(self, identifier):
        task = self.store.get("task", identifier)
        project = self.store.get("project", task["project_id"])
        workspace = Path(project["workspace"])
        self.store.update("task", identifier, status="running", error=None)
        self.store.event(identifier, "state", {"status": "running"})
        rpc = None
        try:
            if not shutil.which(self.codex_binary):
                raise RuntimeError("Codex CLI is not installed on the worker")
            environment = self.connections.environment()
            environment["CODEX_HOME"] = str(self.store.root / "codex")
            complete = asyncio.Event()
            turn_result, process_exited = {}, False

            async def notification(method, params):
                nonlocal process_exited, turn_result
                if method == "zeus/processExited":
                    process_exited = True
                    complete.set()
                else:
                    self.store.event(identifier, method, params)
                    if method == "turn/completed":
                        turn_result = params.get("turn", {})
                        complete.set()

            async def request(method, params, request_id):
                return await self.approve(task, method, params, request_id)

            rpc = CodexRPC([self.codex_binary, "app-server"], str(workspace), environment, notification, request)
            async with asyncio.timeout(task["max_seconds"]):
                await rpc.start()
                policy = {"askAll": "untrusted", "consequential": "on-request", "unrestricted": "never"}[task["permission_mode"]]
                common = {"cwd": str(workspace), "approvalPolicy": policy, "sandbox": "danger-full-access"}
                if project.get("model"):
                    common["model"] = project["model"]
                if task.get("thread_id"):
                    response = await rpc.call("thread/resume", {**common, "threadId": task["thread_id"]})
                else:
                    response = await rpc.call("thread/start", {**common, "ephemeral": False})
                thread = response["thread"]["id"]
                self.store.update("task", identifier, thread_id=thread)
                instructions = self.instructions(project, task)
                for attempt in range(task["max_attempts"]):
                    complete.clear()
                    await rpc.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": instructions}]})
                    await complete.wait()
                    if process_exited:
                        raise RuntimeError("Codex disconnected during the task; resume from the saved thread")
                    if turn_result.get("status") != "completed":
                        raise RuntimeError(str(turn_result.get("error") or turn_result.get("status") or "Codex turn failed"))
                    checks = project.get("verify_commands", [])
                    if not checks:
                        self.store.update("task", identifier, status="needs_verification")
                        break
                    failed = []
                    for check in checks:
                        code, output = await command(["/bin/sh", "-lc", check], workspace, environment, timeout=min(task["max_seconds"], 1800))
                        self.store.event(identifier, "verification", {"command": check, "exit_code": code, "output": output})
                        if code:
                            failed.append({"command": check, "exit_code": code, "output": output[-30_000:]})
                    if not failed:
                        self.store.update("task", identifier, status="completed")
                        break
                    if attempt + 1 == task["max_attempts"]:
                        self.store.update("task", identifier, status="failed", error="Verification still fails after the configured repair attempts")
                    else:
                        instructions = "Continue the same task. Fix the actual failures without weakening the checks.\n" + json.dumps(failed, ensure_ascii=False)
        except asyncio.CancelledError:
            current = self.store.get("task", identifier)
            status = "cancelled" if current["status"] == "cancelling" else "interrupted"
            self.store.update("task", identifier, status=status)
        except TimeoutError:
            self.store.update("task", identifier, status="exhausted", error="The task reached its configured time budget")
        except Exception as error:
            self.store.update("task", identifier, status="failed", error=str(error)[:2000])
        finally:
            if rpc:
                await rpc.close()
            try:
                _, diff = await command(["git", "diff", "HEAD", "--stat"], workspace, timeout=15)
                self.store.event(identifier, "diffSummary", {"text": diff})
            except Exception:
                pass
            self.store.event(identifier, "state", {"status": self.store.get("task", identifier)["status"]})

    @staticmethod
    def instructions(project, task):
        return f'''You are Zeus, the coding agent integrated into ZEUS Browser.
Work in this actual Git project. Read AGENTS.md and relevant skills first.
Inspect before changing files, preserve unrelated work, use focused patches,
run builds and meaningful tests, inspect real failures and repair their causes.
Do not replace the original app UI unless explicitly requested. Use browser
tests for web UI and macOS/GitHub Actions for Xcode; Linux cannot run Xcode.
Continue until the requested outcome is implemented and verified or a real
blocker/permission/budget is reached. Never claim started jobs/deploys succeeded.
Keep a concise plan and checkpoints in .zeus/task-{task['id']}.md.
The parent may reconnect after hours; do not depend on the phone staying open.
When resuming, inspect current files/Git/CI state before replaying any write.
Permission mode: {task['permission_mode']}. In consequential mode request engine
approval before destructive deletion, publishing/deployment, credential exposure
or account-wide changes. Explain the exact destination and impact. Full access
to the worker is not itself user approval for those operations. Respect explicit
authorization already given in this task; never invent a grant.
Project: {project['name']}
Acceptance: {task['acceptance']}
Independent verification commands: {json.dumps(project.get('verify_commands', []))}
Request: {task['prompt']}'''
