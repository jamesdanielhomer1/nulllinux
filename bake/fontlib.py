"""PSF2 console-font parsing.

The font is the medium (NULL.md I2), so everything downstream -- the ramp, the
glyph atlas, the console -- reads it through here. Pure standard library: a
bitmap font is an integer pixel count and needs no rasteriser, which is the
whole reason coverage can be exact (§2.4).
"""

import gzip
import hashlib
import struct

# The four magic bytes as they appear on disk. Note that read as a
# little-endian 32-bit word this is 0x864AB572; writing it the other way round
# is a reliable way to build a parser that rejects every valid font.
PSF2_MAGIC = b"\x72\xb5\x4a\x86"
PSF2_HAS_UNICODE_TABLE = 0x01

_SEP = 0xFF          # end of one glyph's codepoint list
_SEQ = 0xFE          # start of a combining sequence; skipped, we want singles


class Font:
    """One strike of a bitmap font: fixed cell, fixed glyph count."""

    def __init__(self, path):
        self.path = str(path)
        raw = self._read(self.path)

        # Hash the FILE, not the parsed content. §2.4 requires downstream
        # stages to refuse to run when the font changes, and a glyph edit that
        # leaves the header identical must still trip the guard.
        self.sha256 = hashlib.sha256(raw).hexdigest()

        if raw[:4] != PSF2_MAGIC:
            raise ValueError(
                f"{path}: not a PSF2 file (magic {raw[:4].hex()}, expected {PSF2_MAGIC.hex()})"
            )

        (_magic, self.version, self.headersize, self.flags,
         self.length, self.charsize, self.height, self.width) = struct.unpack("<8I", raw[:32])

        self.row_bytes = (self.width + 7) // 8
        expected = self.row_bytes * self.height
        if self.charsize != expected:
            raise ValueError(
                f"{path}: charsize {self.charsize} disagrees with {self.width}x{self.height} "
                f"(expected {expected}) -- refusing to guess"
            )

        start = self.headersize
        end = start + self.length * self.charsize
        if len(raw) < end:
            raise ValueError(f"{path}: truncated glyph data")
        self._glyphs = raw[start:end]

        self.cp_to_index = self._parse_unicode_table(raw[end:])

    @staticmethod
    def _read(path):
        opener = gzip.open if str(path).endswith(".gz") else open
        with opener(path, "rb") as fh:
            return fh.read()

    def _parse_unicode_table(self, tail):
        """Map codepoint -> glyph index.

        Parsed rather than assumed. Glyph index happens to equal codepoint for
        ASCII in the strikes used here, and that will not hold for the next
        font.
        """
        if not (self.flags & PSF2_HAS_UNICODE_TABLE) or not tail:
            return {i: i for i in range(self.length)}

        table, glyph, buf, skipping = {}, 0, bytearray(), False
        for byte in tail:
            if byte == _SEP:
                if buf and not skipping:
                    for cp in buf.decode("utf-8", "ignore"):
                        table.setdefault(ord(cp), glyph)
                buf.clear()
                skipping = False
                glyph += 1
            elif byte == _SEQ:
                if buf and not skipping:
                    for cp in buf.decode("utf-8", "ignore"):
                        table.setdefault(ord(cp), glyph)
                buf.clear()
                skipping = True          # combining sequences are not single glyphs
            else:
                buf.append(byte)
        return table

    def bitmap(self, index):
        """Glyph as a list of rows of 0/1, one entry per pixel."""
        off = index * self.charsize
        rows = []
        for r in range(self.height):
            row_start = off + r * self.row_bytes
            bits = int.from_bytes(self._glyphs[row_start:row_start + self.row_bytes], "big")
            total = self.row_bytes * 8
            rows.append([(bits >> (total - 1 - c)) & 1 for c in range(self.width)])
        return rows

    def bitmap_for_codepoint(self, cp):
        idx = self.cp_to_index.get(cp)
        return None if idx is None else self.bitmap(idx)

    def ink(self, index):
        """Lit pixel count. Exact, because the glyph is a bitmap."""
        off = index * self.charsize
        return sum(bin(b).count("1") for b in self._glyphs[off:off + self.charsize])

    @property
    def cell_pixels(self):
        return self.width * self.height

    def __repr__(self):
        return (f"Font({self.path!r}, {self.width}x{self.height}, "
                f"{self.length} glyphs, sha256={self.sha256[:12]}...)")
