//! Terminal backend: delta cells only (NULL.md §5.2, §6.1).
//!
//! Hysteresis makes the overwhelming majority of cells static between frames,
//! so emitting only what changed is an enormous saving over redrawing -- and
//! it is the same property the compositor backend relies on.

use crate::cells::Cells;
use std::io::{self, Write};
use std::time::{Duration, Instant};

pub struct Stats {
    pub frames: usize,
    pub cells_written: usize,
    pub cells_possible: usize,
}

pub fn run(c: &Cells, duration: Option<Duration>, out: &mut impl Write) -> io::Result<Stats> {
    write!(out, "\x1b[?1049h\x1b[?25l\x1b[2J")?;   // alt screen, hide cursor, clear
    let r = animate(c, duration, out);
    write!(out, "\x1b[0m\x1b[?25h\x1b[?1049l")?;   // restore, always
    out.flush()?;
    r
}

fn animate(c: &Cells, duration: Option<Duration>, out: &mut impl Write) -> io::Result<Stats> {
    let n = c.cell_count();
    let mut prev_g = vec![u8::MAX; n];
    let mut prev_c = vec![u8::MAX; n];
    let mut st = Stats { frames: 0, cells_written: 0, cells_possible: 0 };

    let start = Instant::now();
    let period = Duration::from_secs_f64(1.0 / c.fps as f64);
    let mut buf = String::with_capacity(n * 8);

    loop {
        if let Some(d) = duration {
            if start.elapsed() >= d { break; }
        }
        let f = c.frame_at(start.elapsed());
        let g = c.glyphs(f);
        let col = c.colours(f);

        buf.clear();
        let mut last_colour: Option<u8> = None;
        let mut cursor: Option<(usize, usize)> = None;

        for row in 0..c.rows as usize {
            for x in 0..c.cols as usize {
                let i = row * c.cols as usize + x;
                if g[i] == prev_g[i] && col[i] == prev_c[i] { continue; }

                // Only move the cursor when the run breaks; a move per cell
                // would cost more bytes than the cells themselves.
                if cursor != Some((row, x)) {
                    buf.push_str(&format!("\x1b[{};{}H", row + 1, x + 1));
                }
                if last_colour != Some(col[i]) {
                    let p = c.palette[col[i] as usize];
                    buf.push_str(&format!("\x1b[38;2;{};{};{}m", p[0], p[1], p[2]));
                    last_colour = Some(col[i]);
                }
                buf.push(*c.ramp.get(g[i] as usize).unwrap_or(&'?'));
                prev_g[i] = g[i];
                prev_c[i] = col[i];
                st.cells_written += 1;
                cursor = Some((row, x + 1));
            }
        }
        st.cells_possible += n;
        st.frames += 1;
        out.write_all(buf.as_bytes())?;
        out.flush()?;

        let target = period.saturating_mul(st.frames as u32);
        if let Some(sleep) = target.checked_sub(start.elapsed()) {
            std::thread::sleep(sleep);
        }
    }
    Ok(st)
}
