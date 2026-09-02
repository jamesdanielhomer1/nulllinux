//! render -- one renderer, several backends (NULL.md §6.1).
//!
//! One program draws every surface this system owns. That is the reason the
//! surfaces cannot disagree with each other about what the hero looks like.

mod atlas;
mod cells;
mod ansi;
mod raster;
mod ipc;
mod layershell;

use std::time::Duration;

fn usage() -> ! {
    eprintln!(
"usage: render --file <cells> [--atlas <atlas>] <backend> [options]

backends:
  info                    header, ramp, palette, and the atlas key
  ansi                    animate to this terminal, delta cells only
  raster --frame N --out  rasterise one frame to a PPM
  still --frame N --out   write one frame as ANSI text (for /etc/issue)
  layershell              animate as a compositor surface

options:
  --seconds N             stop after N seconds (ansi)
  --layer overlay         map on the overlay layer (implies --force-animate)
  --force-animate         never suspend, even when occluded
"
    );
    std::process::exit(2)
}

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() { usage() }

    let file = arg(&args, "--file").unwrap_or_else(|| usage());
    let c = match cells::Cells::load(&file) {
        Ok(c) => c,
        Err(e) => { eprintln!("render: {e}"); std::process::exit(1) }
    };

    // The backend is the first bare word that is not the value of a flag.
    let backend = {
        let mut found = None;
        let mut i = 0;
        while i < args.len() {
            if args[i].starts_with("--") { i += 2; continue; }   // flag and its value
            found = Some(args[i].clone());
            break;
        }
        found.unwrap_or_else(|| usage())
    };

    match backend.as_str() {
        "info" => {
            println!("{file}");
            println!("  {}x{} cells, {} frames @ {} fps = {:.3} s loop",
                     c.cols, c.rows, c.frames, c.fps, c.frames as f64 / c.fps as f64);
            println!("  ramp   {:?} ({} levels)", c.ramp.iter().collect::<String>(), c.ramp.len());
            println!("  palette {} entries", c.palette.len());
            if let Some(p) = arg(&args, "--atlas") {
                match atlas::Atlas::load(&p) {
                    Ok(a) => println!("  atlas  {} codepoints at {}x{} px  (font {})",
                                      a.len(), a.cell_w, a.cell_h,
                                      a.font_sha256.iter().take(8).map(|b| format!("{b:02x}")).collect::<String>()),
                    Err(e) => println!("  atlas  ERROR: {e}"),
                }
            }
        }
        "ansi" => {
            let secs = arg(&args, "--seconds").and_then(|s| s.parse::<f64>().ok());
            let mut out = std::io::stdout();
            match ansi::run(&c, secs.map(Duration::from_secs_f64), &mut out) {
                Ok(s) => eprintln!(
                    "{} frames, {} of {} cells written ({:.1}% -- the rest were static)",
                    s.frames, s.cells_written, s.cells_possible,
                    s.cells_written as f64 / s.cells_possible.max(1) as f64 * 100.0),
                Err(e) => { eprintln!("render: {e}"); std::process::exit(1) }
            }
        }
        "raster" => {
            let ap = arg(&args, "--atlas").unwrap_or_else(|| usage());
            let out = arg(&args, "--out").unwrap_or_else(|| usage());
            let frame: usize = arg(&args, "--frame").and_then(|s| s.parse().ok()).unwrap_or(0);
            let a = match atlas::Atlas::load(&ap) {
                Ok(a) => a, Err(e) => { eprintln!("render: {e}"); std::process::exit(1) }
            };
            let (w, h, buf) = raster::frame_to_bgra(&c, &a, frame.min(c.frames as usize - 1), [5, 6, 10]);
            if let Err(e) = raster::write_ppm(&out, w, h, &buf) {
                eprintln!("render: {e}"); std::process::exit(1);
            }
            println!("frame {frame} -> {out}  {w}x{h} px");
        }
        "still" => {
            // One frame as ANSI text. This is how the console banner is
            // produced: derived from the bake like every other still, so a
            // re-bake reaches the console the way it reaches everything else.
            // A hand-written banner is one that goes on showing last year's
            // hero for ever (§9.5).
            let out = arg(&args, "--out").unwrap_or_else(|| usage());
            let frame: usize = arg(&args, "--frame").and_then(|s| s.parse().ok()).unwrap_or(0);
            let f = frame.min(c.frames as usize - 1);
            let g = c.glyphs(f);
            let col = c.colours(f);
            let mut s = String::new();
            for row in 0..c.rows as usize {
                let mut last: Option<u8> = None;
                let mut line = String::new();
                for x in 0..c.cols as usize {
                    let i = row * c.cols as usize + x;
                    let ch = *c.ramp.get(g[i] as usize).unwrap_or(&' ');
                    if ch == ' ' {
                        line.push(' ');
                        continue;
                    }
                    if last != Some(col[i]) {
                        let p = c.palette[col[i] as usize];
                        line.push_str(&format!("\x1b[38;2;{};{};{}m", p[0], p[1], p[2]));
                        last = Some(col[i]);
                    }
                    line.push(ch);
                }
                // Trailing blanks carry no ink and only make the file bigger.
                while line.ends_with(' ') { line.pop(); }
                s.push_str(&line);
                s.push_str("\x1b[0m\n");
            }
            if let Err(e) = std::fs::write(&out, s) {
                eprintln!("render: {e}"); std::process::exit(1);
            }
            println!("frame {f} -> {out}  {}x{} cells", c.cols, c.rows);
        }
        "layershell" => {
            let ap = arg(&args, "--atlas").unwrap_or_else(|| usage());
            let a = match atlas::Atlas::load(&ap) {
                Ok(a) => a, Err(e) => { eprintln!("render: {e}"); std::process::exit(1) }
            };
            let overlay = arg(&args, "--layer").as_deref() == Some("overlay");
            let force = args.iter().any(|x| x == "--force-animate");
            let name = if overlay { "null-screensaver" } else { "null-wallpaper" };
            if let Err(e) = layershell::run(c, a, name, overlay, force) {
                eprintln!("render: {e}"); std::process::exit(1);
            }
        }
        other => { eprintln!("render: unknown backend {other:?}"); usage() }
    }
}
