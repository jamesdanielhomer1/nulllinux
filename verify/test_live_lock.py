"""Live boot exceptions run against copied commands and private marker paths."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LiveLock(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="null-live-lock-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ["bin", "tools", "lib", "runtime", "config/sway", "render/target/release"]:
            (self.root / name).mkdir(parents=True)
        self.marker = self.root / "live-marker"
        self.cmdline = self.root / "boot-flags"
        self.cmdline.write_text("")
        self.env = dict(os.environ, NULL_ROOT=str(self.root), HOME=str(self.root),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_RUNTIME_DIR=str(self.root / "runtime"),
                        WAYLAND_DISPLAY="live-fixture", PATH=str(self.root / "tools") + ":" + os.environ["PATH"])
        for name in ["null-lock", "null-idle"]:
            # The production path is fixed and has no environment override.
            # Replace it only in this isolated copy; never touch host /run.
            code = (ROOT / "bin" / name).read_text().replace("/run/nulllinux-live", str(self.marker))
            (self.root / "bin" / name).write_text(code)
        helper = (ROOT / "lib/live.sh").read_text().replace("/run/nulllinux-live", str(self.marker))
        (self.root / "lib/live.sh").write_text(helper.replace("/proc/cmdline", str(self.cmdline)))
        self.script("render/target/release/lock", 'echo native >> "$NULL_ROOT/started"; echo LOCKED')
        self.script("tools/swaylock", 'echo fallback >> "$NULL_ROOT/started"')
        self.script("tools/swayidle", 'echo idle >> "$NULL_ROOT/started"')
        self.script("tools/notify-send", 'printf "%s\\n" "$*" > "$NULL_ROOT/notification"')
        self.script("tools/pgrep", "exit 1")
        self.script("tools/pkill", 'echo signal >> "$NULL_ROOT/signalled"')
        self.script("bin/machine", "exit 1")
        (self.root / "lib/once.sh").write_text('null_only_one() { echo "$*" >> "$NULL_ROOT/stopped"; }\n')

    def script(self, name, code):
        target = self.root / name
        target.write_text("#!/usr/bin/env bash\n" + code + "\n")
        target.chmod(0o755)

    def run_command(self, name, *args):
        return subprocess.run(["bash", str(self.root / "bin" / name), *args],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def test_live_manual_lock_and_fallback_never_start_a_locker(self):
        self.marker.touch()
        self.cmdline.write_text("quiet rd.live.image rhgb\n")
        for args in [(), ("--daemonize",)]:
            with self.subTest(args=args):
                result = self.run_command("null-lock", *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.root / "started").exists(), "live boot started a locker")
                self.assertIn("live session", result.stderr.lower())
                self.assertIn("live session", (self.root / "notification").read_text().lower())

    def test_live_idle_cannot_be_started_or_reenabled(self):
        self.marker.touch()
        self.cmdline.write_text("quiet rd.live.image rhgb\n")
        for action in ["start", "apply", "toggle"]:
            with self.subTest(action=action):
                result = self.run_command("null-idle", action)
                self.assertEqual(result.returncode, 0, result.stderr)
                time.sleep(.03)
                self.assertFalse((self.root / "started").exists(), "live boot enabled idle lock/suspend")
                self.assertFalse((self.root / "config/nulllinux/idle.conf").exists())
                self.assertIn("live session", result.stdout.lower())
        self.assertEqual((self.root / "stopped").read_text().splitlines(), ["swayidle -w -C"] * 3)
        state = self.run_command("null-idle", "state")
        self.assertEqual(state.stdout.strip(), "off (live session)")

    def test_marker_without_live_boot_flag_keeps_installed_locking(self):
        self.marker.touch()
        result = self.run_command("null-lock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "started").exists(), "marker alone disabled installed locking")
        self.assertEqual(self.run_command("null-idle", "state").stdout.strip(), "off")

    def test_live_boot_flag_without_marker_keeps_installed_locking(self):
        self.cmdline.write_text("quiet rd.live.image rhgb\n")
        result = self.run_command("null-lock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "started").exists(), "boot flag alone disabled installed locking")
        self.assertEqual(self.run_command("null-idle", "state").stdout.strip(), "off")

    def test_installed_session_still_uses_native_and_fallback_lockers(self):
        native = self.run_command("null-lock")
        self.assertEqual(native.returncode, 0, native.stderr)
        fallback = self.run_command("null-lock", "--daemonize")
        self.assertEqual(fallback.returncode, 0, fallback.stderr)
        self.assertEqual((self.root / "started").read_text().splitlines(), ["native", "fallback"])
        self.assertFalse((self.root / "notification").exists())

    def test_installed_session_still_starts_idle_ladder(self):
        result = self.run_command("null-idle", "start")
        self.assertEqual(result.returncode, 0, result.stderr)
        until = time.monotonic() + 2
        while not (self.root / "started").exists() and time.monotonic() < until:
            time.sleep(.02)
        self.assertEqual((self.root / "started").read_text().strip(), "idle")
        conf = (self.root / "config/nulllinux/idle.conf").read_text()
        self.assertIn("before-sleep", conf)
        self.assertIn("null-lock", conf)


if __name__ == "__main__":
    unittest.main()
