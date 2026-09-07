//! A grid of cells, and a delta blit onto a BGRA buffer.
//!
//! Records which ROWS changed in which blit generation, so a surface can copy
//! only the rows a given buffer slot is missing rather than the whole thing
//! (NULL.md §6.3).

use crate::atlas::Atlas;

#[derive(Clone, Copy, PartialEq)]
pub struct Cell {
    pub ch: char,
    pub fg: [u8; 3],
    /// A background for THIS cell, where something wants one. `None` means the
    /// surface's own background, which is what almost everything wants.
    ///
    /// It exists for hosted programs. A terminal user interface says "this is
    /// the selected row" by inverting it, and the host loop was passing only
    /// the foreground through -- so nmtui's selected item, drawn black on
    /// white, arrived as black on a black panel and simply was not there. The
    /// first menu entry of the first program hosted after this was written was
    /// invisible, which is how it was found.
    pub bg: Option<[u8; 3]>,
    pub bold: bool,
}

impl Default for Cell {
    fn default() -> Self { Cell { ch: ' ', fg: [0, 0, 0], bg: None, bold: false } }
}

pub struct TextGrid {
    pub cols: usize,
    pub rows: usize,
    pub bg: [u8; 3],
    cells: Vec<Cell>,
    dirty_gen: Vec<u64>,
    pub generation: u64,
}

impl TextGrid {
    pub fn new(cols: usize, rows: usize, bg: [u8; 3]) -> Self {
        TextGrid {
            cols, rows, bg,
            cells: vec![Cell::default(); cols * rows],
            dirty_gen: vec![1; rows],
            generation: 1,
        }
    }

    pub fn clear(&mut self) {
        self.generation += 1;
        for c in self.cells.iter_mut() { *c = Cell::default() }
        for d in self.dirty_gen.iter_mut() { *d = self.generation }
    }

    #[inline]
    pub fn set(&mut self, x: usize, y: usize, ch: char, fg: [u8; 3]) {
        self.set_full(x, y, Cell { ch, fg, bg: None, bold: false })
    }

    pub fn set_full(&mut self, x: usize, y: usize, cell: Cell) {
        if x >= self.cols || y >= self.rows { return }
        let i = y * self.cols + x;
        if self.cells[i] != cell {
            self.cells[i] = cell;
            self.dirty_gen[y] = self.generation;
        }
    }

    /// Write a string, clipped. Returns the column after the last cell written.
    pub fn text(&mut self, x: usize, y: usize, s: &str, fg: [u8; 3]) -> usize {
        let mut cx = x;
        for ch in s.chars() {
            if cx >= self.cols { break }
            self.set(cx, y, ch, fg);
            cx += 1;
        }
        cx
    }

    /// The character at a position, for the --print view -- which is how a
    /// layout regression becomes visible in a test rather than only on screen.
    pub fn char_at(&self, x: usize, y: usize) -> char {
        if x >= self.cols || y >= self.rows { return ' ' }
        self.cells[y * self.cols + x].ch
    }

    pub fn row_dirty_since(&self, y: usize, gen: u64) -> bool { self.dirty_gen[y] > gen }

    pub fn bump(&mut self) { self.generation += 1 }

    /// Paint the WHOLE buffer the background colour, once.
    ///
    /// blit() writes only the grid area, cols*cell_w wide. On a panel whose
    /// width is not a multiple of the cell width -- 1366 is not a multiple of 8
    /// -- the pixels past the last column are never written, and a freshly
    /// allocated shm slot leaves them transparent: the bar showed the wallpaper
    /// through a strip at its right edge on real hardware, invisible in a VM at
    /// 1280 which happens to divide evenly. Called once per slot at creation, so
    /// it costs nothing per frame; the delta blit paints the cells on top.
    pub fn fill(&self, buf: &mut [u8]) {
        for px in buf.chunks_exact_mut(4) {
            px[0] = self.bg[2]; px[1] = self.bg[1]; px[2] = self.bg[0]; px[3] = 0xff;
        }
    }

    /// Blit into a BGRA buffer, skipping rows the target already has.
    ///
    /// Returns the number of rows copied, which is the figure to watch: a
    /// surface whose spectrum is one row of sixty should be copying one row,
    /// not the whole 1.3 MB thirty times a second (§6.4).
    pub fn blit(&self, atlas: &Atlas, buf: &mut [u8], stride_px: usize,
                target_gen: u64, bold: Option<&Atlas>) -> usize {
        let mut copied = 0;
        for y in 0..self.rows {
            if !self.row_dirty_since(y, target_gen) { continue }
            copied += 1;
            for x in 0..self.cols {
                let c = self.cells[y * self.cols + x];
                let src = if c.bold { bold.unwrap_or(atlas) } else { atlas };
                // A cell the atlas cannot draw must show something VISIBLE.
                // A blank reads as the program having printed nothing, which
                // is indistinguishable from a bug (§7.3).
                let bits = src.glyph(c.ch as u32).or_else(|| atlas.glyph('·' as u32));
                let x0 = x * atlas.cell_w;
                let y0 = y * atlas.cell_h;
                for cy in 0..atlas.cell_h {
                    let row = (y0 + cy) * stride_px;
                    for cx in 0..atlas.cell_w {
                        let o = (row + x0 + cx) * 4;
                        if o + 3 >= buf.len() { continue }
                        let lit = bits.map_or(false, |b| b[cy * atlas.cell_w + cx] != 0);
                        let p = if lit { c.fg } else { c.bg.unwrap_or(self.bg) };
                        buf[o] = p[2]; buf[o+1] = p[1]; buf[o+2] = p[0]; buf[o+3] = 0xff;
                    }
                }
            }
        }
        copied
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fill_leaves_no_transparent_pixel() {
        // The bug this guards: a buffer wider than cols*cell_w has a right strip
        // that blit never touches. fill() must cover the WHOLE buffer opaque, so
        // that strip is the background, not the transparent shm zero that showed
        // the wallpaper through the bar's edge on a 1366-wide panel.
        let g = TextGrid::new(2, 1, [5, 6, 10]);
        let mut buf = vec![0u8; 20 * 4];          // 20px wide, grid covers less
        g.fill(&mut buf);
        for (i, px) in buf.chunks_exact(4).enumerate() {
            assert_eq!(px[3], 0xff, "pixel {i} is transparent after fill");
            assert_eq!([px[2], px[1], px[0]], [5, 6, 10], "pixel {i} is not the bg");
        }
    }
}
