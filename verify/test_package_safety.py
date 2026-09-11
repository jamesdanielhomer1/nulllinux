#!/usr/bin/env python3
"""Packaging regressions: only local Git fixtures and fake RPM tools run."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import tarfile
import unittest
import zlib
from compression import zstd

ROOT = Path(__file__).resolve().parents[1]
STRIKES = [(12, 6), (14, 8), (16, 8), (18, 10), (20, 10), (22, 11), (24, 12), (28, 14), (32, 16)]


class PackageSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="null-package-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = os.environ.copy()
        self.env.pop("NULL_TEST_MACHINE", None)
        self.env.update(NULL_ROOT=str(self.root), NULL_RPM_TOP=str(self.root / "rpmbuild"),
                        PATH=str(self.root / "commands") + os.pathsep + os.environ["PATH"])
        self.write("bin/null-package", (ROOT / "bin/null-package").read_bytes(), True)
        if (ROOT / "packaging/prebuilt.py").exists():
            self.write("packaging/prebuilt.py", (ROOT / "packaging/prebuilt.py").read_bytes())
        self.write("packaging/nulllinux.spec", b"Name: nulllinux\nVersion: 1.0.0\nRelease: 1\nRequires: alpha\n\n%description\nfixture\n")
        self.write("packages/fedora/base.list", b"alpha\n")
        self.write("marker", b"committed source")
        self.write(".gitignore", b"assets/prebuilt/\ncommands/\nrpmbuild/\npackaging/repo/\nbuilder-called\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.command("rpmspec", 'awk \'/^Version:/ {print $2; exit}\' "${!#}"\n')
        self.command("rpmbuild", r'''
out="$NULL_RPM_TOP/RPMS"
while [ $# -gt 0 ]; do
  if [ "$1" = --define ] && [[ "$2" == "_rpmdir "* ]]; then out=${2#_rpmdir }; shift; fi
  shift
done
mkdir -p "$out/x86_64"
printf 'current package\n' > "$out/x86_64/nulllinux-1.0.0-1.x86_64.rpm"
printf 'called\n' > "$NULL_ROOT/builder-called"
''')
        self.command("createrepo_c", '[[ "${MOCK_REPO_FAIL:-0}" != 1 ]] || exit 1\nmkdir -p "${!#}/repodata"\nprintf metadata > "${!#}/repodata/repomd.xml"\n')

    def write(self, rel, data, executable=False):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        if executable:
            p.chmod(0o755)
        return p

    def command(self, name, body):
        self.write("commands/" + name, ("#!/usr/bin/env bash\nset -eu\n" + body).encode(), True)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True, capture_output=True, text=True)

    def run_package(self, *args, extra_env=None):
        return subprocess.run(["bash", "bin/null-package", *args], cwd=self.root,
                              env=dict(self.env, **(extra_env or {})), capture_output=True,
                              text=True, timeout=30)

    def prebuilts(self):
        p = "assets/prebuilt/"
        palette = bytes(range(256)) * 3
        self.write(p + "strikes/palette.bin", palette)
        self.write(p + "strikes/palette.json", b'{"entries":256,"roles":{}}')
        master = b"NLHM" + struct.pack("<HHHHHfffQ", 1, 1, 1, 1, 24, 0, 100, 1, 4)
        self.write(p + "master.hero", master + zstd.compress(struct.pack("<ee", 1, 2000)))
        self.write(p + "master.hero.provenance.json", json.dumps({
            "format": 1, "master_sha256": hashlib.sha256((self.root / p / "master.hero").read_bytes()).hexdigest(),
            "source_bake": {"temperature_model": "linear-luminance-weighted-v1", "cols": 1, "rows": 1, "frames": 1, "fps": 24},
            "tone": [0, 100, 1]}).encode())
        for height, width in STRIKES:
            name = f"ter-1{height}n"
            font_hash = hashlib.sha256(name.encode()).digest()
            ramp = {"ramp": " .", "font_sha256": font_hash.hex(), "cell": [width, height], "coverage": [0, 1]}
            self.write(p + f"strikes/ramp-{name}.json", json.dumps(ramp).encode())
            atlas = b"RATL" + struct.pack("<HHHH", 1, width, height, 2) + font_hash
            atlas += struct.pack("<HIHIH", 2, 32, 0, 46, 1) + bytes(2 * width * height)
            self.write(p + f"strikes/atlas-{name}.bin", atlas)
            self.write(p + f"{name}/ramp-bake.json", json.dumps(ramp).encode())
            cells = b"RCEL" + struct.pack("<HHHHH", 1, 1, 1, 1, 24) + b"\x02 ."
            cells += struct.pack("<H", 256) + palette + struct.pack("<Q", 2) + zstd.compress(b"\x01\x01")
            for file in ("master.cells", "target-2.cells", "target-4.cells", "tty.cells", "logo.cells"):
                self.write(p + f"{name}/{file}", cells)
        for file in ("config/sway/colours.conf", "config/foot/foot.ini", "config/shell/colours.sh",
                     "config/gtk-3.0/gtk.css", "config/gtk-3.0/settings.ini",
                     "config/gtk-4.0/gtk.css", "config/gtk-4.0/settings.ini", "icons/index.theme"):
            self.write(p + "theme/" + file, b"theme")
        self.write(p + "theme/icons/scalable/fixture.svg", b'<svg xmlns="http://www.w3.org/2000/svg"/>')
        for file in ("plymouth-theme/nullLinux.plymouth", "sddm-theme/theme.conf", "sddm-theme/metadata.desktop"):
            self.write(p + "boot/" + file, b"theme")
        self.write(p + "boot/sddm-theme/Main.qml", b"property int frameCount: 1\n")
        for file in ("plymouth-theme/throbber-0001.png", "plymouth-theme/lock.png", "plymouth-theme/box.png",
                     "plymouth-theme/entry.png", "plymouth-theme/bullet.png", "plymouth-theme/keyboard.png", "sddm-theme/f00.png"):
            self.write(p + "boot/" + file, self.png())
        helper = self.root / "packaging/prebuilt.py"
        if helper.exists():
            result = subprocess.run(["python3", str(helper), "--write-manifest", str(self.root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @staticmethod
    def png(pixels=b"\x00\x00"):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))

    def test_incomplete_png_cannot_receive_manifest(self):
        self.prebuilts()
        for data in (self.png()[:24], self.png()[:-1], self.png() + b"trailing", self.png(b""),
                     self.png().replace(b"IDAT", b"JDAT", 1)):
            with self.subTest(data=data):
                self.write("assets/prebuilt/boot/sddm-theme/f00.png", data)
                result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"),
                                         "--write-manifest", str(self.root)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_empty_prebuilts_never_reach_the_builder(self):
        (self.root / "assets/prebuilt").mkdir(parents=True)
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "builder-called").exists())

    def test_only_current_build_is_published(self):
        self.prebuilts()
        self.write("rpmbuild/RPMS/x86_64/nulllinux-9.0.0-1.x86_64.rpm", b"stale")
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(p.name for p in (self.root / "packaging/repo").glob("*.rpm")), ["nulllinux-1.0.0-1.x86_64.rpm"])

    def test_prebuilt_archive_normalizes_windows_permissions(self):
        self.prebuilts()
        for path in (self.root / "assets/prebuilt").rglob("*"):
            path.chmod(0o777)
        (self.root / "assets/prebuilt").chmod(0o777)
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tarfile.open(self.root / "rpmbuild/SOURCES/nulllinux-prebuilt-1.0.0.tar.gz") as archive:
            for member in archive:
                self.assertEqual(member.mode, 0o755 if member.isdir() else 0o644, member.name)

    def test_rpm_staging_removes_write_access_and_keeps_programs_executable(self):
        for relative in ("bin/command", "verify/check.sh", "assets/prebuilt/theme/config/data.ini", "config/data.ini"):
            self.write("stage/opt/nulllinux/" + relative, b"fixture")
        stage = self.root / "stage"
        for path in stage.rglob("*"):
            path.chmod(0o777)
        (stage / "opt/nulllinux/config/data.ini").chmod(0o666)
        commands = [line for line in (ROOT / "packaging/nulllinux.spec").read_text().splitlines()
                    if line.startswith("find %{buildroot}")]
        self.assertEqual(len(commands), 3)
        script = "\n".join(commands).replace("%{buildroot}", str(stage)).replace("%{_prefix}", "/opt").replace("%{name}", "nulllinux")
        subprocess.run(["bash", "-ec", script], check=True)
        for path in stage.rglob("*"):
            expected = 0o755 if path.is_dir() or path.name in {"command", "check.sh"} else 0o644
            self.assertEqual(path.stat().st_mode & 0o777, expected, path)

    def test_failed_metadata_preserves_previous_repository(self):
        self.prebuilts()
        self.write("packaging/repo/nulllinux-old.rpm", b"previous good package")
        result = self.run_package(extra_env={"MOCK_REPO_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        previous = self.root / "packaging/repo/nulllinux-old.rpm"
        self.assertTrue(previous.exists(), result.stdout + result.stderr)
        self.assertEqual(previous.read_bytes(), b"previous good package")

    def test_dirty_override_uses_committed_version_spec_and_source(self):
        self.prebuilts()
        original = (self.root / "packaging/nulllinux.spec").read_text()
        (self.root / "packaging/nulllinux.spec").write_text(original.replace("1.0.0", "9.9.9"))
        (self.root / "marker").write_text("uncommitted source")
        result = self.run_package("--allow-dirty")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "rpmbuild/SOURCES/nulllinux-1.0.0.tar.gz").exists())
        self.assertIn("Version: 1.0.0", (self.root / "rpmbuild/SPECS/nulllinux.spec").read_text())
        self.assertIn("Version: 9.9.9", (self.root / "packaging/nulllinux.spec").read_text())
        with tarfile.open(self.root / "rpmbuild/SOURCES/nulllinux-1.0.0.tar.gz") as archive:
            self.assertEqual(archive.extractfile("nulllinux-1.0.0/marker").read(), b"committed source")

    def test_dirty_override_uses_committed_validator(self):
        self.prebuilts()
        self.write("packaging/prebuilt.py", b"raise SystemExit('uncommitted helper')\n")
        result = self.run_package("--allow-dirty")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tampered_prebuilt_is_not_packaged(self):
        self.prebuilts()
        self.write("assets/prebuilt/strikes/atlas-ter-112n.bin", b"truncated")
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "builder-called").exists())

    def test_legacy_master_cannot_receive_release_manifest(self):
        self.prebuilts()
        p = self.root / "assets/prebuilt/master.hero.provenance.json"
        document = json.loads(p.read_text())
        document["source_bake"]["temperature_model"] = "legacy-unverified"
        p.write_text(json.dumps(document))
        result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"), "--write-manifest", str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nonfinite_master_cannot_receive_manifest(self):
        self.prebuilts()
        p = self.root / "assets/prebuilt/master.hero"
        header = p.read_bytes()[:34]
        for value in (float("nan"), float("inf"), -1):
            with self.subTest(value=value):
                p.write_bytes(header + zstd.compress(struct.pack("<ee", value, 2000)))
                sidecar = p.with_suffix(".hero.provenance.json")
                document = json.loads(sidecar.read_text())
                document["master_sha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
                sidecar.write_text(json.dumps(document))
                result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"),
                                         "--write-manifest", str(self.root)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_master_geometry_must_match_completed_bake(self):
        self.prebuilts()
        p = self.root / "assets/prebuilt/master.hero.provenance.json"
        doc = json.loads(p.read_text())
        doc["source_bake"]["frames"] = 240
        p.write_text(json.dumps(doc))
        result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"), "--write-manifest", str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cells_timing_must_match_master(self):
        self.prebuilts()
        p = self.root / "assets/prebuilt/ter-112n/master.cells"
        data = bytearray(p.read_bytes())
        struct.pack_into("<H", data, 12, 30)
        p.write_bytes(data)
        result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"), "--write-manifest", str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_icon_theme_must_contain_icons(self):
        self.prebuilts()
        (self.root / "assets/prebuilt/theme/icons/scalable/fixture.svg").unlink()
        result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"), "--write-manifest", str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_ramp_cannot_receive_manifest(self):
        self.prebuilts()
        base = self.root / "assets/prebuilt"
        path = base / "strikes/ramp-ter-112n.json"
        original = json.loads(path.read_text())
        palette = (base / "strikes/palette.bin").read_bytes()
        for glyphs, coverage in ((" ", [0]), (" .", [0]), (" .", [0, float("nan")]),
                                 (" .", [0.8, 0.2]), (" .", [-0.1, 0.5])):
            with self.subTest(glyphs=glyphs, coverage=coverage):
                doc = dict(original, ramp=glyphs, coverage=coverage)
                path.write_text(json.dumps(doc))
                (base / "ter-112n/ramp-bake.json").write_text(json.dumps(doc))
                cells = b"RCEL" + struct.pack("<HHHHHB", 1, 1, 1, 1, 24, len(glyphs)) + glyphs.encode()
                cells += struct.pack("<H", 256) + palette + struct.pack("<Q", 2) + zstd.compress(b"\x00\x01")
                for name in ("master", "target-2", "target-4", "tty", "logo"):
                    (base / f"ter-112n/{name}.cells").write_bytes(cells)
                result = subprocess.run(["python3", str(self.root / "packaging/prebuilt.py"), "--write-manifest", str(self.root)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
