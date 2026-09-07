//! Glyph atlas: one byte per pixel, baked from the same font file the ramp was
//! derived from and keyed by the same hash (NULL.md §6.2).

use std::collections::HashMap;
use std::fs;

const MAGIC: &[u8; 4] = b"RATL";

pub struct Atlas {
    pub cell_w: usize,
    pub cell_h: usize,
    pub font_sha256: [u8; 32],
    index: HashMap<u32, usize>,
    bitmaps: Vec<u8>,
}

impl Atlas {
    pub fn load(path: &str) -> Result<Self, String> {
        let d = fs::read(path).map_err(|e| format!("{path}: {e}"))?;
        Self::from_bytes(&d, path)
    }

    /// Parse an atlas from bytes. Every read is bounds-checked and every failure
    /// is an Err, not a panic: this file is trusted and manifest-verified, but a
    /// truncated or corrupt one (a bad bake, a torn write, a disk fault) must
    /// FAIL a surface, not crash-loop it -- the supervisor would respawn it
    /// straight back into the same panic every few seconds.
    pub fn from_bytes(d: &[u8], path: &str) -> Result<Self, String> {
        // The fixed header runs to offset 46: magic[0..4], cell_w@6, cell_h@8,
        // count@10, sha256[12..44], tbl@44. Guard the whole thing at once.
        if d.len() < 46 || &d[0..4] != MAGIC {
            return Err(format!("{path}: not an atlas (short or bad magic)"));
        }
        let g = |o: usize| u16::from_le_bytes([d[o], d[o + 1]]) as usize;
        let cell_w = g(6);
        let cell_h = g(8);
        let count = g(10);
        let mut font_sha256 = [0u8; 32];
        font_sha256.copy_from_slice(&d[12..44]);
        let tbl = g(44);
        // The index is tbl entries of 6 bytes from offset 46. Prove it is all
        // there before the loop, so no d[o+k] inside can be out of bounds.
        let idx_end = 46usize.checked_add(tbl.checked_mul(6).ok_or_else(|| format!("{path}: absurd index count"))?)
            .ok_or_else(|| format!("{path}: absurd index count"))?;
        if d.len() < idx_end {
            return Err(format!("{path}: truncated index"));
        }
        let mut index = HashMap::with_capacity(tbl);
        let mut o = 46;
        for _ in 0..tbl {
            let cp = u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]]);
            let idx = u16::from_le_bytes([d[o + 4], d[o + 5]]) as usize;
            index.insert(cp, idx);
            o += 6;
        }
        let need = count.checked_mul(cell_w).and_then(|v| v.checked_mul(cell_h))
            .ok_or_else(|| format!("{path}: absurd bitmap size"))?;
        if d.len() - o < need {
            return Err(format!("{path}: truncated bitmaps"));
        }
        Ok(Atlas { cell_w, cell_h, font_sha256, index, bitmaps: d[o..o + need].to_vec() })
    }

    /// The glyph's pixels, row-major, one byte per pixel (0 or 1).
    ///
    /// Returns None for a codepoint the atlas has no glyph for. Callers must
    /// substitute something VISIBLE, never a blank: a blank reads as the
    /// program having printed nothing, which is indistinguishable from a bug
    /// (§7.3).
    #[inline]
    pub fn glyph(&self, cp: u32) -> Option<&[u8]> {
        let i = *self.index.get(&cp)?;
        let n = self.cell_w * self.cell_h;
        // A corrupt index entry can point past the bitmaps; that is a missing
        // glyph, not a reason to panic in the draw loop.
        let (a, b) = (i * n, (i + 1) * n);
        if b > self.bitmaps.len() { return None }
        Some(&self.bitmaps[a..b])
    }

    pub fn has(&self, cp: u32) -> bool { self.index.contains_key(&cp) }
    pub fn len(&self) -> usize { self.index.len() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(cell_w: u16, cell_h: u16, count: u16, tbl: u16) -> Vec<u8> {
        let mut d = MAGIC.to_vec();
        d.extend_from_slice(&[0, 0]);               // 4..6 reserved
        d.extend_from_slice(&cell_w.to_le_bytes()); // 6
        d.extend_from_slice(&cell_h.to_le_bytes()); // 8
        d.extend_from_slice(&count.to_le_bytes());  // 10
        d.extend_from_slice(&[0u8; 32]);            // 12..44 sha
        d.extend_from_slice(&tbl.to_le_bytes());    // 44
        d                                            // ends at 46
    }

    #[test]
    fn short_header_errors_not_panics() {
        assert!(Atlas::from_bytes(b"RATL", "t").is_err());
        assert!(Atlas::from_bytes(&header(8, 16, 1, 1)[..20], "t").is_err());
    }

    #[test]
    fn truncated_index_errors_not_panics() {
        // Says 100 index entries, provides none.
        let d = header(8, 16, 1, 100);
        assert!(Atlas::from_bytes(&d, "t").is_err());
    }

    #[test]
    fn truncated_bitmaps_error_not_panic() {
        // One glyph of 8x16 = 128 bytes promised, index present, bitmaps absent.
        let mut d = header(8, 16, 1, 1);
        d.extend_from_slice(&[b'A' as u8, 0, 0, 0, 0, 0]);   // one index entry -> idx 0
        assert!(Atlas::from_bytes(&d, "t").is_err());
    }

    #[test]
    fn a_glyph_index_past_the_bitmaps_reads_as_missing_not_a_panic() {
        // A valid-length atlas whose index points a codepoint at glyph 5 while
        // only one glyph of bitmap exists: glyph() must return None, not panic.
        let mut d = header(2, 2, 1, 1);              // count=1 -> 4 bytes of bitmap
        d.extend_from_slice(&[b'Z' as u8, 0, 0, 0, 5, 0]); // 'Z' -> idx 5 (out of range)
        d.extend_from_slice(&[0u8; 4]);             // one glyph's worth
        let a = Atlas::from_bytes(&d, "t").expect("loads");
        assert_eq!(a.glyph('Z' as u32), None, "out-of-range index must read as missing");
    }
}
