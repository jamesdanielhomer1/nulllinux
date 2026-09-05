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
use nulllinux::derive;

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
  outputs                 list the compositor's screens: name, w, h, scale
  derive                  build a cells file for one grid from the master

options:
  --seconds N             stop after N seconds (ansi)
  --layer overlay         map on the overlay layer (implies --force-animate)
  --force-animate         never suspend, even when occluded
  --output NAME           pin the surface to one screen (layershell)
  --master F --cols N --rows M --ramp F --out F      (derive)
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

    // The backend is the first bare word that is not the value of a flag.
    //
    // NOT EVERY FLAG TAKES A VALUE. This skipped two tokens for any `--flag`,
    // so `--force-animate layershell` consumed the backend name as if it were
    // the flag's argument and the whole command fell through to usage(). It was
    // invisible because the only two callers pass either no valueless flag or
    // one that happens to come last.
    const VALUELESS: [&str; 1] = ["--force-animate"];
    let backend = {
        let mut found = None;
        let mut i = 0;
        while i < args.len() {
            if args[i].starts_with("--") {
                i += if VALUELESS.contains(&args[i].as_str()) { 1 } else { 2 };
                continue;
            }
            found = Some(args[i].clone());
            break;
        }
        found.unwrap_or_else(|| usage())
    };

    // `outputs` asks the compositor what screens exist and reads no asset, so
    // it must not require --file. Decided by the backend, before loading.
    if backend == "outputs" {
        let conn = match wayland_client::Connection::connect_to_env() {
            Ok(c) => c, Err(e) => { eprintln!("render: no Wayland display: {e}"); std::process::exit(1) }
        };
        match nulllinux::outputs::list_outputs(&conn) {
            Ok(v) if v.is_empty() => { eprintln!("render: the compositor reports no outputs"); std::process::exit(1) }
            Ok(v) => { for (n, w, h, sc) in v { println!("{n}\t{w}\t{h}\t{sc}") } }
            Err(e) => { eprintln!("render: {e}"); std::process::exit(1) }
        }
        return;
    }

    // `derive` builds a cells file from the master; it reads no cells file, so
    // it must not require --file. Decided by the backend, before loading.
    if backend == "derive" {
        let need = |n: &str| arg(&args, n).unwrap_or_else(|| {
            eprintln!("render derive: {n} is required"); std::process::exit(2) });
        let master = need("--master");
        let out = need("--out");
        let cols: usize = need("--cols").parse().unwrap_or_else(|_| { eprintln!("--cols must be a number"); std::process::exit(2) });
        let rows: usize = need("--rows").parse().unwrap_or_else(|_| { eprintln!("--rows must be a number"); std::process::exit(2) });
        let ramp_p = need("--ramp");
        let pal_meta = arg(&args, "--palette-meta").unwrap_or_else(|| "assets/palette.json".into());
        let pal_bin = arg(&args, "--palette").unwrap_or_else(|| "assets/palette.bin".into());
        let k_residual: f32 = arg(&args, "--k-residual").and_then(|v| v.parse().ok()).unwrap_or(1.5);
        let hyst: f32 = arg(&args, "--hysteresis").and_then(|v| v.parse().ok()).unwrap_or(0.25);

        let die = |e: String| -> ! { eprintln!("render derive: {e}"); std::process::exit(1) };
        let m = derive::Master::load(std::path::Path::new(&master)).unwrap_or_else(|e| die(e));
        let ramp = derive::Ramp::load(std::path::Path::new(&ramp_p)).unwrap_or_else(|e| die(e));

        let meta = std::fs::read_to_string(&pal_meta).unwrap_or_else(|e| die(format!("{pal_meta}: {e}")));
        let mv: serde_json::Value = serde_json::from_str(&meta).unwrap_or_else(|e| die(e.to_string()));
        let temps: Vec<f32> = mv.get("temperatures_K").and_then(|t| t.as_array())
            .unwrap_or_else(|| die(format!("{pal_meta}: no temperatures_K")))
            .iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect();
        let raw = std::fs::read(&pal_bin).unwrap_or_else(|e| die(format!("{pal_bin}: {e}")));
        let palette: Vec<[u8; 3]> = raw.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect();

        let mut log = |s: &str| println!("{s}");
        let d = derive::derive(&m, cols, rows, &ramp, &temps, k_residual, hyst, &mut log)
            .unwrap_or_else(|e| die(e));
        derive::write_cells(std::path::Path::new(&out), &d, &ramp, &palette)
            .unwrap_or_else(|e| die(e));
        let n = std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
        println!("  -> {out}  {n} bytes");
        return;
    }

    let file = arg(&args, "--file").unwrap_or_else(|| usage());
    let c = match cells::Cells::load(&file) {
        Ok(c) => c,
        Err(e) => { eprintln!("render: {e}"); std::process::exit(1) }
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
            let out = arg(&args, "--output");
            if let Err(e) = layershell::run(c, a, name, overlay, force, out.as_deref()) {
                eprintln!("render: {e}"); std::process::exit(1);
            }
        }
        other => { eprintln!("render: unknown backend {other:?}"); usage() }
    }
}
