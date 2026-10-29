from pathlib import Path
import tempfile
import unittest
from zeus_cloud.resources import limits


class ResourceTests(unittest.TestCase):
    def test_reports_effective_container_quota_instead_of_host_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in {"cpu.max":"25000 100000", "memory.max":"499998720", "pids.max":"1000"}.items():
                (root / name).write_text(value)
            observed = limits(root)
            self.assertEqual(observed["cpu_cores_quota"], .25)
            self.assertEqual(observed["memory_bytes_limit"], 499998720)
            self.assertEqual(observed["pids_limit"], 1000)
            self.assertTrue(observed["shared_across_conversations"])

    def test_unknown_or_unlimited_quota_never_falls_back_to_host_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIsNone(limits(root)["memory_bytes_limit"])
            (root / "cpu.max").write_text("max 100000")
            (root / "memory.max").write_text("max")
            (root / "pids.max").write_text("max")
            observed = limits(root)
            for name in ["cpu_cores_quota", "memory_bytes_limit", "pids_limit"]: self.assertIsNone(observed[name])
