"""Update failures remain failures; all commands operate through local doubles."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UpdateCommands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        (self.root / "lib").mkdir()
        shutil.copy(ROOT / "lib/menu.sh", self.root / "lib/menu.sh")
        self.env = dict(os.environ, NULL_ROOT=str(self.root), HOME=str(self.root),
                        PATH=f"{self.root}/bin:/usr/bin:/bin",
                        RECORD=str(self.root / "commands"), FAIL="")
        self.command("pkg", '''case $1 in
metadata-age) echo 0;;
upgrade-count) echo 0;;
cache-size) echo 0;;
what-is-orphaned) [ "$FAIL" != query ] || exit 8;;
*) echo "$1" >> "$RECORD"; [ "$FAIL" != "$1" ] || exit 9;;
esac
''')
        self.command("fwupdmgr", '''case $1 in
get-remotes) exit 0;;
update) echo firmware >> "$RECORD"; [ "$FAIL" != firmware ] || exit 7;;
esac
''')
        self.command("fc-cache", 'echo fonts >> "$RECORD"\n')

    def command(self, name, body):
        p = self.root / "bin" / name
        p.write_text("#!/bin/bash\n" + body)
        p.chmod(0o755)

    def run_update(self, *args):
        return subprocess.run(["bash", str(ROOT / "bin/null-update"), *args],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def recorded(self):
        path = Path(self.env["RECORD"])
        return path.read_text().splitlines() if path.exists() else []

    def test_report_without_flags_never_mutates(self):
        r = self.run_update()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.recorded(), [])

    def test_failed_upgrade_stops_before_orphan_removal_and_cache_cleanup(self):
        self.env["FAIL"] = "upgrade"
        r = self.run_update("--apply")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.recorded(), ["upgrade"])

    def test_failed_cleanup_propagates_status(self):
        self.env["FAIL"] = "clean-cache"
        r = self.run_update("--apply")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.recorded(), ["upgrade", "remove-orphans", "clean-cache"])

    def test_failed_firmware_write_propagates_status(self):
        self.env["FAIL"] = "firmware"
        r = self.run_update("--firmware-write")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.recorded(), ["firmware"])

    def test_failed_orphan_query_is_unknown_not_zero(self):
        self.env["FAIL"] = "query"
        r = self.run_update()
        row = next(line for line in r.stdout.splitlines() if "ORPHANED" in line)
        self.assertTrue(row.rstrip().endswith("--"), row)


if __name__ == "__main__":
    unittest.main()
