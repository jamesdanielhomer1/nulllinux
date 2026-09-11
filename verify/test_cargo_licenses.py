#!/usr/bin/env python3
"""Notice collection uses synthetic metadata and temporary registry files only."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cargo_licenses", ROOT / "packaging/cargo_licenses.py")
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
MIT = b"Copyright Fixture\nPermission is hereby granted, free of charge\nTHE SOFTWARE IS PROVIDED AS IS\n"


class CargoNotices(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="null-license-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.packages = [{"id": "root", "name": "fixture", "version": "1", "source": None,
                          "manifest_path": str(self.root / "Cargo.toml"), "targets": []}]
        self.nodes = [{"id": "root", "deps": []}]
        self.lock = []

    def package(self, name="dependency", version="1.0", kind=None, proc_macro=False):
        ident = name + "@" + version
        directory = self.root / ident
        directory.mkdir()
        (directory / "LICENSE-MIT").write_bytes(MIT)
        package = {"id": ident, "name": name, "version": version, "source": "registry+fixture",
                   "license": "MIT OR Apache-2.0", "license_file": None,
                   "manifest_path": str(directory / "Cargo.toml"),
                   "targets": [{"kind": ["proc-macro" if proc_macro else "lib"]}]}
        self.packages.append(package)
        self.nodes.append({"id": ident, "deps": []})
        self.nodes[0]["deps"].append({"pkg": ident, "dep_kinds": [{"kind": kind}]})
        self.lock.append({"name": name, "version": version, "source": "registry+fixture", "checksum": "ab" * 32})
        return directory, package

    def collect(self):
        metadata = {"packages": self.packages, "resolve": {"root": "root", "nodes": self.nodes}}
        lock = self.root / "Cargo.lock"
        lock.write_text("version = 4\n" + "".join("\n[[package]]\n" + "".join(f'{k} = {json.dumps(v)}\n' for k, v in p.items()) for p in self.lock))
        return collector.collect(metadata, lock, "x86_64-unknown-linux-gnu")

    def test_complete_notices_are_deterministic_and_identify_the_lock(self):
        directory, _ = self.package()
        (directory / "NOTICE").write_bytes(b"Additional attribution\r\n")
        document, files = self.collect()
        again, same = self.collect()
        self.assertEqual((document, files), (again, same))
        self.assertEqual(document["cargo_lock_sha256"], hashlib.sha256((self.root / "Cargo.lock").read_bytes()).hexdigest())
        self.assertEqual(document["packages"][0]["scope"], "runtime")
        self.assertEqual(files["dependency-1.0/NOTICE"], b"Additional attribution\r\n")
        self.assertNotIn(str(self.root), json.dumps(document))

    def test_build_and_proc_macro_notices_are_marked_separately(self):
        self.package("build-helper", kind="build")
        self.package("macro", proc_macro=True)
        document, _ = self.collect()
        self.assertEqual([p["scope"] for p in document["packages"]], ["build/proc-macro"] * 2)

    def test_missing_mit_text_fails(self):
        directory, _ = self.package()
        (directory / "LICENSE-MIT").unlink()
        (directory / "NOTICE").write_text("Attribution alone is not the license.")
        with self.assertRaisesRegex(ValueError, "MIT notice"):
            self.collect()

    def test_missing_lock_checksum_and_unknown_license_fail(self):
        _, package = self.package()
        self.lock[0].pop("checksum")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.collect()
        self.lock[0]["checksum"] = "ab" * 32
        package["license"] = "GPL-3.0-only"
        with self.assertRaisesRegex(ValueError, "license review"):
            self.collect()

    def test_declared_notice_cannot_escape_crate(self):
        _, package = self.package()
        package["license_file"] = "../outside"
        (self.root / "outside").write_bytes(MIT)
        with self.assertRaisesRegex(ValueError, "outside crate"):
            self.collect()

    def test_protocol_copyright_is_preserved_with_exact_xml(self):
        directory, _ = self.package("wayland-client")
        xml = b'<protocol name="fixture"><copyright>Copyright A &amp; B\nPermission terms</copyright></protocol>\n'
        (directory / "wayland.xml").write_bytes(xml)
        _, files = self.collect()
        self.assertEqual(files["wayland-client-1.0/wayland.xml"], xml)

    def test_native_zstd_notice_and_source_headers_are_preserved(self):
        directory, _ = self.package("zstd-sys", "2.0.16+zstd.1.5.7")
        (directory / "zstd/lib/common").mkdir(parents=True)
        (directory / "zstd/LICENSE").write_bytes(b"Native BSD license")
        (directory / "LICENSE.BSD-3-Clause").write_bytes(b"Bindings BSD license")
        native = b"/* Copyright Native Author; BSD terms */\nint fixture;\n"
        (directory / "zstd/lib/common/xxhash.h").write_bytes(native)
        _, files = self.collect()
        self.assertEqual(files["zstd-sys-2.0.16+zstd.1.5.7/zstd/lib/common/xxhash.h"], native)
        (directory / "zstd/LICENSE").unlink()
        with self.assertRaisesRegex(ValueError, "zstd"):
            self.collect()

    def test_toolchain_bundle_requires_matching_vendor_list_and_notice_hashes(self):
        bundle, share = self.root / "bundle", self.root / "share"
        (bundle / "dependency-1.0").mkdir(parents=True)
        (bundle / "dependency-1.0/LICENSE").write_bytes(MIT)
        document = {"format": 1, "source_package": "fixture", "packages": [
            {"name": "dependency", "version": "1.0", "files": {"LICENSE": hashlib.sha256(MIT).hexdigest()}}]}
        (bundle / "MANIFEST.json").write_text(json.dumps(document))
        for path in collector.TOOLCHAIN_NOTICES:
            destination = share / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"Exact toolchain notice")
        vendor = share / "licenses/rust-std-static/cargo-vendor.txt"
        vendor.write_text("dependency v1.0\n")
        result, files = collector.collect_toolchain(bundle, share)
        self.assertEqual(files["toolchain/vendor/dependency-1.0/LICENSE"], MIT)
        self.assertIn("toolchain/fedora/doc/rust/COPYRIGHT-library.html", files)
        vendor.write_text("dependency v2.0\n")
        with self.assertRaisesRegex(ValueError, "vendor inventory changed"):
            collector.collect_toolchain(bundle, share)
        vendor.write_text("dependency v1.0\n")
        (bundle / "dependency-1.0/LICENSE").write_bytes(b"truncated")
        with self.assertRaisesRegex(ValueError, "notice hash"):
            collector.collect_toolchain(bundle, share)


if __name__ == "__main__":
    unittest.main()
