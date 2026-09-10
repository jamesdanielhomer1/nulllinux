#!/usr/bin/env python3
"""Validate the shipped assets and bind them to their generating source.

null-prebake writes the manifest only after a successful bake. null-package
checks it against its archived source revision before invoking rpmbuild.
Only Python's standard library is needed (Fedora's Python 3.14 supplies zstd).
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
import zlib
from compression import zstd

STRIKES = {f"ter-1{h}n": (w, h) for h, w in
           [(12, 6), (14, 8), (16, 8), (18, 10), (20, 10), (22, 11), (24, 12), (28, 14), (32, 16)]}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def sources(root):
    paths = set()
    for pattern in ("bake/**/*.py", "bake/gpu/src/*", "render/src/**/*.rs", "bin/machine", "bin/null-prebake"):
        paths.update(p for p in root.glob(pattern) if p.is_file())
    return {p.relative_to(root).as_posix(): digest(p) for p in sorted(paths)}


def payload(body, expected, label):
    require(0 < expected <= 512 * 1024 * 1024, f"{label}: invalid payload size {expected}")
    decoder = zstd.ZstdDecompressor()
    data = decoder.decompress(body, max_length=expected + 1)
    require(decoder.eof and not decoder.unused_data and len(data) == expected,
            f"{label}: truncated, oversized or trailing compressed payload")
    return data


def png(image, label):
    """Check complete, non-interlaced PNGs emitted by our boot-image producer."""
    require(image[:8] == b"\x89PNG\r\n\x1a\n", f"{label}: invalid PNG signature")
    offset, header, ended, data_ended = 8, None, False, False
    compressed = bytearray()
    palette = False
    while offset < len(image):
        require(offset + 12 <= len(image), f"{label}: truncated PNG chunk")
        size = struct.unpack_from(">I", image, offset)[0]
        kind = image[offset + 4:offset + 8]
        end = offset + 12 + size
        require(end <= len(image), f"{label}: truncated PNG chunk body")
        body = image[offset + 8:end - 4]
        require(zlib.crc32(kind + body) == struct.unpack_from(">I", image, end - 4)[0],
                f"{label}: PNG chunk checksum mismatch")
        require(header is not None or kind == b"IHDR", f"{label}: PNG header must be first")
        if kind == b"IHDR":
            require(header is None and size == 13, f"{label}: invalid PNG header")
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            require(not compressed and 0 < size <= 768 and size % 3 == 0, f"{label}: invalid PNG palette")
            palette = True
        elif kind == b"IDAT":
            require(not data_ended, f"{label}: nonconsecutive PNG image data")
            compressed.extend(body)
        elif kind == b"IEND":
            require(size == 0 and end == len(image), f"{label}: invalid PNG end or trailing data")
            ended = True
        else:
            require(kind[0] & 32, f"{label}: unsupported critical PNG chunk")
        if compressed and kind != b"IDAT":
            data_ended = True
        offset = end
    require(header is not None and ended and compressed, f"{label}: incomplete PNG")
    width, height, depth, color, compression, filtering, interlace = header
    depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
    require(width > 0 and height > 0 and depth in depths.get(color, ()) and
            compression == filtering == interlace == 0, f"{label}: invalid/unsupported PNG dimensions or format")
    require(color != 3 or palette, f"{label}: indexed PNG has no palette")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    row = (width * depth * channels + 7) // 8 + 1
    expected = row * height
    require(expected <= 512 * 1024 * 1024, f"{label}: oversized PNG dimensions")
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed, expected + 1)
    require(decoder.eof and not decoder.unused_data and len(pixels) == expected,
            f"{label}: truncated, oversized or trailing PNG pixels")
    require(all(pixels[i] <= 4 for i in range(0, expected, row)), f"{label}: invalid PNG row filter")


def validate(prebuilt):
    def read(rel):
        path = prebuilt / rel
        require(path.is_file() and path.stat().st_size > 0, f"missing or empty {rel}")
        return path.read_bytes()

    palette = read("strikes/palette.bin")
    require(len(palette) == 768, "palette must have 256 RGB entries")
    require(json.loads(read("strikes/palette.json"))["entries"] == 256, "palette metadata disagrees")
    master = read("master.hero")
    require(master[:4] == b"NLHM" and len(master) >= 34, "invalid master.hero header")
    version, cols, rows, frames, fps = struct.unpack_from("<HHHHH", master, 4)
    tone = struct.unpack_from("<fff", master, 14)
    require(version == 1 and min(cols, rows, frames, fps) > 0, "invalid master dimensions/version")
    require(all(math.isfinite(x) for x in tone) and 0 <= tone[0] < tone[1] <= 100 and tone[2] > 0,
            "invalid master tone curve")
    raw_len = struct.unpack_from("<Q", master, 26)[0]
    require(raw_len == cols * rows * frames * 4, "master payload length disagrees with dimensions")
    master_pixels = payload(master[34:], raw_len, "master.hero")
    require(all(math.isfinite(value) and value >= 0 for (value,) in struct.iter_unpack("<e", master_pixels)),
            "master.hero: nonfinite or negative sample")
    del master_pixels
    provenance = json.loads(read("master.hero.provenance.json"))
    require(provenance.get("format") == 1 and provenance.get("master_sha256") == hashlib.sha256(master).hexdigest(),
            "master provenance does not identify this master")
    require(provenance.get("source_bake", {}).get("temperature_model") == "linear-luminance-weighted-v1",
            "legacy or unverified HDR master cannot be packaged; produce a corrected bake")
    completed = provenance["source_bake"]
    require(tuple(completed.get(key) for key in ("cols", "rows", "frames", "fps")) == (cols, rows, frames, fps),
            "packed master geometry/timing differs from its completed HDR bake")
    master_frames, master_fps = frames, fps

    for strike, cell in STRIKES.items():
        ramp = json.loads(read(f"strikes/ramp-{strike}.json"))
        require(tuple(ramp["cell"]) == cell and len(ramp["ramp"]) >= 2 and len(ramp["ramp"].encode("utf-8")) <= 255,
                f"{strike}: invalid ramp geometry")
        coverage = ramp["coverage"]
        require(len(coverage) == len(ramp["ramp"]) and all(math.isfinite(c) and 0 <= c <= 1 for c in coverage)
                and all(a < b for a, b in zip(coverage, coverage[1:])), f"{strike}: invalid ramp coverage")
        atlas = read(f"strikes/atlas-{strike}.bin")
        require(atlas[:4] == b"RATL" and len(atlas) >= 46, f"{strike}: invalid atlas header")
        version, width, height, count = struct.unpack_from("<HHHH", atlas, 4)
        mapped = struct.unpack_from("<H", atlas, 44)[0]
        require(version == 1 and (width, height) == cell and count > 0 and mapped > 0,
                f"{strike}: invalid atlas geometry")
        require(len(atlas) == 46 + mapped * 6 + count * width * height,
                f"{strike}: incomplete atlas")
        require(atlas[12:44].hex() == ramp["font_sha256"], f"{strike}: atlas/ramp font mismatch")
        entries = [struct.unpack_from("<IH", atlas, 46 + i * 6) for i in range(mapped)]
        require(len({cp for cp, _ in entries}) == mapped and all(index < count for _, index in entries),
                f"{strike}: invalid atlas index")
        require(set(map(ord, ramp["ramp"])).issubset({cp for cp, _ in entries}), f"{strike}: ramp glyph missing")
        require(json.loads(read(f"{strike}/ramp-bake.json")) == ramp, f"{strike}: stale bake ramp")
        for name in ("master.cells", "target-2.cells", "target-4.cells", "tty.cells", "logo.cells"):
            rel = f"{strike}/{name}"
            data = read(rel)
            require(data[:4] == b"RCEL" and len(data) >= 15, f"{rel}: invalid cells header")
            version, cols, rows, frames, fps = struct.unpack_from("<HHHHH", data, 4)
            require(version == 1 and min(cols, rows, frames, fps) > 0, f"{rel}: invalid dimensions/version")
            require((frames, fps) == (master_frames, master_fps), f"{rel}: timing differs from the master")
            ramp_len = data[14]
            require(data[15:15 + ramp_len].decode("ascii") == ramp["ramp"], f"{rel}: stale ramp")
            offset = 15 + ramp_len
            require(struct.unpack_from("<H", data, offset)[0] == 256, f"{rel}: invalid palette size")
            offset += 2
            require(data[offset:offset + 768] == palette, f"{rel}: stale palette")
            offset += 768
            expected = cols * rows * frames * 2
            require(struct.unpack_from("<Q", data, offset)[0] == expected, f"{rel}: payload length mismatch")
            body = payload(data[offset + 8:], expected, rel)
            plane = cols * rows
            require(all(max(body[i:i + plane]) < ramp_len for i in range(0, expected, plane * 2)),
                    f"{rel}: glyph index outside ramp")

    for rel in ("config/sway/colours.conf", "config/foot/foot.ini", "config/shell/colours.sh",
                "config/gtk-3.0/gtk.css", "config/gtk-3.0/settings.ini",
                "config/gtk-4.0/gtk.css", "config/gtk-4.0/settings.ini", "icons/index.theme"):
        read("theme/" + rel)
    icons = [p for p in (prebuilt / "theme/icons").rglob("*") if p.suffix in (".svg", ".png") and p.is_file()]
    require(bool(icons) and all(p.stat().st_size > 0 for p in icons), "icon theme has no icons or contains empty icons")
    for rel in ("plymouth-theme/nullLinux.plymouth", "sddm-theme/theme.conf", "sddm-theme/metadata.desktop"):
        read("boot/" + rel)
    qml = read("boot/sddm-theme/Main.qml").decode()
    count = re.search(r"property int frameCount:\s*(\d+)", qml)
    require(count is not None and 0 < int(count[1]) <= 10000, "greeter has no valid frame count")
    images = [f"sddm-theme/f{i:02d}.png" for i in range(int(count[1]))]
    images += ["plymouth-theme/" + p for p in ("lock.png", "box.png", "entry.png", "bullet.png", "keyboard.png")]
    throbbers = sorted((prebuilt / "boot/plymouth-theme").glob("throbber-*.png"))
    require(bool(throbbers), "boot splash has no animation frames")
    require([p.name for p in throbbers] == [f"throbber-{i:04d}.png" for i in range(1, len(throbbers) + 1)],
            "boot splash frame sequence has a gap")
    images += ["plymouth-theme/" + p.name for p in throbbers]
    for rel in images:
        png(read("boot/" + rel), rel)


def inventory(prebuilt):
    files = {}
    for path in sorted(prebuilt.rglob("*")):
        require(not path.is_symlink(), f"prebuilt symlink is not a self-contained asset: {path}")
        if path.is_file() and path.name != "MANIFEST.json":
            files[path.relative_to(prebuilt).as_posix()] = digest(path)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    prebuilt = args.root / "assets/prebuilt"
    try:
        if args.write_manifest:
            (prebuilt / "MANIFEST.new").unlink(missing_ok=True)
        validate(prebuilt)
        actual = {"format": 1, "sources": sources(args.source_root or args.root), "files": inventory(prebuilt)}
        manifest = prebuilt / "MANIFEST.json"
        if args.write_manifest:
            tmp = manifest.with_suffix(".new")
            tmp.write_text(json.dumps(actual, indent=2, sort_keys=True) + "\n")
            tmp.replace(manifest)
        else:
            require(manifest.is_file(), "prebuilt manifest is missing; run null-prebake")
            recorded = json.loads(manifest.read_text())
            require(recorded.get("format") == 1, "unsupported prebuilt manifest")
            require(recorded.get("sources") == actual["sources"], "prebuilts were generated from different source; run null-prebake")
            require(recorded.get("files") == actual["files"], "prebuilt contents differ from their manifest; run null-prebake")
        print(f"prebuilt assets verified: {len(actual['files'])} files")
        return 0
    except (OSError, ValueError, KeyError, IndexError, struct.error, zstd.ZstdError, zlib.error) as error:
        print(f"null-package: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
