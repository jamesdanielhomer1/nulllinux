#!/usr/bin/env python3
"""Live-media cleanup is evaluated only in redirected temporary filesystems."""
import configparser
import http.server
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import threading
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

    def setup_live(self, *, selinux=False, live=True, label_status=0):
        source = heredoc("SETUP")
        for directory in ("/etc", "/usr", "/opt", "/home", "/run", "/proc", "/sys"):
            source = source.replace(directory, str(self.root) + directory)
        self.file("/proc/cmdline").write_text("rd.live.image\n" if live else "quiet\n")
        self.file("/home/live/.bash_profile")
        (self.root / "run").mkdir(exist_ok=True)
        if selinux:
            self.file("/sys/fs/selinux/enforce").write_text("1\n")
        prefix = r'''
getent() { return 0; }
useradd() { printf 'useradd %s\n' "$*" >> calls; }
passwd() { printf 'passwd %s\n' "$*" >> calls; }
chown() { printf 'chown %s\n' "$*" >> calls; }
chcon() {
  test -f "${@: -1}" || return 20
  printf 'chcon %s\n' "$*" >> calls
  return "$FIXTURE_LABEL_STATUS"
}
'''
        env = dict(os.environ, FIXTURE_LABEL_STATUS=str(label_status))
        env.pop("NULL_TEST_MACHINE", None)
        return subprocess.run(["bash", "-c", prefix + source], cwd=self.root, env=env,
                              capture_output=True, text=True, timeout=15)

    def test_live_marker_gets_existing_polkit_context_before_authorization_rule(self):
        result = self.setup_live(selinux=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        marker = self.root / "run/nulllinux-live"
        self.assertEqual(marker.stat().st_mode & 0o777, 0o644)
        self.assertIn(f"chcon -t policykit_var_run_t {marker}",
                      (self.root / "calls").read_text())
        self.assertTrue((self.root / "etc/polkit-1/rules.d/49-nulllinux-live.rules").exists())

    def test_disabled_selinux_does_not_require_labeling(self):
        result = self.setup_live(selinux=False, label_status=17)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("chcon", (self.root / "calls").read_text())
        self.assertTrue((self.root / "run/nulllinux-live").is_file())

    def test_failed_live_marker_label_stops_before_privilege_rule(self):
        result = self.setup_live(selinux=True, label_status=17)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertFalse((self.root / "etc/polkit-1/rules.d/49-nulllinux-live.rules").exists())

    def test_installed_boot_never_creates_live_marker_or_rule(self):
        result = self.setup_live(selinux=True, live=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "run/nulllinux-live").exists())
        self.assertFalse((self.root / "calls").exists())
        self.assertFalse((self.root / "etc/polkit-1/rules.d/49-nulllinux-live.rules").exists())

    def test_compose_removes_cloned_identity_and_seed_but_preserves_dbus_link(self):
        machine_id = self.file("/etc/machine-id")
        machine_id.write_text("c0df2dd1d0f44bd88b2f6372064e5832\n")
        seed = self.file("/var/lib/systemd/random-seed")
        link = self.root / "var/lib/dbus/machine-id"
        link.parent.mkdir(parents=True)
        link.symlink_to("/etc/machine-id")
        # Run the actual final compose post-script tail in a redirected tree.
        tail = SOURCE.rsplit("/opt/nulllinux/bin/null-brand report\n", 1)[1].split("%end", 1)[0]
        for directory in ("/etc", "/var"):
            tail = tail.replace(directory, str(self.root) + directory)
        result = subprocess.run(["bash", "-eu", "-c", tail], cwd=self.root,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(machine_id.read_bytes(), b"")
        self.assertFalse(seed.exists())
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "/etc/machine-id")

    def test_target_cleanup_removes_seed_but_retains_generated_machine_id(self):
        machine_id = self.file("/etc/machine-id")
        machine_id.write_text("created-by-anaconda\n")
        seed = self.file("/var/lib/systemd/random-seed")
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(machine_id.read_text(), "created-by-anaconda\n")
        self.assertFalse(seed.exists())

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

    def test_branded_installer_inherits_fedora_without_hiding_accounts(self):
        profile = configparser.ConfigParser()
        profile.read_string(heredoc("ANACONDA_PROFILE"))
        self.assertEqual(profile["Profile"]["profile_id"], "nulllinux")
        self.assertEqual(profile["Profile"]["base_profile"], "fedora")
        self.assertEqual(profile["Profile Detection"]["os_id"], "nulllinux")
        self.assertEqual(profile["User Interface"]["webui_web_engine"], "firefox")
        self.assertNotIn("anaconda-screen-accounts",
                         profile["User Interface"].get("hidden_webui_pages", "").split())
        self.assertIn("/etc/anaconda/profile.d/nulllinux.conf", SOURCE)

    def test_live_getty_uses_selinux_labeled_stock_program_after_live_guard(self):
        unit = configparser.ConfigParser(interpolation=None, strict=False)
        unit.read_string(heredoc("AUTO"))
        self.assertEqual(unit["Service"].get("ExecCondition"),
                         "/usr/libexec/nulllinux-live-check")
        self.assertEqual(unit["Service"]["ExecStart"],
                         "-/sbin/agetty --autologin live --noclear %I $TERM")
        # A generated shell wrapper acquires the wrong SELinux service domain
        # before PAM starts the user shell, even when its argv are identical.
        self.assertNotIn("cat > /usr/libexec/nulllinux-live-getty", SOURCE)

    def test_live_compose_removes_conflicting_display_manager_boot_job(self):
        if not shutil.which("systemctl"):
            self.skipTest("systemctl is not installed")
        unit = self.file("/usr/lib/systemd/system/sddm.service")
        unit.write_text("[Unit]\nConflicts=getty@tty1.service\n"
                        "[Service]\nExecStart=/bin/true\n"
                        "[Install]\nAlias=display-manager.service\n")
        alias = self.root / "etc/systemd/system/display-manager.service"
        alias.parent.mkdir(parents=True)
        alias.symlink_to("/usr/lib/systemd/system/sddm.service")
        # Evaluate only compose commands, excluding the installed cleanup
        # heredoc, which must restore the display manager after installation.
        compose = re.sub(r"<<'([A-Z_]+)'\n.*?\n\1\n", "", SOURCE, flags=re.S)
        commands = re.findall(r"^systemctl --root=/ (?:enable|disable) sddm\.service$",
                              compose, flags=re.M)
        for command in commands:
            result = subprocess.run(command.replace("--root=/", f"--root={self.root}").split(),
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(alias.is_symlink(), "SDDM's skipped start job still conflicts with live tty1")
        self.assertIn("systemctl --root=/ enable sddm.service nulllinux-machine-sync.service",
                      heredoc("CLEANUP"))

    def test_real_anaconda_detects_btrfs_profile_with_accounts_visible(self):
        try:
            from pyanaconda.core.configuration.anaconda import AnacondaConfiguration
            from pyanaconda.core.configuration.profile import ProfileLoader
        except ImportError:
            self.skipTest("Anaconda configuration loader is not installed")
        config_dir = Path("/etc/anaconda")
        if not (config_dir / "profile.d/fedora.conf").is_file():
            self.skipTest("Fedora Anaconda profile is not installed")
        candidate = self.root / "nulllinux.conf"
        candidate.write_text(heredoc("ANACONDA_PROFILE"))
        loader = ProfileLoader()
        loader.load_profiles(str(config_dir / "profile.d"))
        loader.load_profile(str(candidate))
        detected = loader.detect_profile("nulllinux", "remix")
        self.assertEqual(detected, "nulllinux")
        config = AnacondaConfiguration()
        config.read(str(config_dir / "anaconda.conf"))
        for path in loader.collect_configurations(detected):
            config.read(path)
        parser = config.get_parser()
        self.assertEqual(parser["Storage"]["default_scheme"], "BTRFS")
        self.assertEqual(parser["Storage"]["btrfs_compression"], "zstd:1")
        self.assertEqual(parser["Bootloader"]["efi_dir"], "fedora")
        self.assertEqual(parser["User Interface"]["webui_web_engine"], "firefox")
        self.assertNotIn("anaconda-screen-accounts",
                         parser["User Interface"]["hidden_webui_pages"].split())
        self.assertNotIn("UserSpoke", config.ui.hidden_spokes)
        self.assertNotIn("PasswordSpoke", config.ui.hidden_spokes)

    def test_explicit_test_key_retries_refused_connection(self):
        if not shutil.which("curl"):
            self.skipTest("curl is not installed")
        source = heredoc("HOOK")
        for directory in ("/etc", "/usr", "/root", "/proc"):
            source = source.replace(directory, str(self.root) + directory)
        check = self.file("/usr/libexec/nulllinux-live-check")
        check.write_text("#!/bin/bash\nexit 0\n")
        check.chmod(0o755)
        class KeyHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(handler):
                body = b"ssh-ed25519 fixture\n"
                handler.send_response(200)
                handler.send_header("Content-Length", str(len(body)))
                handler.end_headers()
                handler.wfile.write(body)

            def log_message(handler, *args):
                pass

        # Reserve an ephemeral loopback port without listening. Wait for real
        # curl's refused connection before starting the server, so this cannot
        # accidentally pass by connecting successfully on the first attempt.
        server = http.server.HTTPServer(("127.0.0.1", 0), KeyHandler,
                                       bind_and_activate=False)
        self.addCleanup(server.server_close)
        server.server_bind()
        server.timeout = 5
        port = server.server_address[1]
        self.file("/proc/cmdline").write_text(
            f"rd.live.image nulllinux.sshkey=http://127.0.0.1:{port}/key.pub\n")
        prefix = r'''
systemctl() { printf 'systemctl %s\n' "$*" >> calls; }
ssh-keygen() { return 0; }
curl() {
  command curl --connect-timeout 1 --max-time 2 --retry-max-time 5 "$@"
}
'''
        env = dict(os.environ, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        with subprocess.Popen(["bash", "-c", prefix + source], cwd=self.root,
                              env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as process:
            try:
                ready, _, _ = select.select([process.stderr], [], [], 5)
                self.assertTrue(ready, "curl did not report its first connection attempt")
                first_error = process.stderr.readline()
                self.assertIn("curl: (7)", first_error)
                server.server_activate()
                responder = threading.Thread(target=server.handle_request, daemon=True)
                responder.start()
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stdout + first_error + stderr)
                responder.join(timeout=1)
                self.assertFalse(responder.is_alive())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        key = self.root / "root/.ssh/authorized_keys"
        self.assertEqual(key.read_text(), "ssh-ed25519 fixture\n")
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        calls = (self.root / "calls").read_text()
        self.assertIn("systemctl restart sshd", calls)


if __name__ == "__main__":
    unittest.main()
