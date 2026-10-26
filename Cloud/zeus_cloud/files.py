"""Bounded, verified workspace checkpoints outside Railway's ephemeral disk."""
import asyncio
import hashlib
import os
import shutil
from pathlib import Path, PurePosixPath
import stat
import uuid
import base64
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from contextlib import contextmanager
import httpx

CHUNK = 8 * 1024 * 1024
WORKSPACE_LIMIT = 128 * 1024 * 1024
MAX_FILES = 4096


def relative_path(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or any(p in {"..", ".", ""} for p in name.split("/")) or "\\" in name or "\0" in name:
        raise ValueError("Invalid workspace path")
    return path


def contained(root, name):
    relative_path(name)
    value = root.joinpath(name)
    resolved = value.resolve()
    if not resolved.is_relative_to(root.resolve()) or value.is_symlink():
        raise ValueError("Workspace links cannot escape the project")
    return value


@contextmanager
def open_regular(root, name):
    """openat/O_NOFOLLOW protects root-owned readers from symlink races."""
    parts = relative_path(name).parts
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory); directory = child
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor); raise ValueError("Only regular workspace files can be uploaded")
        with os.fdopen(descriptor, "rb") as file: yield file
    finally: os.close(directory)


def inventory(root):
    result, total = [], 0
    def walk(directory, prefix=""):
        nonlocal total
        with os.scandir(directory) as children:
            for entry in sorted(children, key=lambda e: e.name):
                name = prefix + entry.name
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    try: walk(child, name + "/")
                    finally: os.close(child)
                elif stat.S_ISREG(info.st_mode):
                    total += info.st_size
                    if total > WORKSPACE_LIMIT or len(result) >= MAX_FILES: raise ValueError("Workspace limit reached; no local files were deleted")
                    result.append((name, info.st_size, info.st_mtime_ns, stat.S_IMODE(info.st_mode) & 0o777))
                else: raise ValueError("Workspace links/special files cannot be checkpointed")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: walk(descriptor)
    finally: os.close(descriptor)
    return result


def write_regular(root, name, data):
    parts = relative_path(name).parts
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            try: os.mkdir(part, mode=0o700, dir_fd=descriptor)
            except FileExistsError: pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor); descriptor = child
        leaf = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=descriptor)
        try:
            info = os.fstat(leaf)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1: raise ValueError("Refusing a special or shared-linked file")
            os.ftruncate(leaf, 0)
            with os.fdopen(os.dup(leaf), "wb") as file: file.write(data); file.flush(); os.fsync(file.fileno())
        finally: os.close(leaf)
    finally: os.close(descriptor)


class FilesGateway:
    def __init__(self, url, client=None):
        self.url = url
        self.client = client or httpx.AsyncClient(timeout=90, follow_redirects=False)

    async def check(self, token):
        response = await self.client.get(self.url, params={"op": "check"}, headers={"Authorization": "Bearer " + token})
        response.raise_for_status(); return response.json()

    async def put(self, token, data):
        if len(data) > CHUNK: raise ValueError("Object exceeds transfer limit")
        digest = hashlib.sha256(data).hexdigest()
        response = await self.client.put(self.url, params={"op": "put", "sha": digest}, content=data,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/octet-stream"})
        response.raise_for_status()
        result = response.json()
        if result.get("sha256") != digest or result.get("bytes") != len(data) or result.get("verified") is not True:
            raise ValueError("Cloud object verification failed")
        return {"sha256": digest, "bytes": len(data)}

    async def get(self, token, ref):
        digest, size = ref.get("sha256", ""), ref.get("bytes", -1)
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest) or not 0 <= size <= CHUNK:
            raise ValueError("Invalid object reference")
        async with self.client.stream("GET", self.url, params={"op": "get" if token.startswith("zg1_") else "userget", "sha": digest}, headers={"Authorization": "Bearer " + token}) as response:
            response.raise_for_status(); data = bytearray()
            async for part in response.aiter_bytes():
                if len(data) + len(part) > size: raise ValueError("Object response exceeds declared size")
                data.extend(part)
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest: raise ValueError("Corrupt cloud object")
        return bytes(data)

    async def close(self): await self.client.aclose()


class Workspaces:
    def __init__(self, root, gateway, store, vault=None):
        self.root, self.gateway, self.store = Path(root).resolve(), gateway, store
        self.vault = vault
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def key(self, owner, record):
        if record.get("key"):
            return base64.b64decode(self.vault.open(owner, record["key"]), validate=True)
        return None

    def aad(self, owner, digest, index): return f"{owner}|{digest}|{index}".encode()

    async def part(self, owner, file, index, grant, key):
        data = await self.gateway.get(grant, file["parts"][index])
        if file.get("encrypted"):
            if not key or len(data) < 28: raise ValueError("Encrypted workspace key is unavailable")
            data = AESGCM(key).decrypt(data[:12], data[12:], self.aad(owner, file["sha256"], index))
        return data

    async def import_files(self, owner, conversation, files, key_text, grant):
        if not self.vault: raise ValueError("Encrypted workspace storage is unavailable")
        key = base64.b64decode(key_text, validate=True)
        if len(key) != 32 or len(files) > MAX_FILES or sum(f["bytes"] for f in files) > WORKSPACE_LIMIT:
            raise ValueError("Workspace exceeds its configured limit or has an invalid key")
        previous = await self.store.get(owner, "workspace", conversation) or {}
        target_key = self.key(owner, previous) or key
        merged = {f["path"]: f for f in previous.get("files", [])}
        for file in files:
            relative_path(file["path"])
            digest = hashlib.sha256(); size = 0; parts = []
            if len(file["sha256"]) != 64 or len(file["parts"]) > WORKSPACE_LIMIT // (CHUNK - 28) + 1: raise ValueError("Invalid encrypted file manifest")
            for index in range(len(file["parts"])):
                data = await self.part(owner, {**file, "encrypted": True}, index, grant, key)
                digest.update(data); size += len(data)
                if size > file["bytes"]: raise ValueError("Imported file exceeds declared size")
                if key == target_key: parts.append(file["parts"][index])
                else:
                    nonce = os.urandom(12)
                    parts.append(await self.gateway.put(grant, nonce + AESGCM(target_key).encrypt(nonce, data, self.aad(owner, file["sha256"], index))))
            if size != file["bytes"] or digest.hexdigest() != file["sha256"]: raise ValueError("Imported file integrity check failed")
            existing = merged.get(file["path"])
            if existing and existing.get("sha256") != file["sha256"]: raise ValueError("Cloud file differs from the local import; local originals were retained")
            merged[file["path"]] = {"path": file["path"], "bytes": size, "sha256": file["sha256"], "parts": parts, "encrypted": True, "mode": 0o600}
        if len(merged) > MAX_FILES or sum(f["bytes"] for f in merged.values()) > WORKSPACE_LIMIT: raise ValueError("Merged workspace exceeds its configured limit")
        return await self.store.put(owner, "workspace", conversation, {"files": list(merged.values()), "version": 1,
            "key": self.vault.seal(owner, base64.b64encode(target_key).decode())})

    async def read_cloud_file(self, owner, conversation, name, grant, offset=0):
        relative_path(name)
        record = await self.store.get(owner, "workspace", conversation) or {}
        file = next((f for f in record.get("files", []) if f["path"] == name), None)
        if file is None: raise KeyError(name)
        key = self.key(owner, record); result = bytearray(); skipped = 0
        for index, ref in enumerate(file["parts"]):
            length = ref["bytes"] - (28 if file.get("encrypted") else 0)
            if skipped + length <= offset: skipped += length; continue
            part = await self.part(owner, file, index, grant, key)
            start = max(0, offset - skipped)
            result.extend(part[start:start + 1024 * 1024 - len(result)]); skipped += len(part)
            if len(result) >= 1024 * 1024: break
        return bytes(result)

    def path(self, owner, conversation):
        owner, conversation = str(uuid.UUID(owner)), str(uuid.UUID(conversation))
        return self.root / owner / conversation

    async def restore(self, owner, conversation, grant):
        root = self.path(owner, conversation)
        # A failed job may contain newer, unverified writes. Never overwrite
        # that recovery workspace with an older cloud checkpoint.
        if root.is_dir() and any(root.iterdir()): return root
        record = await self.store.get(owner, "workspace", conversation)
        root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        stage = root.with_name("." + root.name + "-restore-" + uuid.uuid4().hex)
        if record:
            files = record.get("files", [])
            if len(files) > MAX_FILES or sum(f["bytes"] for f in files) > WORKSPACE_LIMIT: raise ValueError("Workspace exceeds its configured limit")
            stage.mkdir(mode=0o700)
            try:
                for entry in files:
                    path = contained(stage, entry["path"]); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    overhead = 28 if entry.get("encrypted") else 0
                    if sum(p["bytes"] - overhead for p in entry["parts"]) != entry["bytes"]: raise ValueError("Invalid manifest size")
                    digest = hashlib.sha256()
                    with path.open("wb") as output:
                        for index in range(len(entry["parts"])):
                            data = await self.part(owner, entry, index, grant, self.key(owner, record))
                            digest.update(data); output.write(data)
                    if entry.get("sha256") and digest.hexdigest() != entry["sha256"]: raise ValueError("File integrity check failed")
                    os.chmod(path, entry.get("mode", 0o600) & 0o777)
                os.replace(stage, root)
            finally:
                if stage.exists(): await asyncio.to_thread(shutil.rmtree, stage)
        else: root.mkdir(parents=True, exist_ok=True, mode=0o700)
        return root

    async def checkpoint(self, owner, conversation, grant):
        root = self.path(owner, conversation)
        before = await asyncio.to_thread(inventory, root)
        previous = await self.store.get(owner, "workspace", conversation)
        key = self.key(owner, previous or {}) or (os.urandom(32) if self.vault else None)
        known = {(p["sha256"], p["bytes"]) for f in (previous or {}).get("files", []) for p in f["parts"]}
        files = []
        for name, size, _, mode in before:
            parts = []
            copied_digest = hashlib.sha256()
            def file_hash():
                digest = hashlib.sha256()
                with open_regular(root, name) as source:
                    while data := source.read(CHUNK): digest.update(data)
                return digest.hexdigest()
            file_digest = await asyncio.to_thread(file_hash)
            old = next((f for f in (previous or {}).get("files", []) if f.get("sha256") == file_digest and f["bytes"] == size and bool(f.get("encrypted")) == bool(key)), None)
            if old:
                files.append({**old, "path": name, "mode": mode}); continue
            with open_regular(root, name) as file:
                while data := await asyncio.to_thread(file.read, CHUNK - (28 if key else 0)):
                    copied_digest.update(data)
                    if key:
                        nonce = os.urandom(12)
                        data = nonce + AESGCM(key).encrypt(nonce, data, self.aad(owner, file_digest, len(parts)))
                    digest = hashlib.sha256(data).hexdigest()
                    ref = {"sha256": digest, "bytes": len(data)}
                    if (digest, len(data)) not in known: ref = await self.gateway.put(grant, data)
                    parts.append(ref)
            if sum(p["bytes"] - (28 if key else 0) for p in parts) != size: raise ValueError("File changed during checkpoint")
            if copied_digest.hexdigest() != file_digest: raise ValueError("File changed while copying its contents")
            files.append({"path": name, "bytes": size, "mode": mode, "parts": parts, "sha256": file_digest, "encrypted": bool(key)})
        if before != await asyncio.to_thread(inventory, root): raise ValueError("Workspace changed during checkpoint; no complete checkpoint published")
        record = {"files": files, "version": 1}
        if key: record["key"] = (previous or {}).get("key") or self.vault.seal(owner, base64.b64encode(key).decode())
        return await self.store.put(owner, "workspace", conversation, record)
