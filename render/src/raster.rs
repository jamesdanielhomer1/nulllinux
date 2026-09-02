//! Rasterising backend (NULL.md §6.1).
//!
//! Not a debug convenience. This is how the boot splash and every still is
//! produced (§9.6.1), and routing them through the SAME code path as the
//! animated surfaces is what guarantees they cannot disagree about what the
//! hero looks like.

use crate::atlas::Atlas;
use crate::cells::Cells;

/// Rasterise one frame to a BGRA buffer (the layout a Wayland shm buffer wants).
pub fn frame_to_bgra(c: &Cells, a: &Atlas, frame: usize, bg: [u8; 3]) -> (usize, usize, Vec<u8>) {
    let w = c.cols as usize * a.cell_w;
    let h = c.rows as usize * a.cell_h;
    let mut buf = vec![0u8; w * h * 4];
    for px in buf.chunks_exact_mut(4) {
        px[0] = bg[2]; px[1] = bg[1]; px[2] = bg[0]; px[3] = 0xff;
    }
    blit_frame(c, a, frame, &mut buf, w, None);
    (w, h, buf)
}

/// Blit a frame into an existing BGRA buffer.
///
/// If `prev` is given, only cells whose glyph or colour changed are touched --
/// the delta property the whole design rests on.
pub fn blit_frame(c: &Cells, a: &Atlas, frame: usize, buf: &mut [u8], stride_px: usize,
                  prev: Option<(&[u8], &[u8])>) -> usize {
    let g = c.glyphs(frame);
    let col = c.colours(frame);
    let mut touched = 0usize;

    for row in 0..c.rows as usize {
        for x in 0..c.cols as usize {
            let i = row * c.cols as usize + x;
            if let Some((pg, pc)) = prev {
                if g[i] == pg[i] && col[i] == pc[i] { continue; }
            }
            touched += 1;
            let ch = *c.ramp.get(g[i] as usize).unwrap_or(&' ');
            let rgb = c.palette[col[i] as usize];
            let bits = a.glyph(ch as u32);
            let x0 = x * a.cell_w;
            let y0 = row * a.cell_h;

            for cy in 0..a.cell_h {
                let dst_row = (y0 + cy) * stride_px;
                for cx in 0..a.cell_w {
                    let o = (dst_row + x0 + cx) * 4;
                    let lit = bits.map_or(false, |b| b[cy * a.cell_w + cx] != 0);
                    if lit {
                        buf[o] = rgb[2]; buf[o + 1] = rgb[1]; buf[o + 2] = rgb[0]; buf[o + 3] = 0xff;
                    } else {
                        // Clearing to the background is what makes this a
                        // DELTA blit: a changed cell must erase what it had.
                        buf[o] = 0x0a; buf[o + 1] = 0x06; buf[o + 2] = 0x05; buf[o + 3] = 0xff;
                    }
                }
            }
        }
    }
    touched
}

pub fn write_ppm(path: &str, w: usize, h: usize, bgra: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    write!(f, "P6\n{w} {h}\n255\n")?;
    let mut rgb = Vec::with_capacity(w * h * 3);
    for px in bgra.chunks_exact(4) {
        rgb.push(px[2]); rgb.push(px[1]); rgb.push(px[0]);
    }
    f.write_all(&rgb)
}
