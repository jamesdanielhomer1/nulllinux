"""The two file formats (NULL.md §5.2).

  HDR intermediate  -- one file per frame. Four channels per cell: linear RGB
                       plus OBSERVED TEMPERATURE in Kelvin. Temperature is
                       stored rather than inferred so the quantiser never has
                       to invert the Planckian locus out of an RGB triple
                       (§3.3).

  Quantised cells   -- glyph plane + colour plane per frame, compressed.
"""

import struct
from compression import zstd
import numpy as np

HDR_MAGIC = b"RHDR"
CEL_MAGIC = b"RCEL"
VERSION = 1

R, G, B, T = 0, 1, 2, 3          # channel order in the HDR intermediate
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


# --- HDR intermediate ---------------------------------------------------

def write_hdr(path, arr):
    """arr: float32 (rows, cols, 4) = linear R, G, B, T_obs in Kelvin."""
    rows, cols, ch = arr.shape
    if ch != 4:
        raise ValueError(f"HDR needs 4 channels (R,G,B,T), got {ch}")
    with open(path, "wb") as fh:
        fh.write(HDR_MAGIC)
        fh.write(struct.pack("<HHH", VERSION, cols, rows))
        fh.write(np.ascontiguousarray(arr, dtype="<f4").tobytes())


def read_hdr(path):
    with open(path, "rb") as fh:
        if fh.read(4) != HDR_MAGIC:
            raise ValueError(f"{path}: not an HDR intermediate")
        version, cols, rows = struct.unpack("<HHH", fh.read(6))
        if version != VERSION:
            raise ValueError(f"{path}: version {version}, expected {VERSION}")
        data = np.frombuffer(fh.read(), dtype="<f4")
    return data.reshape(rows, cols, 4)


# --- quantised cells ----------------------------------------------------

def write_cells(path, cols, rows, fps, ramp, palette, glyph_planes, colour_planes):
    """ramp: str. palette: list of (r,g,b). planes: list of uint8 (rows, cols).

    The payload is compressed as one block: large empty regions compress
    extremely hard, and hysteresis makes most cells static between frames.
    """
    n = len(glyph_planes)
    if len(colour_planes) != n:
        raise ValueError("glyph and colour plane counts differ")

    header = bytearray()
    header += CEL_MAGIC
    header += struct.pack("<HHHHH", VERSION, cols, rows, n, fps)
    ramp_bytes = ramp.encode("ascii")
    header += struct.pack("<B", len(ramp_bytes)) + ramp_bytes
    # 256 does not fit in a byte -- this field must be 16-bit (§5.2).
    header += struct.pack("<H", len(palette))
    for r, g, b in palette:
        header += struct.pack("BBB", r, g, b)

    payload = bytearray()
    for gp, cp in zip(glyph_planes, colour_planes):
        payload += np.ascontiguousarray(gp, dtype=np.uint8).tobytes()
        payload += np.ascontiguousarray(cp, dtype=np.uint8).tobytes()

    body = zstd.compress(bytes(payload), level=19)
    with open(path, "wb") as fh:
        fh.write(bytes(header))
        fh.write(struct.pack("<Q", len(payload)))
        fh.write(body)
    return len(payload), len(body)


def read_cells(path):
    with open(path, "rb") as fh:
        if fh.read(4) != CEL_MAGIC:
            raise ValueError(f"{path}: not a quantised cell file")
        version, cols, rows, frames, fps = struct.unpack("<HHHHH", fh.read(10))
        if version != VERSION:
            raise ValueError(f"{path}: version {version}, expected {VERSION}")
        (rl,) = struct.unpack("<B", fh.read(1))
        ramp = fh.read(rl).decode("ascii")
        (pl,) = struct.unpack("<H", fh.read(2))
        palette = [struct.unpack("BBB", fh.read(3)) for _ in range(pl)]
        (raw_len,) = struct.unpack("<Q", fh.read(8))
        payload = zstd.decompress(fh.read())
    if len(payload) != raw_len:
        raise ValueError(f"{path}: payload is {len(payload)} bytes, header says {raw_len}")

    per = cols * rows
    glyphs, colours = [], []
    for i in range(frames):
        off = i * per * 2
        glyphs.append(np.frombuffer(payload[off:off + per], dtype=np.uint8).reshape(rows, cols))
        colours.append(np.frombuffer(payload[off + per:off + 2 * per], dtype=np.uint8).reshape(rows, cols))
    return {"cols": cols, "rows": rows, "frames": frames, "fps": fps,
            "ramp": ramp, "palette": palette, "glyphs": glyphs, "colours": colours}
