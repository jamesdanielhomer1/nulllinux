"""PSF1 and PSF2 console-font parsing.

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

# PSF1, which this refused to read at all until a machine needed it.
#
# Terminus ships BOTH formats and the choice is not ours: every 8-pixel-wide
# strike is PSF1, because PSF1 has no width field and is 8 wide by definition.
# ter-112n is PSF2 and ter-116n is PSF1, and which one a machine wants depends
# on the size of its screen -- so a 1280x800 panel picked an 8x16 strike, the
# baker was handed a PSF1 file, and the install stopped.
#
# The header is four bytes: magic, a mode byte, and the glyph height. Width is
# 8. Mode bit 0 means 512 glyphs rather than 256; bit 1 means a unicode table
# follows, in a different and simpler encoding than PSF2's.
PSF1_MAGIC = b"\x36\x04"
PSF1_MODE512 = 0x01
PSF1_MODEHASTAB = 0x02
PSF1_SEPARATOR = 0xFFFF
PSF1_STARTSEQ = 0xFFFE

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

        if raw[:4] == PSF2_MAGIC:
            self.psf_version = 2
            (_magic, self.version, self.headersize, self.flags,
             self.length, self.charsize, self.height, self.width) = struct.unpack("<8I", raw[:32])
        elif raw[:2] == PSF1_MAGIC:
            self.psf_version = 1
            mode, charsize = raw[2], raw[3]
            self.version = 0
            self.headersize = 4
            self.flags = PSF2_HAS_UNICODE_TABLE if (mode & PSF1_MODEHASTAB) else 0
            self.length = 512 if (mode & PSF1_MODE512) else 256
            self.charsize = charsize
            self.height = charsize
            self.width = 8          # PSF1 has no width field and never can
        else:
            raise ValueError(
                f"{path}: not a PSF font (magic {raw[:4].hex()}; "
                f"expected {PSF2_MAGIC.hex()} for PSF2 or {PSF1_MAGIC.hex()} for PSF1)"
            )

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

        if self.psf_version == 1:
            self.cp_to_index = self._parse_unicode_table_psf1(raw[end:])
        else:
            self.cp_to_index = self._parse_unicode_table(raw[end:])

    def _parse_unicode_table_psf1(self, tail):
        """Map codepoint -> glyph index, PSF1's way.

        PSF1 stores little-endian 16-bit words, not UTF-8: 0xFFFF ends a
        glyph's list and 0xFFFE starts a combining sequence, which is skipped
        for the same reason PSF2's is -- singles are what a cell can draw.
        """
        if not (self.flags & PSF2_HAS_UNICODE_TABLE):
            # No table: index is codepoint, which is true of ASCII in these
            # strikes and stated rather than assumed.
            return {i: i for i in range(self.length)}
        out, idx, i, in_seq = {}, 0, 0, False
        while i + 1 < len(tail) and idx < self.length:
            (word,) = struct.unpack_from("<H", tail, i)
            i += 2
            if word == PSF1_SEPARATOR:
                idx += 1; in_seq = False
            elif word == PSF1_STARTSEQ:
                in_seq = True
            elif not in_seq:
                out.setdefault(word, idx)
        return out

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
