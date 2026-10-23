"""Smoke-test the built image with a new volume, then remove only our fixtures."""
import json
import os
import secrets
import subprocess
import time
import uuid
import sys


def run(*arguments, **options):
    return subprocess.run(["docker", *arguments], check=True, capture_output=True, text=True, **options).stdout.strip()


def main():
    name = "zeus-project-smoke-" + uuid.uuid4().hex[:12]
    volume = name + "-data"
    environment = dict(os.environ, ZEUS_API_TOKEN=secrets.token_urlsafe(32))
    code = '''import urllib.request,json,os,sys
path,method,body=sys.argv[1:]
r=urllib.request.Request('http://127.0.0.1:8080'+path,method=method,data=body.encode() if body else None,headers={'Authorization':'Bearer '+os.environ['ZEUS_API_TOKEN'],'Content-Type':'application/json'})
print(urllib.request.urlopen(r,timeout=15).read().decode())'''
    def request(path, method="GET", body=None):
        return json.loads(run("exec", name, "python", "-c", code, path, method, json.dumps(body) if body else ""))
    def ready():
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                return request("/health")
            except subprocess.CalledProcessError:
                time.sleep(.2)
        raise RuntimeError("Container did not become healthy")
    run("volume", "create", volume)
    try:
        run("run", "-d", "--name", name, "--env", "ZEUS_API_TOKEN", "--volume", volume + ":/data", "zeus-project-agent:test", env=environment)
        ready()
        capabilities = request("/v1/capabilities")
        assert capabilities["codex_installed"], capabilities
        assert "0.163.0" in capabilities["codex_version"], capabilities
        project = request("/v1/projects", "POST", {"name": "Persistent container project"})
        run("restart", name)
        ready()
        projects = request("/v1/projects")["projects"]
        assert any(p["id"] == project["id"] for p in projects), projects
        uid = run("exec", name, "sh", "-c", "awk '/^Uid:/{print $2}' /proc/1/status")
        assert uid == "10001", uid
        print(json.dumps({"container_health": True, "codex_version": capabilities["codex_version"], "volume_persistence_after_restart": True, "worker_uid": uid}, indent=2))
    except BaseException as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        diagnostic = subprocess.run(["docker", "logs", "--tail", "80", name], capture_output=True, text=True)
        print(diagnostic.stdout + diagnostic.stderr, file=sys.stderr)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "volume", "rm", volume], capture_output=True)


if __name__ == "__main__": main()
