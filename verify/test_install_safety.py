#!/usr/bin/env python3
"""Installer regressions. All writes and command doubles live in a temp tree.

Never execute a privileged entry point against the running machine. The few
functions which name /etc are extracted and their filesystem boundary is
redirected before evaluation; account, service and package commands are doubles.
"""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("TEST_BASH", shutil.which("bash") or "bash")


def shell_path(path):
    value = str(path).replace("\\", "/")
    return "/" + value[0].lower() + value[2:] if re.match(r"^[A-Za-z]:/", value) else value


def function(path, name):
    source = (ROOT / path).read_text()
    return re.search(r"^" + name + r"\(\).*?^}", source, re.M | re.S).group()


class Safety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="null-install-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()

    def write(self, rel, content, executable=False):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, newline="\n")
        if executable:
            path.chmod(0o755)
        return path

    def command(self, name, content):
        return self.write("commands/" + name, "#!/usr/bin/env bash\n" + content, True)

    def run_shell(self, script, data=None, env=None):
        environment = os.environ.copy()
        environment.pop("NULL_TEST_MACHINE", None)
        environment.update(env or {})
        prefix = "PATH=" + shlex.quote(shell_path(self.commands)) + ":/usr/bin:/bin:$PATH\n"
        return subprocess.run([BASH, "-c", prefix + script], input=data,
                              text=True, capture_output=True, timeout=20,
                              cwd=self.root, env=environment)

    def test_invalid_admin_state_never_removes_the_last_admin(self):
        script = function("bin/null-users", "cmd_admin") + r'''
need_root() { :; }
exists() { return 0; }
is_admin() { return 0; }
admins() { printf 'onlyuser\n'; }
gpasswd() { printf '%s\n' "$*" >> mutation; }
say() { :; }; hint() { :; }; oops() { :; }
ADMIN_GROUP=wheel
cmd_admin onlyuser off
'''
        result = self.run_shell(script)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "mutation").exists())

    def installer(self, password, output="answers.ks", full='A "quoted" Person'):
        self.write("bin/null-installer", (ROOT / "bin/null-installer").read_text(), True)
        self.write("lib/menu.sh", (ROOT / "lib/menu.sh").read_text())
        self.command("lsblk", "printf '/dev/sdz 20G Test disk\\n'\n")
        self.command("findmnt", "exit 1\n")
        self.command("timedatectl", "printf 'Europe/London\\n'\n")
        answers = f"1\ntesthost\ntester\n{full}\n{password}\n{password}\n1\ngb\n\n/dev/sdz\n"
        return self.run_shell("bin/null-installer --dry-run --generate " + shlex.quote(output), answers,
                              {"NULL_ROOT": shell_path(self.root)})

    def test_kickstart_preserves_quotes_and_backslashes(self):
        password = 'a"b"c\\tail'
        result = self.installer(password)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        line = next(line for line in (self.root / "answers.ks").read_text().splitlines()
                    if line.startswith("user "))
        args = shlex.split(line)
        self.assertIn("--password=" + password, args)
        self.assertIn('--gecos=A "quoted" Person', args)

    def test_installer_write_failure_is_failure(self):
        (self.root / "answers.ks").mkdir()
        result = self.installer("password")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_installer_does_not_reuse_declined_answers(self):
        result = self.installer("password")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_shell("bin/null-installer --dry-run --generate answers.ks",
                                "1\nh\nu\nU\np\np\n1\ngb\n\nno\n",
                                {"NULL_ROOT": shell_path(self.root)})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "answers.ks").exists())

    def test_booted_whole_disk_is_excluded(self):
        script = function("bin/null-installer", "booted_from") + r'''
findmnt() { printf '/dev/sdz\n'; }
lsblk() { case "$*" in *TYPE*) printf 'disk\n';; esac; }
[() { if [[ "$1" == -b ]]; then return 0; fi; builtin [ "$@"; }
booted_from
'''
        result = self.run_shell(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/dev/sdz")

    def machine_fixture(self, install_rc=0):
        source = (ROOT / "bin/null-machine-sync").read_text()
        source = source.replace("/var/lib/nulllinux/surfaces-placed", shell_path(self.root / "state/stamp"))
        self.write("bin/null-machine-sync", source, True)
        self.write("bin/machine", '''#!/usr/bin/env bash
case $1 in
 profile) echo profile;;
 check-profile|generate) exit 0;;
 get) case $2 in interface_strike) echo ter-u16n;; bake_strike) echo ter-112n;; esac;;
esac
''', True)
        self.write("bin/null-install", f"#!/usr/bin/env bash\nexit {install_rc}\n", True)
        self.write("bin/null-system", "#!/usr/bin/env bash\nexit 0\n", True)
        for rel in ["strikes/palette.bin", "strikes/palette.json", "strikes/atlas-ter-116n.bin",
                    "strikes/ramp-ter-116n.json", "strikes/atlas-ter-112n.bin"]:
            self.write("assets/prebuilt/" + rel, "asset")
        for name in ("master.cells", "target-2.cells", "target-4.cells", "tty.cells", "logo.cells", "ramp-bake.json"):
            self.write("assets/prebuilt/ter-112n/" + name, "asset")
        for rel in ("config/sway/colours.conf", "config/foot/foot.ini", "config/shell/colours.sh",
                    "config/gtk-3.0/gtk.css", "config/gtk-4.0/gtk.css"):
            self.write("assets/prebuilt/theme/" + rel, "theme")
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
        for rel in ("boot/plymouth-theme/nullLinux.plymouth", "boot/sddm-theme/Main.qml"):
            self.write("assets/prebuilt/" + rel, "theme")

    def test_failed_machine_install_does_not_stamp_success(self):
        self.machine_fixture(1)
        result = self.run_shell("bin/null-machine-sync", env={"NULL_ROOT": shell_path(self.root)})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "state/stamp").exists())
        self.write("bin/null-install", "#!/usr/bin/env bash\nexit 0\n", True)
        result = self.run_shell("bin/null-machine-sync", env={"NULL_ROOT": shell_path(self.root)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "state/stamp").exists())

    def test_machine_sync_refreshes_hardlinked_theme_trees(self):
        self.machine_fixture()
        pairs = [("theme/config/gtk-3.0/gtk.css", "config/gtk-3.0/gtk.css"),
                 ("theme/config/gtk-4.0/gtk.css", "config/gtk-4.0/gtk.css"),
                 ("boot/plymouth-theme/nullLinux.plymouth", "system/plymouth-theme/nullLinux.plymouth"),
                 ("boot/sddm-theme/Main.qml", "system/sddm-theme/Main.qml")]
        for source, target in pairs:
            destination = self.root / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.link(self.root / "assets/prebuilt" / source, destination)
        result = self.run_shell("bin/null-machine-sync", env={"NULL_ROOT": shell_path(self.root)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "state/stamp").exists())
        for source, target in pairs:
            original = self.root / "assets/prebuilt" / source
            destination = self.root / target
            self.assertEqual(destination.read_bytes(), original.read_bytes())
            self.assertNotEqual(destination.stat().st_ino, original.stat().st_ino)

    def test_missing_machine_asset_does_not_stamp_success(self):
        self.machine_fixture()
        (self.root / "assets/prebuilt/strikes/atlas-ter-116n.bin").unlink()
        result = self.run_shell("bin/null-machine-sync", env={"NULL_ROOT": shell_path(self.root)})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "state/stamp").exists())

    def test_failed_hardware_refresh_invalidates_previous_stamp(self):
        self.machine_fixture()
        self.write("state/stamp", "old hardware")
        self.write("bin/machine", '''#!/usr/bin/env bash
case $1 in
 profile) echo profile;;
 check-profile) test -e profile-current;;
 generate) touch profile-current;;
 get) case $2 in interface_strike) echo ter-u16n;; bake_strike) echo ter-112n;; esac;;
esac
''', True)
        atlas = self.root / "assets/prebuilt/strikes/atlas-ter-116n.bin"
        atlas.unlink()
        result = self.run_shell("bin/null-machine-sync", env={"NULL_ROOT": shell_path(self.root)})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "state/stamp").exists())
        self.write("assets/prebuilt/strikes/atlas-ter-116n.bin", "repaired")
        result = self.run_shell("bin/null-machine-sync", env={"NULL_ROOT": shell_path(self.root)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "assets/atlas-interface.bin").read_text(), "repaired")

    def test_package_upgrade_invalidates_surface_stamp(self):
        self.write("state/stamp", "old")
        spec = (ROOT / "packaging/nulllinux.spec").read_text()
        body = spec.split("\n%post\n", 1)[1].split("\n%preun", 1)[0]
        body = re.sub(r"^%systemd_post.*$", "", body, flags=re.M)
        body = body.replace("%{_prefix}/%{name}", shell_path(self.root)).replace("%{version}", "1.0.0")
        body = body.replace("/var/lib/nulllinux/surfaces-placed", shell_path(self.root / "state/stamp"))
        self.command("systemctl", "exit 0\n")
        # Permit removal ONLY of this fixture's stamp. Every other OS path is inert.
        script = 'rm() { case "${!#}" in ' + shlex.quote(shell_path(self.root / "state/stamp")) + ') command rm "$@";; esac; }\n' + body
        result = self.run_shell(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "state/stamp").exists())

    def test_display_manager_enable_failure_is_install_failure(self):
        source = (ROOT / "bin/null-install").read_text()
        section = source.split('head_ "something has to start the desktop"', 1)[1].split('head_ "the GTK theme', 1)[0]
        self.write("usr/lib/systemd/system/sddm.service", "fixture")
        section = section.replace("/usr/lib/", shell_path(self.root / "usr/lib") + "/")
        script = 'APPLY=1\nsay() { :; }; refuse() { exit 1; }\nsystemctl() { return 1; }\n'
        result = self.run_shell(script + section)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_greeter_copy_is_not_success(self):
        self.write("system/sddm-theme/Main.qml", "__NULL_HOSTNAME__")
        code = function("bin/null-system", "cmd_sddm")
        code = code.replace("/etc/", shell_path(self.root / "etc") + "/")
        code = code.replace("/usr/share/", shell_path(self.root / "usr/share") + "/")
        prefix = 'ROOT=' + shlex.quote(shell_path(self.root)) + '\nAPPLY=1\n'
        prefix += 'say() { :; }; head_() { :; }; snapshot() { :; }; backup() { :; }\n'
        prefix += 'refuse() { exit 1; }; sddm() { :; }; systemctl() { :; }; cp() { return 1; }\n'
        result = self.run_shell(prefix + code + '\ncmd_sddm\n')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_backup_rejects_nonexistent_destination_before_copy(self):
        self.write("master/frame.hdr", "master")
        import hashlib
        self.write("master/MANIFEST.sha256", hashlib.sha256(b"master").hexdigest() + "  frame.hdr\n")
        self.write("bin/null-backup", (ROOT / "bin/null-backup").read_text(), True)
        self.command("lsblk", "exit 0\n")
        self.command("df", '[[ -e "${!#}" ]] || exit 1\nprintf "Filesystem\\n/dev/same\\n"\n')
        result = self.run_shell("bin/null-backup missing/destination", env={
            "NULL_ROOT": shell_path(self.root), "NULL_MASTER": shell_path(self.root / "master")})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "missing").exists())

    def firewall(self, validation_error=False, start_ok=False, chroot=False, reapply_ok=True, restore_ok=True):
        self.write("config/nftables/nulllinux.nft", "table inet filter {}")
        self.write("packaging/nulllinux-netfilter-modules.service", "[Unit]")
        code = function("bin/null-system", "cmd_firewall").replace("/etc/", shell_path(self.root / "etc") + "/")
        prefix = 'ROOT=' + shlex.quote(shell_path(self.root)) + '\nAPPLY=1\n'
        prefix += 'VALIDATION_ERROR=' + str(int(validation_error)) + '\n'
        prefix += 'START_OK=' + str(int(start_ok)) + '\nCHROOT=' + str(int(chroot)) + '\n'
        prefix += 'REAPPLY_OK=' + str(int(reapply_ok)) + '\nRESTORE_OK=' + str(int(restore_ok)) + '\n'
        prefix += r'''
say() { :; }; head_() { :; }; snapshot() { :; }; backup() { :; }
install_file() { :; }
refuse() { printf '%s\n' "$*" >&2; exit 1; }
systemd-detect-virt() { [ "$CHROOT" = 1 ]; }
nft() {
  printf '%s\n' "nft $*" >> services
  if [ "$1" = -c ] && [ "$VALIDATION_ERROR" = 1 ]; then
    echo 'Error: Could not process rule: Operation not supported' >&2; return 1
  fi
  if [ "$1" = -f ] && [ "$2" = "$ROOT/config/nftables/nulllinux.nft" ]; then [ "$REAPPLY_OK" = 1 ]; return; fi
  if [ "$1" = list ]; then echo 'policy drop;'; fi
  return 0
}
systemctl() {
  printf '%s\n' "$*" >> services
  case "$*" in
    'is-enabled firewalld.service'|'is-active firewalld.service') return 0;;
    'is-enabled nftables.service') return 1;;
    'start nftables.service'|'restart nftables.service') [ "$START_OK" = 1 ]; return;;
    'restart firewalld.service') [ "$RESTORE_OK" = 1 ]; return;;
  esac
  return 0
}
'''
        return self.run_shell(prefix + code + '\ncmd_firewall\n')

    def test_firewall_start_failure_keeps_previous_firewall_enabled(self):
        result = self.firewall()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "services").read_text()
        self.assertNotRegex(calls, r"disable(?: --now)? firewalld.service")
        self.assertIn("nft list ruleset", calls)
        self.assertRegex(calls, r"nft -f .*/null-firewall\.")

    def test_firewall_kernel_error_is_not_assumed_to_be_a_chroot(self):
        result = self.firewall(validation_error=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if (self.root / "services").exists():
            self.assertNotIn("disable firewalld.service", (self.root / "services").read_text())

    def test_firewall_loads_before_disabling_previous_service(self):
        result = self.firewall(start_ok=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "services").read_text()
        self.assertLess(calls.index("nft list chain inet filter forward"), calls.index("disable --now firewalld.service"))
        self.assertGreater(calls.rindex("nft list chain inet filter forward"), calls.index("disable --now firewalld.service"))

    def test_firewall_stages_only_in_a_confirmed_chroot(self):
        result = self.firewall(validation_error=True, chroot=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "services").read_text()
        self.assertIn("enable nftables.service", calls)
        self.assertNotIn("restart nftables.service", calls)
        self.assertNotIn("disable --now", calls)

    def test_firewall_reapply_failure_restores_previous_service(self):
        result = self.firewall(start_ok=True, reapply_ok=False)
        self.assertNotEqual(result.returncode, 0)
        calls = (self.root / "services").read_text()
        self.assertIn("enable firewalld.service", calls)
        self.assertIn("restart firewalld.service", calls)

    def test_firewall_does_not_claim_failed_rollback_succeeded(self):
        result = self.firewall(start_ok=True, reapply_ok=False, restore_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("restored firewalld", result.stderr)

    def plymouth(self, build_ok=False, complete=True):
        self.write("boot/initramfs-fixture.img", "previous bootable image")
        self.write("theme/nullLinux.plymouth", "new theme")
        self.write("usr/share/plymouth/themes/old/old.plymouth", "previous theme")
        self.write("current-theme", "old")
        pointer = self.root / "usr/share/plymouth/themes/default.plymouth"
        pointer.symlink_to("old/old.plymouth")
        source = function("bin/null-system", "cmd_plymouth")
        branch = source[source.index('  if [ "$APPLY" -eq 1 ] && [ "$FALLBACK_VERIFIED" -eq 1 ]; then'):]
        branch = branch.removesuffix("}")
        branch = re.sub(r"/usr/share/|/boot/|/tmp/", lambda match:
                        shell_path(self.root / match[0].lstrip("/")) + "/", branch)
        (self.root / "tmp").mkdir()
        prefix = 'ROOT=' + shlex.quote(shell_path(self.root)) + '\ntheme="$ROOT/theme"\n'
        prefix += f'APPLY=1\nFALLBACK_VERIFIED=1\nBUILD_OK={int(build_ok)}\nCOMPLETE={int(complete)}\nmodule=two-step\n'
        prefix += r'''
say() { :; }; snapshot() { :; }; backup() { :; }
refuse() { printf '%s\n' "$*" >&2; exit 1; }
uname() { printf 'fixture\n'; }
plymouth-set-default-theme() {
  if [ $# = 0 ]; then cat "$ROOT/current-theme"; else printf '%s' "$1" > "$ROOT/current-theme"; fi
}
dracut() {
  printf '%s\n' "$*" >> "$ROOT/dracut-calls"
  [ "$BUILD_OK" = 1 ] || return 1
  printf 'new candidate image' > "${!#}"
}
lsinitrd() {
  printf '%s\n' "$*" >> "$ROOT/inspect-calls"
  if [ "$COMPLETE" = 1 ]; then
    if [ "${2:-}" = -f ]; then printf 'Theme=nullLinux\n'; else
      printf 'themes/nullLinux/throbber-0001.png\nplymouth/two-step.so\n'; fi
  fi
}
'''
        return self.run_shell(prefix + 'apply_fixture() {\n' + branch + '\n}\napply_fixture\n')

    def test_failed_plymouth_build_does_not_validate_old_image(self):
        result = self.plymouth()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "inspect-calls").exists())
        self.assertEqual((self.root / "boot/initramfs-fixture.img").read_text(), "previous bootable image")
        self.assertEqual((self.root / "current-theme").read_text(), "old")
        self.assertEqual(os.readlink(self.root / "usr/share/plymouth/themes/default.plymouth"), "old/old.plymouth")

    def test_incomplete_plymouth_candidate_preserves_old_image(self):
        result = self.plymouth(build_ok=True, complete=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "boot/initramfs-fixture.img").read_text(), "previous bootable image")
        self.assertEqual((self.root / "current-theme").read_text(), "old")
        self.assertEqual(len((self.root / "dracut-calls").read_text().splitlines()), 1)

    def test_complete_plymouth_candidate_replaces_image_after_validation(self):
        result = self.plymouth(build_ok=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "boot/initramfs-fixture.img").read_text(), "new candidate image")
        self.assertEqual((self.root / "current-theme").read_text(), "nullLinux")
        self.assertNotIn("initramfs-fixture.img", (self.root / "inspect-calls").read_text())

    def test_snapshot_guidance_requires_offline_recovery(self):
        code = function("lib/snapshot.sh", "null_snapshot")
        prefix = 'APPLY=1\nNULL_SNAPDIR=' + shlex.quote(shell_path(self.root / "snapshots")) + '\nSTAMP=fixture\n'
        prefix += 'btrfs() { :; }; say() { printf "%s\\n" "$*"; }; null_snapshot_prune() { :; }\n'
        result = self.run_shell(prefix + code + '\nnull_snapshot install\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("btrfs subvolume delete /", result.stdout)
        self.assertIn("rescue", result.stdout.lower())
        self.assertIn("separate", result.stdout.lower())

    def test_vm_install_lock_supports_a_new_work_directory(self):
        source = (ROOT / "verify/vm-iso-install.sh").read_text()
        start = source.index('if [ "${1:-install}" = install ] || [ "${1:-install}" = boot ]; then')
        section = source[start:source.index("# STOPPING THE GUEST", start)]
        prefix = 'WORK=' + shlex.quote(shell_path(self.root / "fresh-work")) + '\ndie() { exit 1; }\n'
        result = self.run_shell(prefix + section)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "fresh-work/.install.lock").exists())

    def test_vm_http_server_exposes_only_public_files_on_loopback(self):
        source = (ROOT / "verify/vm-iso-install.sh").read_text()
        launch = next(line for line in source.splitlines() if "exec python3 -m http.server" in line)
        self.write("work/id_guest", "PRIVATE fixture key")
        self.write("work/public/install.ks", "kickstart")
        self.write("work/public/testkey.pub", "public fixture key")
        self.command("python3", 'printf "%s\\n" "$PWD" "$@" > "$CAPTURE"\n')
        capture = self.root / "server-call"
        prefix = 'WORK=' + shlex.quote(shell_path(self.root / "work")) + '\nPUBLIC="$WORK/public"\n'
        result = self.run_shell(prefix + launch + '\nwait\n', env={"CAPTURE": str(capture)})
        self.assertEqual(result.returncode, 0, result.stderr)
        args = capture.read_text().splitlines()
        served = Path(args[args.index("--directory") + 1] if "--directory" in args else args[0])
        self.assertEqual(args[args.index("--bind") + 1], "127.0.0.1")
        self.assertFalse((served / "id_guest").exists())
        self.assertTrue((served / "install.ks").exists())

    def test_iso_builder_success_without_artifact_is_failure(self):
        for script, marker in (("bin/null-iso", "if [ $st -eq 0 ] && built="),
                               ("bin/null-installer-iso", "if [ $st -eq 0 ] && iso=")):
            with self.subTest(script=script):
                source = (ROOT / script).read_text()
                tail = source[source.index(marker):]
                (self.root / "results").mkdir(exist_ok=True)
                (self.root / "installer").mkdir(exist_ok=True)
                prefix = "st=0\nWORK=" + shlex.quote(shell_path(self.root)) + '\nOUT="$WORK/installer"\n'
                result = self.run_shell(prefix + tail)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_installer_iso_without_rpms_is_not_published(self):
        self.write("installer/images/boot.iso", "fake boot medium")
        (self.root / "packaging/repo").mkdir(parents=True)
        source = (ROOT / "bin/null-installer-iso").read_text()
        tail = source[source.index("if [ $st -eq 0 ] && iso="):]
        prefix = 'st=0\nROOT=' + shlex.quote(shell_path(self.root)) + '\nWORK="$ROOT"\nOUT="$WORK/installer"\nNAME=nulllinux\nVERSION=test\n'
        result = self.run_shell(prefix + tail)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "nulllinux-installer-test.iso").exists())

    def test_shipped_kickstart_strips_test_credentials_and_requires_confirmation(self):
        ks = self.write("interactive.ks", (ROOT / "packaging/nulllinux-install.ks").read_text())
        source = (ROOT / "bin/null-installer-iso").read_text()
        for name in ("ASK", "STRIP"):
            code = re.search(r"<<'" + name + r"'[^\n]*\n(.*?)\n" + name, source, re.S).group(1)
            result = subprocess.run(["python3", "-c", code, str(ks)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        generated = ks.read_text()
        self.assertNotRegex(generated, r"(?m)^(?:user --name|rootpw |sshpw |clearpart |zerombr$)")
        self.assertNotIn("NULLLINUX_TEST_KEY", generated)
        self.assertIn("%include /tmp/nulllinux-answers.ks", generated)
        self.assertIn("--erroronfail", generated)
        self.assertLess(generated.index("rm -f /tmp/nulllinux-answers.ks"), generated.index("OPENVT=$INST/openvt"))

    def test_failed_menu_rewrite_preserves_previous_live_iso(self):
        self.write("results/images/boot.iso", "new unpatched medium")
        self.write("nulllinux-test.iso", "previous complete medium")
        self.command("mkksiso", "exit 1\n")
        source = (ROOT / "bin/null-iso").read_text()
        tail = source[source.index("if [ $st -eq 0 ] && built="):]
        prefix = 'st=0\nWORK=' + shlex.quote(shell_path(self.root)) + '\nNAME=nulllinux\nVERSION=test\nREL=44\n'
        result = self.run_shell(prefix + tail)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "nulllinux-test.iso").read_text(), "previous complete medium")


if __name__ == "__main__":
    unittest.main()
