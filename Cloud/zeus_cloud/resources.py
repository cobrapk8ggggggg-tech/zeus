"""Report container quotas, never mistake the host's /proc totals for a quota."""
import json
from pathlib import Path


def limits(root=Path("/sys/fs/cgroup")):
    def read(name):
        try: return (root / name).read_text().strip()
        except (OSError, UnicodeError): return ""
    def bounded_integer(name):
        value = read(name)
        return int(value) if value.isdecimal() and int(value) > 0 else None
    quota = read("cpu.max").split()
    cpu = int(quota[0]) / int(quota[1]) if len(quota) == 2 and all(v.isdecimal() for v in quota) and int(quota[1]) > 0 else None
    return {"cpu_cores_quota": cpu, "memory_bytes_limit": bounded_integer("memory.max"),
            "pids_limit": bounded_integer("pids.max"), "shared_across_conversations": True}


def instructions():
    return "\nObserved container cgroup quotas (null means unavailable, never infer a number): " + json.dumps(limits(), sort_keys=True) + "\n/proc/meminfo, /proc/cpuinfo, /proc/loadavg and host process totals can describe the hosting machine, NOT this service's available resources. Use cgroup quotas for actual allocation. Do not attribute fork EAGAIN to host load without evidence; inspect the command's real exit, process limit and container PID usage. Conversation workspaces share this service's quota; there is no dedicated VM per chat."
