#!/usr/bin/env python3
"""Live-media cleanup is evaluated only in redirected temporary filesystems."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "packaging/nulllinux-live.ks").read_text()


def heredoc(marker):
    match = re.search(r"<<'" + marker + r"'\n(.*?)\n" + marker + r"\n", SOURCE, re.S)
    if not match:
        raise AssertionError(f"missing live-image script {marker}")
    return match[1]


class LiveImage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="null-live-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def file(self, name):
        path = self.root / name.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture")
        return path

    def cleanup(self, password=""):
        source = heredoc("CLEANUP")
        for directory in ("/etc", "/usr", "/opt", "/root", "/home", "/run", "/var"):
            source = source.replace(directory, str(self.root) + directory)
        prefix = r'''
systemctl() { printf 'systemctl %s\n' "$*" >> calls; }
userdel() { printf 'userdel %s\n' "$*" >> calls; }
getent() {
  case "$1" in
    passwd) printf 'live:x:1000:1000:nullLinux Live Session:/home/live:/bin/bash\n';;
    shadow) printf 'live:%s:1:0:99999:7:::\n' "$FIXTURE_PASSWORD";;
  esac
}
'''
        env = dict(os.environ, FIXTURE_PASSWORD=password)
        env.pop("NULL_TEST_MACHINE", None)
        return subprocess.run(["bash", "-c", prefix + source], cwd=self.root, env=env,
                              capture_output=True, text=True, timeout=15)

    def test_target_cleanup_removes_live_privileges_and_debug_access(self):
        removed = ["/etc/sudoers.d/live-nulllinux", "/etc/polkit-1/rules.d/49-nulllinux-live.rules",
                   "/etc/systemd/system/getty@tty1.service.d/autologin.conf",
                   "/etc/systemd/system/sddm.service.d/live.conf",
                   "/etc/ssh/sshd_config.d/60-nulllinux-test.conf", "/root/.ssh/authorized_keys",
                   "/usr/share/applications/install-nulllinux.desktop", "/run/nulllinux-live",
                   "/var/lib/nulllinux/surfaces-placed"]
        for name in removed:
            self.file(name)
        retained = self.file("/etc/sudoers.d/administrator")
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(retained.exists())
        for name in removed:
            self.assertFalse((self.root / name.lstrip("/")).exists(), name)
        self.assertIn("userdel --force --remove live", (self.root / "calls").read_text())

    def test_new_installed_live_named_user_and_unrelated_root_key_are_retained(self):
        key = self.file("/root/.ssh/authorized_keys")
        result = self.cleanup("$6$new-installed-password")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(key.exists())
        self.assertNotIn("userdel", (self.root / "calls").read_text())

    def test_live_setup_and_launcher_are_scoped_and_ordered(self):
        setup = heredoc("SETUP")
        self.assertLess(setup.index("rd.live.image"), setup.index("useradd"))
        self.assertIn("/run/nulllinux-live", setup)
        self.assertIn("org.fedoraproject.pkexec.liveinst", setup)
        self.assertIn("subject.active && subject.local", setup)
        self.assertNotIn("NOPASSWD", setup)
        unit = heredoc("AUTO")
        self.assertIn("Requires=nulllinux-live-setup.service nulllinux-machine-sync.service", unit)
        self.assertIn("After=nulllinux-live-setup.service nulllinux-machine-sync.service", unit)
        launcher = heredoc("DESK")
        self.assertIn("Exec=/opt/nulllinux/bin/null-live install", launcher)
        self.assertIn("Terminal=false", launcher)
        self.assertNotIn("liveinst --kickstart", SOURCE)


if __name__ == "__main__":
    unittest.main()
