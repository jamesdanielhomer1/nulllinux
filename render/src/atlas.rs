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
        if d.len() < 4 || &d[0..4] != MAGIC {
            return Err(format!("{path}: not an atlas"));
        }
        let g = |o: usize| u16::from_le_bytes([d[o], d[o + 1]]) as usize;
        let cell_w = g(6);
        let cell_h = g(8);
        let count = g(10);
        let mut font_sha256 = [0u8; 32];
        font_sha256.copy_from_slice(&d[12..44]);
        let tbl = g(44);
        let mut index = HashMap::with_capacity(tbl);
        let mut o = 46;
        for _ in 0..tbl {
            let cp = u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]]);
            let idx = u16::from_le_bytes([d[o + 4], d[o + 5]]) as usize;
            index.insert(cp, idx);
            o += 6;
        }
        let need = count * cell_w * cell_h;
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
        Some(&self.bitmaps[i * n..(i + 1) * n])
    }

    pub fn has(&self, cp: u32) -> bool { self.index.contains_key(&cp) }
    pub fn len(&self) -> usize { self.index.len() }
}
