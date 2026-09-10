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
    blit_frame(c, a, frame, &mut buf, w, bg, (0, 0), None);
    (w, h, buf)
}

/// Blit a frame into an existing BGRA buffer.
///
/// If `prev` is given, only cells whose glyph or colour changed are touched --
/// the delta property the whole design rests on.
pub fn blit_frame(c: &Cells, a: &Atlas, frame: usize, buf: &mut [u8], stride_px: usize,
                  bg: [u8; 3], origin: (usize, usize), prev: Option<(&[u8], &[u8])>) -> usize {
    if stride_px == 0 { return 0 }
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
            // Guarded like the ramp above it: col[i] is a byte from the cells
            // file, and a corrupt frame whose index exceeds the palette must not
            // panic the wallpaper mid-draw. A wrong pixel is cosmetic; a crash
            // loop is not.
            let rgb = c.palette.get(col[i] as usize).copied().unwrap_or([0, 0, 0]);
            let bits = a.glyph(ch as u32);
            let x0 = origin.0 + x * a.cell_w;
            let y0 = origin.1 + row * a.cell_h;

            for cy in 0..a.cell_h {
                let dst_row = (y0 + cy) * stride_px;
                for cx in 0..a.cell_w {
                    if x0 + cx >= stride_px { break }
                    let o = (dst_row + x0 + cx) * 4;
                    // Guarded like TextGrid::blit: the buffer is the
                    // COMPOSITOR's size and the cells are the FILE's. A mode
                    // change mid-run can shrink one under the other for a
                    // frame, and a clipped pixel beats a panic in the draw
                    // loop, whatever screen is attached.
                    if o + 3 >= buf.len() { continue }
                    let lit = bits.map_or(false, |b| b[cy * a.cell_w + cx] != 0);
                    if lit {
                        buf[o] = rgb[2]; buf[o + 1] = rgb[1]; buf[o + 2] = rgb[0]; buf[o + 3] = 0xff;
                    } else {
                        // Clearing to the background is what makes this a
                        // DELTA blit: a changed cell must erase what it had.
                        // The colour is the CALLER's background -- this was a
                        // hand-typed #05060a, which 4.8 forbids, and which
                        // silently diverges the moment the palette is rebaked.
                        buf[o] = bg[2]; buf[o + 1] = bg[1]; buf[o + 2] = bg[0]; buf[o + 3] = 0xff;
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

#[cfg(test)]
mod tests {
    use super::*;

    // One frame, every cell glyph 0 / colour 0. ramp[0] is ' ' (all pixels
    // unlit), so a blit paints every covered pixel the caller's background.
    fn cells(cols: u16, rows: u16) -> Cells {
        let n = cols as usize * rows as usize;
        Cells::synthetic(cols, rows, 1, vec![' ', '#'], vec![[200, 100, 50]],
                         vec![0u8; n * 2])
    }
    fn atlas() -> Atlas {
        // A synthetic 2x2 atlas carrying ' ' (unlit) and '#' (all lit).
        let mut d = b"RATL".to_vec();
        d.extend_from_slice(&[1, 0]);
        d.extend_from_slice(&2u16.to_le_bytes());   // cell_w
        d.extend_from_slice(&2u16.to_le_bytes());   // cell_h
        d.extend_from_slice(&2u16.to_le_bytes());   // count
        d.extend_from_slice(&[0u8; 32]);
        d.extend_from_slice(&2u16.to_le_bytes());   // tbl
        d.extend_from_slice(&[b' ', 0, 0, 0, 0, 0]);
        d.extend_from_slice(&[b'#', 0, 0, 0, 1, 0]);
        d.extend_from_slice(&[0u8; 4]);             // ' ' bitmap: unlit
        d.extend_from_slice(&[1u8; 4]);             // '#' bitmap: lit
        Atlas::from_bytes(&d, "synthetic").unwrap()
    }

    #[test]
    fn erase_uses_the_callers_background_not_a_constant() {
        // The erase colour was a hand-typed #05060a. Pass a colour that is
        // nothing like it and require every covered pixel to be exactly that.
        let (c, a) = (cells(3, 2), atlas());
        let (w, h) = (6usize, 4usize);
        let mut buf = vec![0u8; w * h * 4];
        blit_frame(&c, &a, 0, &mut buf, w, [9, 8, 7], (0, 0), None);
        for (i, px) in buf.chunks_exact(4).enumerate() {
            assert_eq!([px[0], px[1], px[2], px[3]], [7, 8, 9, 0xff], "pixel {i}");
        }
    }

    #[test]
    fn a_buffer_smaller_than_the_cells_does_not_panic() {
        // The compositor's size and the file's size are independent; a mode
        // change mid-run can hand a buffer smaller than the grid for a frame.
        let (c, a) = (cells(50, 40), atlas());     // needs 100x80 px
        for (w, h) in [(30usize, 20usize), (7, 3), (1, 1), (99, 79), (101, 81)] {
            let mut buf = vec![0u8; w * h * 4];
            blit_frame(&c, &a, 0, &mut buf, w, [1, 2, 3], (0, 0), None);
        }
    }

    #[test]
    fn horizontal_clipping_never_overwrites_the_next_scanline() {
        let c = Cells::synthetic(2,1,1,vec!['#'],vec![[200,0,0],[0,0,200]],vec![0,0,0,1]);
        let a = atlas();
        let mut buf = vec![0u8; 2 * 4 * 4];
        blit_frame(&c, &a, 0, &mut buf, 2, [0,0,0], (0,0), None);
        assert_eq!(&buf[8..12], &[0,0,200,255], "visible red cell survives the off-screen blue cell");
        assert_eq!(&buf[16..20], &[0,0,0,0], "no pixels spill below the hero");
    }

    #[test]
    fn weird_panel_sizes_all_survive_fill_plus_blit() {
        // The property, not one machine: ANY buffer at least as big as the
        // grid, filled then blitted, ends fully opaque with the remainder
        // bands the background -- odd widths, primes, portrait, near-misses.
        let (c, a) = (cells(4, 3), atlas());        // grid: 8x6 px
        let bg = [5, 6, 10];
        for (w, h) in [(9usize, 7usize), (13, 6), (8, 11), (37, 23), (8, 6), (211, 6), (9, 97)] {
            let mut buf = vec![0u8; w * h * 4];
            for px in buf.chunks_exact_mut(4) {
                px[0] = bg[2]; px[1] = bg[1]; px[2] = bg[0]; px[3] = 0xff;
            }
            blit_frame(&c, &a, 0, &mut buf, w, bg, (0, 0), None);
            for (i, px) in buf.chunks_exact(4).enumerate() {
                assert_eq!(px[3], 0xff, "{w}x{h}: pixel {i} transparent");
                assert_eq!([px[2], px[1], px[0]], bg, "{w}x{h}: pixel {i} not bg");
            }
        }
    }
}

#[cfg(test)]
mod centering_tests {
    use super::*;

    #[test]
    fn an_origin_offsets_the_hero_and_leaves_bg_around_it() {
        // A grid smaller than the buffer, drawn at an origin, must leave the
        // margin the background on every side -- the centred-wallpaper case on
        // a panel the asset does not fill.
        let cols = 2u16; let rows = 2u16;                     // 4x4 px hero (2x2 cells)
        let cells = Cells::synthetic(cols, rows, 1, vec!['#'],  // ramp[0]='#': all lit
                                     vec![[200, 50, 25]], vec![0u8; (cols*rows) as usize * 2]);
        // atlas: one glyph '#', 2x2, all lit
        let mut d = b"RATL".to_vec(); d.extend_from_slice(&[1,0]);
        d.extend_from_slice(&2u16.to_le_bytes()); d.extend_from_slice(&2u16.to_le_bytes());
        d.extend_from_slice(&1u16.to_le_bytes()); d.extend_from_slice(&[0u8;32]);
        d.extend_from_slice(&1u16.to_le_bytes());
        d.extend_from_slice(&[b'#',0,0,0,0,0]); d.extend_from_slice(&[1u8;4]);
        let a = Atlas::from_bytes(&d, "syn").unwrap();
        let bg=[5,6,10]; let (w,h)=(8usize,8usize);          // hero 4x4 centred in 8x8 -> origin (2,2)
        let mut buf=vec![0u8;w*h*4];
        for px in buf.chunks_exact_mut(4){px[0]=bg[2];px[1]=bg[1];px[2]=bg[0];px[3]=0xff;}
        blit_frame(&cells,&a,0,&mut buf,w,bg,(2,2),None);
        let at=|x:usize,y:usize|{let o=(y*w+x)*4;(buf[o+2],buf[o+1],buf[o])};
        assert_eq!(at(0,0),(5,6,10),"top-left margin is bg");
        assert_eq!(at(7,7),(5,6,10),"bottom-right margin is bg");
        assert_eq!(at(3,3),(200,50,25),"hero centre is the lit glyph colour");
    }
}
