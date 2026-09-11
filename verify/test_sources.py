#!/usr/bin/env python3
"""Source inventory checks use a local manifest and a fake retrieval helper."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Sources(unittest.TestCase):
    def run_check(self, corrupt=False, wrong_download=False):
        with tempfile.TemporaryDirectory(prefix="null-sources-test-") as tmp:
            root = Path(tmp)
            source = (ROOT / "bin/null-sources").read_text()
            match = re.search(r"^check_manifest\(\).*?^}", source, re.M | re.S)
            self.assertIsNotNone(match, "source checks must be independently testable without mounting")
            (root / "bin").mkdir()
            helper = root / "bin/pkg"
            filename = "wrong.src.rpm" if wrong_download else "$2.src.rpm"
            helper.write_text(f'#!/usr/bin/env bash\nprintf source > "$3/{filename}"\n')
            helper.chmod(0o755)
            rows = [f"package{i}-1-1.noarch\tGPL-2.0-only\tpackage{i}-1-1.src.rpm" for i in range(101)]
            if corrupt:
                rows[-1] = "package100-1-1.noarch\tGPL-2.0-only\tmissing"
            manifest = root / "SOURCES.txt"
            manifest.write_text("nullLinux source inventory\n" + "\n".join(rows) + "\n")
            env = dict(os.environ, ROOT=str(root))
            env.pop("NULL_TEST_MACHINE", None)
            return subprocess.run(["bash", "-c", match.group() + '\ncheck_manifest "$1"', "fixture", str(manifest)],
                                  env=env, capture_output=True, text=True, timeout=15)

    def test_factual_inventory_does_not_require_a_written_offer(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("sample source retrieval passed", result.stdout)
        self.assertNotIn("complete and fulfillable", result.stdout)

    def test_missing_source_identity_is_failure(self):
        result = self.run_check(corrupt=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_different_downloaded_source_is_failure(self):
        result = self.run_check(wrong_download=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
