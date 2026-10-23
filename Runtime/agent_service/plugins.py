"""Official plugin sources, independent OAuth and a narrow MCP credential proxy."""
import asyncio
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import time
from urllib.parse import urlencode, urlparse
import httpx
from cryptography.fernet import Fernet
from .worker import command

CATALOG = [
    {"id": "github", "name": "GitHub", "repository": "openai/plugins", "path": "plugins/github", "mcp_url": "https://api.githubcopilot.com/mcp/", "description": "المستودعات والفروع وطلبات الدمج وGitHub Actions"},
    {"id": "railway", "name": "Railway", "repository": "railwayapp/railway-skills", "path": "plugins/railway", "mcp_url": "https://mcp.railway.com", "description": "المشاريع والخدمات والنشر والسجلات"},
    {"id": "vercel", "name": "Vercel", "repository": "vercel/vercel-plugin", "path": ".", "mcp_url": "https://mcp.vercel.com", "description": "مشاريع الويب والمعاينات والنشر"},
    {"id": "build-ios-apps", "name": "تطوير تطبيقات iOS", "repository": "openai/plugins", "path": "plugins/build-ios-apps", "description": "مهارات SwiftUI والتصحيح والأداء والمحاكيات"},
    {"id": "build-web-apps", "name": "تطوير مواقع الويب", "repository": "openai/plugins", "path": "plugins/build-web-apps", "description": "بناء الواجهات واختبارها والتعامل مع بيانات الويب"},
]


class Connections:
    def __init__(self, store, public_url, api_token, port):
        self.store, self.public_url, self.port = store, public_url.rstrip("/"), port
        keyfile = store.root / "connection.key"
        if not keyfile.exists():
            descriptor = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as file:
                file.write(Fernet.generate_key())
        self.key = keyfile.read_bytes()
        self.cipher = Fernet(self.key)
        self.locks = {}

    def catalog(self):
        result = []
        for item in CATALOG:
            try:
                installed = self.store.get("plugin", item["id"])
            except KeyError:
                installed = {}
            try:
                auth = self.store.get("connection", item["id"])
            except KeyError:
                auth = {}
            result.append({**item, "installed": bool(installed), "revision": installed.get("revision"),
                "skills": installed.get("skills", []), "connected": bool(auth),
                "proxy_token": self.proxy_token(item["id"]) if auth else None})
        return result

    @staticmethod
    def definition(identifier):
        for item in CATALOG:
            if item["id"] == identifier:
                return item
        raise ValueError("إضافة غير موجودة في الدليل.")

    def proxy_token(self, identifier):
        return hmac.new(self.key, ("mcp-only:" + identifier).encode(), hashlib.sha256).hexdigest()

    def save_token(self, identifier, data):
        self.store.put("connection", {"id": identifier, "encrypted": self.cipher.encrypt(json.dumps(data).encode()).decode()})

    def credentials(self, identifier):
        return json.loads(self.cipher.decrypt(self.store.get("connection", identifier)["encrypted"].encode()))

    async def token(self, identifier):
        async with self.locks.setdefault(identifier, asyncio.Lock()):
            data = self.credentials(identifier)
            if data.get("expires_at", float("inf")) > time.time() + 60:
                return data["access_token"]
            if not data.get("refresh_token"):
                raise ValueError("انتهى التفويض. أعد ربط الحساب.")
            async with httpx.AsyncClient(timeout=30) as client:
                response = await client.post(data["token_endpoint"], data={"grant_type": "refresh_token", "refresh_token": data["refresh_token"], "client_id": data["client_id"]})
                response.raise_for_status()
                refreshed = response.json()
            data.update(refreshed, expires_at=time.time() + refreshed.get("expires_in", 3600))
            self.save_token(identifier, data)
            return data["access_token"]

    async def start_oauth(self, identifier):
        provider = self.definition(identifier)
        if not self.public_url.startswith("https://"):
            raise ValueError("يتطلب تسجيل الدخول عنوان HTTPS عامًا للخادم. يمكن ربط GitHub بتوكن وصول أيضًا.")
        resource = provider["mcp_url"]
        origin = urlparse(resource)
        async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
            probe = await client.get(resource, headers={"Accept": "application/json, text/event-stream"})
            match = re.search(r'resource_metadata="([^"]+)"', probe.headers.get("www-authenticate", ""))
            metadata_url = match[1] if match else f"{origin.scheme}://{origin.netloc}/.well-known/oauth-protected-resource"
            protected = await client.get(metadata_url)
            protected.raise_for_status()
            issuer = protected.json()["authorization_servers"][0].rstrip("/")
            metadata_response = await client.get(issuer + "/.well-known/oauth-authorization-server")
            if metadata_response.status_code == 404:
                metadata_response = await client.get(issuer + "/.well-known/openid-configuration")
            metadata_response.raise_for_status()
            metadata = metadata_response.json()
            registration = metadata.get("registration_endpoint")
            if not registration:
                raise ValueError("هذا المزود يحتاج تسجيل تطبيق OAuth مستقلًا؛ استخدم توكن الوصول المدعوم أو بيانات تطبيقك، ولا تنسخ تسجيل تطبيق ChatGPT.")
            if not all(str(metadata.get(k, "")).startswith("https://") for k in ("authorization_endpoint", "token_endpoint", "registration_endpoint")):
                raise ValueError("OAuth metadata must use HTTPS")
            redirect = self.public_url + "/oauth/callback"
            response = await client.post(registration, json={"client_name": "ZEUS Browser", "redirect_uris": [redirect],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"})
            response.raise_for_status()
            registered = response.json()
        state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        record = {"id": state, "provider": identifier, "created": time.time(), "redirect_uri": redirect,
            "client_id": registered["client_id"], "verifier": verifier, "token_endpoint": metadata["token_endpoint"], "resource": resource}
        self.store.put("oauth", {"id": state, "encrypted": self.cipher.encrypt(json.dumps(record).encode()).decode()})
        return {"url": metadata["authorization_endpoint"] + "?" + urlencode({"response_type": "code", "client_id": registered["client_id"],
            "redirect_uri": redirect, "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "resource": resource})}

    async def finish_oauth(self, state, code):
        record = json.loads(self.cipher.decrypt(self.store.get("oauth", state)["encrypted"].encode()))
        if time.time() - record["created"] > 600 or record.get("used"):
            raise ValueError("انتهت صلاحية طلب تسجيل الدخول.")
        # Consume the state before token exchange; do not replay a callback.
        record["used"] = True
        self.store.put("oauth", {"id": state, "encrypted": self.cipher.encrypt(json.dumps(record).encode()).decode()})
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(record["token_endpoint"], data={"grant_type": "authorization_code", "code": code,
                "client_id": record["client_id"], "redirect_uri": record["redirect_uri"], "code_verifier": record["verifier"], "resource": record["resource"]})
            response.raise_for_status()
            data = response.json()
        self.save_token(record["provider"], {**data, "expires_at": time.time() + data.get("expires_in", 3600),
            "client_id": record["client_id"], "token_endpoint": record["token_endpoint"]})
        return record["provider"]

    async def install(self, identifier):
        item = self.definition(identifier)
        root = self.store.root / "plugins" / identifier
        root.parent.mkdir(exist_ok=True)
        if not root.exists():
            code, output = await command(["git", "clone", "--filter=blob:none", "--depth=1", "--sparse", "https://github.com/" + item["repository"] + ".git", str(root)], self.store.root, timeout=180)
            if code:
                raise ValueError("Plugin download failed: " + output[-2000:])
            if item["path"] != ".":
                code, output = await command(["git", "sparse-checkout", "set", item["path"]], root)
                if code:
                    raise ValueError(output[-2000:])
            else:
                code, output = await command(["git", "sparse-checkout", "disable"], root)
                if code:
                    raise ValueError(output[-2000:])
        code, revision = await command(["git", "rev-parse", "HEAD"], root)
        source = root / item["path"]
        manifest_file = source / ".codex-plugin/plugin.json"
        if not manifest_file.exists():
            manifest_file = source / ".claude-plugin/plugin.json"
        manifest = json.loads(manifest_file.read_text())
        skills = []
        destination = self.store.root / "codex/skills"
        destination.mkdir(parents=True, exist_ok=True)
        for skill in sorted((source / "skills").glob("*/SKILL.md")):
            assets = list(skill.parent.rglob("*"))
            if len(assets) > 10000 or sum(a.stat().st_size for a in assets if a.is_file()) > 50_000_000:
                raise ValueError("Skill exceeds the installation size limit")
            for asset in assets:
                if asset.is_symlink() or not asset.resolve().is_relative_to(source.resolve()):
                    raise ValueError("Plugin contains an unsafe path")
            target = destination / (identifier + "--" + skill.parent.name)
            shutil.copytree(skill.parent, target, dirs_exist_ok=True)
            prefix = "" if item["path"] == "." else item["path"].strip("/") + "/"
            skills.append({"name": skill.parent.name, "url": f"https://github.com/{item['repository']}/tree/{revision.strip()}/{prefix}skills/{skill.parent.name}"})
        installed = self.store.put("plugin", {"id": identifier, "revision": revision.strip(), "version": manifest.get("version"),
            "skills": skills, "unsupported": ["ChatGPT .app.json account bindings", "host-specific hooks and commands"], "installed_at": time.time()})
        self.write_codex_config()
        return installed

    def write_codex_config(self):
        directory = self.store.root / "codex"
        directory.mkdir(exist_ok=True)
        text = '# Generated ZEUS MCP proxies; no provider credentials in this file.\n'
        for item in self.catalog():
            if item["installed"] and item.get("mcp_url"):
                text += f'\n[mcp_servers.{item["id"]}]\nurl = "http://127.0.0.1:{self.port}/mcp/{item["id"]}"\nbearer_token_env_var = "ZEUS_MCP_{item["id"].upper()}"\n'
        (directory / "config.toml").write_text(text)

    def environment(self):
        allowed = {"PATH", "HOME", "LANG", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_PROXY_CERT"}
        environment = {key: value for key, value in os.environ.items() if key in allowed or key.startswith("CODEX_") and key != "CODEX_HOME"}
        for item in CATALOG:
            if item.get("mcp_url"):
                environment["ZEUS_MCP_" + item["id"].upper()] = self.proxy_token(item["id"])
        try:
            github = self.credentials("github")
            environment["GH_TOKEN"] = github["access_token"]
        except KeyError:
            pass
        return environment
