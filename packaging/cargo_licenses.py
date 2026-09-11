#!/usr/bin/env python3
"""Collect notices for the locked Linux renderer build, without network access.

The current crate alternatives are selected under MIT. Native zstd uses its
BSD-3-Clause alternative; embedded Wayland protocols include MIT and
HPND-sell-variant terms. Re-audit embedded material when updating Cargo.lock.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib
import xml.etree.ElementTree as ET

MIT_CHOICES = {
    "MIT", "MIT OR Apache-2.0", "MIT/Apache-2.0", "Apache-2.0 OR MIT",
    "Zlib OR Apache-2.0 OR MIT", "MIT OR Apache-2.0 OR Zlib", "Unlicense OR MIT",
    "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT",
}
NOTICE_NAME = re.compile(r"^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|UNLICENSE)(?:$|[._-])", re.I)
AUDITED_ZSTD = "2.0.16+zstd.1.5.7"
TOOLCHAIN_NOTICES = (
    "licenses/rust/LICENSE-MIT", "licenses/rust/LICENSE-APACHE",
    "doc/rust/COPYRIGHT-library.html", "doc/rust/licenses/Unicode-3.0.txt",
    "licenses/rust-std-static/cargo-vendor.txt",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def collect(metadata, lock_path, target):
    lock_bytes = lock_path.read_bytes()
    locked = {(p["name"], p["version"], p.get("source")): p
              for p in tomllib.loads(lock_bytes.decode())["package"]}
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    root = metadata["resolve"]["root"]
    require(root in nodes, "Cargo metadata must identify the renderer package")

    def reachable(runtime):
        seen, pending = set(), [root]
        while pending:
            ident = pending.pop()
            if ident in seen:
                continue
            seen.add(ident)
            for edge in nodes[ident]["deps"]:
                kinds = [kind["kind"] for kind in edge["dep_kinds"]]
                if not any(k is None if runtime else k != "dev" for k in kinds):
                    continue
                dependency = packages[edge["pkg"]]
                if runtime and any("proc-macro" in t["kind"] for t in dependency["targets"]):
                    continue
                pending.append(edge["pkg"])
        return seen

    runtime = reachable(True)
    files, inventory = {}, []
    for ident in sorted(reachable(False) - {root}, key=lambda i: (packages[i]["name"], packages[i]["version"])):
        package = packages[ident]
        name, version, source = (package[k] for k in ("name", "version", "source"))
        label = name + "-" + version
        require(re.fullmatch(r"[A-Za-z0-9_.+-]+", label), "invalid crate directory name")
        require(source and source.startswith("registry+"), f"{label}: non-registry source needs license review")
        entry = locked.get((name, version, source), {})
        checksum = entry.get("checksum", "")
        require(re.fullmatch(r"[0-9a-f]{64}", checksum), f"{label}: missing lock checksum")
        license = package.get("license")
        scope = "runtime" if ident in runtime else "build/proc-macro"
        if license in MIT_CHOICES:
            selected = "MIT"
        elif license == "(MIT OR Apache-2.0) AND Unicode-3.0" and scope == "build/proc-macro":
            selected = "MIT AND Unicode-3.0"
        else:
            raise ValueError(f"{label}: license review required for {license}")
        directory = Path(package["manifest_path"]).resolve().parent
        candidates = {p for p in directory.rglob("*") if p.is_file() and NOTICE_NAME.match(p.name)}
        if package.get("license_file"):
            candidates.add(directory / package["license_file"])
        if name.startswith("wayland-"):
            protocols = {p for p in directory.rglob("*.xml") if ET.parse(p).find(".//copyright") is not None}
            if name in {"wayland-client", "wayland-protocols", "wayland-protocols-wlr"}:
                require(protocols, f"{label}: missing protocol copyright notices")
            # Preserve exact XML so copyright text, entities and context survive.
            candidates.update(protocols)
        embedded = []
        if name == "zstd-sys":
            require(version == AUDITED_ZSTD, f"{label}: native source update needs license review")
            for relative in ("LICENSE.BSD-3-Clause", "zstd/LICENSE"):
                require((directory / relative).is_file(), f"{label}: missing zstd notice {relative}")
            native = {p for p in (directory / "zstd/lib").rglob("*") if p.is_file() and p.suffix in {".c", ".h", ".S"}}
            require(native, f"{label}: missing bundled zstd native source notices")
            # Full source preserves per-file holders/terms, including xxhash and threading.
            candidates.update(native)
            embedded.append({"material": "native zstd", "selected_license": "BSD-3-Clause"})
        if name in {"wayland-client", "wayland-protocols", "wayland-protocols-wlr"}:
            embedded.append({"material": "protocol XML", "license_forms": ["MIT", "HPND-sell-variant"]})
        copied, mit_found = {}, False
        for path in sorted(candidates):
            resolved = path.resolve()
            require(resolved.is_relative_to(directory), f"{label}: notice outside crate: {path.name}")
            data = resolved.read_bytes()
            require(data, f"{label}: empty notice {path.name}")
            relative = path.relative_to(directory).as_posix()
            files[label + "/" + relative] = data
            copied[relative] = sha(data)
            lower = data.lower()
            mit_found |= b"permission is hereby granted" in lower and b"the software is provided" in lower
        require(mit_found, f"{label}: missing MIT notice text")
        if "Unicode-3.0" in selected:
            require(any("unicode" in p.lower() for p in copied), f"{label}: missing Unicode notice")
        inventory.append({"name": name, "version": version, "source": source, "checksum": checksum,
                          "declared_license": license, "selected_license": selected, "scope": scope,
                          "embedded": embedded, "files": copied})
    require(inventory, "renderer has no collected dependency notices")
    return {"format": 1, "target": target, "cargo_lock_sha256": sha(lock_bytes), "packages": inventory}, files


def collect_toolchain(bundle, share):
    """Fedora supplies stdlib terms; its exact vendor-version notices are pinned."""
    pinned = json.loads((bundle / "MANIFEST.json").read_text())
    require(pinned.get("format") == 1, "unsupported standard-library notice inventory")
    recorded = sorted(f"{p['name']} v{p['version']}" for p in pinned["packages"])
    installed = sorted(line.strip() for line in (share / TOOLCHAIN_NOTICES[-1]).read_text().splitlines() if line.strip())
    require(recorded == installed, "Rust standard-library vendor inventory changed; refresh reviewed notices")
    files = {}
    for package in pinned["packages"]:
        label = package["name"] + "-" + package["version"]
        for relative, expected in package["files"].items():
            path = (bundle / label / relative).resolve()
            require(path.is_relative_to(bundle.resolve()), "toolchain notice outside bundle")
            data = path.read_bytes()
            require(sha(data) == expected, f"{label}/{relative}: standard-library notice hash mismatch")
            files[f"toolchain/vendor/{label}/{relative}"] = data
    for relative in TOOLCHAIN_NOTICES:
        data = (share / relative).read_bytes()
        require(data, f"empty Rust toolchain notice: {relative}")
        files["toolchain/fedora/" + relative] = data
    files["toolchain/vendor/MANIFEST.json"] = (bundle / "MANIFEST.json").read_bytes()
    return {"vendor_notice_source": pinned["source_package"],
            "selected_licenses": ["MIT", "Unicode-3.0"],
            "files": {p: sha(data) for p, data in sorted(files.items())}}, files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest-path", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        require(not args.out.exists(), f"notice destination already exists: {args.out}")
        result = subprocess.run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1",
                                 "--filter-platform", args.target, "--manifest-path", str(args.manifest_path)],
                                check=True, capture_output=True, text=True)
        document, files = collect(json.loads(result.stdout), args.manifest_path.parent / "Cargo.lock", args.target)
        sysroot = subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip()
        require(Path(sysroot).resolve() == Path("/usr"), "notice collection requires the Fedora Rust toolchain")
        toolchain, toolchain_files = collect_toolchain(Path(__file__).resolve().parents[1] / "licenses/rust-stdlib", Path("/usr/share"))
        toolchain["rustc_version"] = subprocess.check_output(["rustc", "--version", "--verbose"], text=True).strip()
        document["toolchain"] = toolchain
        files.update(toolchain_files)
        args.out.mkdir(parents=True)
        for relative, data in sorted(files.items()):
            path = args.out / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (args.out / "MANIFEST.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
        (args.out / "README").write_text(__doc__ + "\n\nThe inventory includes build/proc-macro dependencies as well as runtime\n"
                                       "dependencies. Keeping an alternative license text is not a claim\n"
                                       "that the package selects every upstream licensing alternative.\n")
        print(f"Cargo notices collected: {len(document['packages'])} crates, {len(files)} files")
        return 0
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"cargo-licenses: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
