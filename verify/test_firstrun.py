#!/usr/bin/env python3
"""First-run reporting reads disposable logs without changing user settings."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "bin/null-firstrun").read_text()
REPORT = SOURCE[SOURCE.index("TROUBLE="):SOURCE.index("trap report_trouble EXIT")]


class FirstRunReporting(unittest.TestCase):
    def run_report(self, contents):
        with tempfile.TemporaryDirectory(prefix="null-firstrun-test-") as folder:
            log = Path(folder) / "firstrun.log"
            log.write_text(contents)
            script = "set -uo pipefail\n" + REPORT + r'''
notify-send() { printf 'notification: %s\n' "$*"; }
report_trouble
'''
            return subprocess.run(["bash", "-c", script], env=dict(os.environ, LOG=str(log)),
                                  capture_output=True, text=True, timeout=10)

    def test_clean_log_is_silent(self):
        result = self.run_report("all settings applied\nbrowser skipped\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "")

    def test_duplicate_errors_produce_one_problem(self):
        result = self.run_report("  failed to connect\nfailed to connect\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("First-run setup: 1 problem", result.stdout)
        self.assertNotIn("1 problems", result.stdout)

    def test_distinct_errors_report_their_count(self):
        result = self.run_report("could not write settings\npermission denied\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("First-run setup: 2 problems", result.stdout)


if __name__ == "__main__":
    unittest.main()
