//! Derive this screen's ASCII from the packed master (NULL.md §5.3, §0.5).
//!
//! A port of bake/derive_for_screen.py, and the reason for the port is that
//! the Python one needs numpy: about 30 MB on every installed machine, to run
//! for two minutes once per screen. Nothing else on an installed machine needs
//! numpy at all.
//!
//! THIS MUST AGREE WITH THE PYTHON, and "must" is checked rather than hoped
//! for -- verify/check-derive-parity.sh derives the same grid both ways and
//! compares the files. Two implementations of one tone curve is exactly the
//! kind of thing that drifts silently, and the drift would look like a slightly
//! different picture rather than a bug.

use std::io::Read;
use std::path::Path;

// --- the packed master (bake/pack_master.py) --------------------------------

const MASTER_MAGIC: &[u8; 4] = b"NLHM";
const MASTER_VERSION: u16 = 1;
const MAX_MASTER_BYTES: u64 = 512 * 1024 * 1024;

pub struct Master {
    pub cols: usize,
    pub rows: usize,
    pub frames: usize,
    pub fps: u16,
    /// black percentile, white percentile, gamma -- swept by bake/tune.py and
    /// carried IN the master, because a machine deriving its own grid cannot
    /// re-run a sweep and the defaults blank a third of the subject.
    pub tone: (f32, f32, f32),
    /// frames * rows * cols * 2, interleaved (luminance, temperature).
    pub data: Vec<f32>,
}

fn rd<const N: usize>(r: &mut impl Read) -> Result<[u8; N], String> {
    let mut b = [0u8; N];
    r.read_exact(&mut b).map_err(|e| e.to_string())?;
    Ok(b)
}

/// IEEE 754 binary16 -> f32. Written out rather than pulling in a crate: it is
/// twenty lines and this is the only place the project needs it.
fn f16_to_f32(bits: u16) -> f32 {
    let sign = ((bits >> 15) & 1) as u32;
    let exp = ((bits >> 10) & 0x1f) as u32;
    let frac = (bits & 0x3ff) as u32;
    let out = match exp {
        0 if frac == 0 => sign << 31,
        // Subnormal: normalise it by hand.
        0 => {
            let mut e = 0i32;
            let mut f = frac;
            while f & 0x400 == 0 { f <<= 1; e -= 1; }
            let f = f & 0x3ff;
            (sign << 31) | (((127 - 15 + e + 1) as u32) << 23) | (f << 13)
        }
        0x1f => (sign << 31) | (0xff << 23) | (frac << 13),
        _ => (sign << 31) | ((exp + 127 - 15) << 23) | (frac << 13),
    };
    f32::from_bits(out)
}

impl Master {
    pub fn load(path: &Path) -> Result<Self, String> {
        let f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if f.metadata().map_err(|e| e.to_string())?.len() > MAX_MASTER_BYTES {
            return Err(format!("{}: compressed master exceeds the 512 MiB limit", path.display()));
        }
        let mut r = std::io::BufReader::new(f);
        if &rd::<4>(&mut r)? != MASTER_MAGIC {
            return Err(format!("{}: not a hero master", path.display()));
        }
        let version = u16::from_le_bytes(rd(&mut r)?);
        if version != MASTER_VERSION {
            return Err(format!("{}: master version {version}, expected {MASTER_VERSION}", path.display()));
        }
        let cols = u16::from_le_bytes(rd(&mut r)?) as usize;
        let rows = u16::from_le_bytes(rd(&mut r)?) as usize;
        let frames = u16::from_le_bytes(rd(&mut r)?) as usize;
        let fps = u16::from_le_bytes(rd(&mut r)?);
        let tone = (
            f32::from_le_bytes(rd(&mut r)?),
            f32::from_le_bytes(rd(&mut r)?),
            f32::from_le_bytes(rd(&mut r)?),
        );
        let raw_len = u64::from_le_bytes(rd(&mut r)?);
        if cols == 0 || rows == 0 || frames == 0 || fps == 0 {
            return Err(format!("{}: master geometry, frames and fps must be nonzero", path.display()));
        }
        if !tone.0.is_finite() || !tone.1.is_finite() || !tone.2.is_finite()
            || !(0.0 <= tone.0 && tone.0 < tone.1 && tone.1 <= 100.0 && tone.2 > 0.0) {
            return Err(format!("{}: invalid master tone curve", path.display()));
        }
        let want = (frames as u64).checked_mul(rows as u64)
            .and_then(|v| v.checked_mul(cols as u64)).and_then(|v| v.checked_mul(4))
            .ok_or_else(|| format!("{}: master geometry exceeds the size limit", path.display()))?;
        if want > MAX_MASTER_BYTES || raw_len > MAX_MASTER_BYTES {
            return Err(format!("{}: master payload exceeds the 512 MiB limit", path.display()));
        }
        if raw_len != want {
            return Err(format!("{}: master payload header says {raw_len}, geometry needs {want}", path.display()));
        }
        let mut decoder = zstd::stream::read::Decoder::new(r)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        decoder.window_log_max(27).map_err(|e| e.to_string())?;
        let mut payload = Vec::new();
        decoder.take(want + 1).read_to_end(&mut payload)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if payload.len() as u64 != raw_len {
            return Err(format!("{}: payload {} bytes, header says {raw_len}", path.display(), payload.len()));
        }
        let data = payload.chunks_exact(2)
            .enumerate().map(|(i, c)| {
                let value = f16_to_f32(u16::from_le_bytes([c[0], c[1]]));
                if !value.is_finite() || value < 0.0 {
                    Err(format!("{}: nonfinite or negative master sample {i}", path.display()))
                } else { Ok(value) }
            }).collect::<Result<Vec<_>, _>>()?;
        Ok(Master { cols, rows, frames, fps, tone, data })
    }
}

// --- the ramp ---------------------------------------------------------------

pub struct Ramp {
    pub chars: String,
    coverage: Vec<f32>,
    peak: f32,
    /// Midpoints of MEASURED coverage. Steps are uneven and quantised, so even
    /// spacing would put every boundary in the wrong place (§2.4).
    bounds: Vec<f32>,
    steps: Vec<f32>,
    /// Glyph count, counted ONCE.
    ///
    /// `len()` was `self.chars.chars().count()` -- a full UTF-8 walk of the
    /// ramp string -- and `hysteresis()` calls it for every cell. At 3840x2160
    /// that is 55 million decodes of the same short string, and it was most of
    /// what a derive spent its time on.
    n_glyphs: usize,
}

impl Ramp {
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let chars = v.get("ramp").and_then(|r| r.as_str())
            .ok_or_else(|| format!("{}: no \"ramp\"", path.display()))?.to_string();
        let coverage: Vec<f32> = v.get("coverage").and_then(|c| c.as_array())
            .ok_or_else(|| format!("{}: no \"coverage\"", path.display()))?
            .iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect();
        if coverage.len() != chars.chars().count() {
            return Err(format!("{}: {} coverages for {} glyphs",
                               path.display(), coverage.len(), chars.chars().count()));
        }
        if coverage.len() < 2 || chars.len() > u8::MAX as usize {
            return Err(format!("{}: ramp needs at least two glyphs and at most 255 UTF-8 bytes", path.display()));
        }
        if coverage.iter().any(|c| !c.is_finite() || !(0.0..=1.0).contains(c)) {
            return Err(format!("{}: ramp coverage must be finite and between 0 and 1", path.display()));
        }
        if coverage.windows(2).any(|w| w[1] <= w[0]) {
            return Err(format!("{}: ramp is not monotonic in measured coverage (§2.3)", path.display()));
        }
        // An empty ramp passes the length check above (0 coverages for 0 glyphs)
        // and the monotonic check (no windows), then reaches here. Err, not a
        // last().unwrap() panic -- first-boot derivation reads this file, and it
        // already fails gracefully on every other malformed ramp.
        let peak = match coverage.last() {
            Some(&p) => p,
            None => return Err(format!("{}: ramp is empty", path.display())),
        };
        let bounds: Vec<f32> = coverage.windows(2).map(|w| (w[0] + w[1]) / 2.0).collect();
        let steps: Vec<f32> = coverage.windows(2).map(|w| w[1] - w[0]).collect();
        let n_glyphs = chars.chars().count();
        Ok(Ramp { chars, coverage, peak, bounds, steps, n_glyphs })
    }

    fn len(&self) -> usize { self.n_glyphs }

    /// numpy's searchsorted(bounds, t, side='left'): how many bounds are < t.
    fn ideal_index(&self, t: f32) -> u8 {
        self.bounds.partition_point(|&b| b < t) as u8
    }

    /// Move a cell only when it crosses a boundary by `margin` of a step.
    /// The margin governs WHETHER to move, not how far -- a cell that moves
    /// goes straight to the ideal.
    fn hysteresis(&self, target: f32, current: u8, margin: f32) -> u8 {
        let n = self.len() as i32;
        let idx = current as i32;

        let up_from = idx.clamp(0, n - 2) as usize;
        let up_thr = self.bounds[up_from] + margin * self.steps[up_from];
        let can_up = idx < n - 1 && target > up_thr;

        let dn_from = (idx - 1).clamp(0, n - 2) as usize;
        let dn_thr = self.bounds[dn_from] - margin * self.steps[dn_from];
        let can_dn = idx > 0 && target < dn_thr;

        let ideal = self.ideal_index(target) as i32;
        if can_up && ideal > idx { return ideal as u8 }
        if can_dn && ideal < idx { return ideal as u8 }
        current
    }
}

// --- resampling -------------------------------------------------------------

/// Weights that average input spans exactly: every input cell contributes in
/// proportion to how much of it the output cell covers. Not nearest-neighbour
/// and not bilinear -- an average of radiance, not a sample of it.
fn area_weights(n_in: usize, n_out: usize) -> Vec<Vec<(usize, f32)>> {
    let scale = n_in as f64 / n_out as f64;
    (0..n_out).map(|i| {
        let (lo, hi) = (i as f64 * scale, (i + 1) as f64 * scale);
        let first = lo.floor() as usize;
        let last = (hi.ceil() as usize).min(n_in);
        let mut w: Vec<(usize, f32)> = (first..last)
            .map(|j| (j, (hi.min(j as f64 + 1.0) - lo.max(j as f64)) as f32))
            .filter(|&(_, v)| v > 0.0)
            .collect();
        let s: f32 = w.iter().map(|&(_, v)| v).sum();
        if s > 0.0 { for e in w.iter_mut() { e.1 /= s } }
        w
    }).collect()
}

/// The largest sub-grid of (cols, rows) with the master's ratio. A target of a
/// different ratio is a different FRAMING, and §5.3 is explicit that a framing
/// needs its own camera rather than a stretched copy of someone else's -- so
/// the hero is fitted inside and centred, and the rest is void.
pub fn fit_preserving_aspect(m_cols: usize, m_rows: usize, cols: usize, rows: usize) -> (usize, usize) {
    let by_width = (cols, (round_half_even(cols as f64 * m_rows as f64 / m_cols as f64) as usize).max(1));
    if by_width.1 <= rows { return by_width }
    ((round_half_even(rows as f64 * m_cols as f64 / m_rows as f64) as usize).max(1), rows)
}

/// HALF TO EVEN, because Python's round() is and this has to agree with it.
///
/// Rust's f64::round() goes half away from zero. On an 80x24 grid the fitted
/// height is round(22.5): Python says 22, Rust said 23, and the two derivers
/// then produced entirely different pictures -- 83% agreement with cells
/// thirteen ramp steps apart, where a 227x64 grid had agreed on 99.999% of
/// them. It only shows when the arithmetic lands exactly on a half, so most
/// grids never reveal it, which is precisely why the parity check derives a
/// grid chosen to be awkward rather than a grid that happens to be in use.
fn round_half_even(x: f64) -> f64 {
    let r = x.round();
    if (x.fract().abs() - 0.5).abs() < f64::EPSILON && r % 2.0 != 0.0 {
        r - x.signum()
    } else {
        r
    }
}

#[cfg(test)]
mod rounding {
    use super::round_half_even;
    #[test]
    fn matches_python() {
        // python3 -c "print([round(v) for v in (22.5,23.5,-22.5,22.4,22.6,0.5,1.5)])"
        for (input, want) in [(22.5, 22.0), (23.5, 24.0), (-22.5, -22.0),
                              (22.4, 22.0), (22.6, 23.0), (0.5, 0.0), (1.5, 2.0)] {
            assert_eq!(round_half_even(input), want, "round_half_even({input})");
        }
    }
}

// --- the tone curve and quantisation ---------------------------------------

/// Log-exposure with two INDEPENDENT anchors (§4.1). One parameter cannot serve
/// as both toe and spread.
fn tone_curve(l: f32, black: f32, white: f32, gamma: f32) -> f32 {
    Tone::new(black, white, gamma).apply(l)
}

/// The tone curve with its constants worked out once.
///
/// `tone_curve` recomputed `black.ln()` and `white.ln()` on every call, and
/// called `powf` on every call -- and it is called once per cell, per frame,
/// per hysteresis iteration: 110 million times for a 3840x2160 grid. Two
/// logarithms and a pow of loop-invariant arguments, 110 million times.
///
/// The arithmetic is UNCHANGED, deliberately: `num / den` stays a division
/// rather than becoming a multiply by a precomputed reciprocal, which would
/// give different last bits and therefore, occasionally, a different glyph.
/// `powf(1.0)` is exactly the identity in IEEE 754, so skipping it when gamma
/// is 1 is not an approximation either.
struct Tone { lb: f32, den: f32, gamma: f32, unit_gamma: bool }

impl Tone {
    fn new(black: f32, white: f32, gamma: f32) -> Self {
        let lb = black.ln();
        Tone { lb, den: white.ln() - lb, gamma, unit_gamma: gamma == 1.0 }
    }
    #[inline]
    fn apply(&self, l: f32) -> f32 {
        let v = ((l.max(1e-12).ln() - self.lb) / self.den).clamp(0.0, 1.0);
        if self.unit_gamma { v } else { v.powf(self.gamma) }
    }
}

/// numpy.percentile with the default linear interpolation.
fn percentile(sorted: &[f32], q: f32) -> f32 {
    if sorted.is_empty() { return 0.0 }
    let pos = (q as f64 / 100.0) * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi { return sorted[lo] }
    let frac = (pos - lo as f64) as f32;
    sorted[lo] + (sorted[hi] - sorted[lo]) * frac
}

const N_VALUES: u16 = 8;

pub struct Derived {
    pub cols: usize,
    pub rows: usize,
    pub fps: u16,
    pub glyphs: Vec<Vec<u8>>,
    pub colours: Vec<Vec<u8>>,
}

/// Resample the master onto this grid and quantise it, exactly as the bake
/// does: exposure over the whole sequence, hysteresis to a fixed point, and a
/// loop-closure check that refuses to return a sequence with a seam.
pub fn derive(master: &Master, cols: usize, rows: usize, ramp: &Ramp,
              pal_temps: &[f32], k_residual: f32, hysteresis: f32,
              log: &mut dyn FnMut(&str)) -> Result<Derived, String> {
    // WHERE THE TIME WENT, every time. A derive is the longest thing this
    // system does on demand -- a newly plugged monitor waits for it -- and it
    // used to be a single opaque pause. Two rounds of optimising the wrong
    // phase is what this line is here to prevent.
    let t_start = std::time::Instant::now();
    let mut mark = t_start;
    let mut phase = |what: &str, log: &mut dyn FnMut(&str)| {
        let d = mark.elapsed();
        mark = std::time::Instant::now();
        log(&format!("  {what}: {:.2}s", d.as_secs_f64()));
    };

    let (hc, hr) = fit_preserving_aspect(master.cols, master.rows, cols, rows);
    log(&format!("master {}x{} -> hero {hc}x{hr} inside a {cols}x{rows} grid ({}% of the cells)",
                 master.cols, master.rows, 100 * hc * hr / (cols * rows)));

    let wc = area_weights(master.cols, hc);
    let wr = area_weights(master.rows, hr);
    let (y0, x0) = ((rows - hr) / 2, (cols - hc) / 2);

    // Separable area resample, in the HDR domain. Quantisation happens once,
    // afterwards -- never the other way round, because glyph indices cannot be
    // averaged: the mean of '.' and '@' is a different glyph, not a tone.
    //
    // ONE THREAD PER CHUNK OF FRAMES. Frames do not see each other here -- each
    // reads its own slice of the master and writes its own output -- so this
    // splits with no coordination beyond the join. (Quantisation below is a
    // different matter: hysteresis carries state from one frame to the next,
    // and it stays sequential.)
    //
    // It is the whole cost of a derive. Measured on a 4-core guest, a first
    // sight of a new monitor: 24.3s at 1920x1080, 57.8s at 3840x2160. That is
    // how long a freshly plugged screen shows the prebuilt rung instead of its
    // own exact grid.
    //
    // std::thread::scope rather than a thread pool crate, because the RPM
    // builds with `cargo build --offline` and a new dependency would have to be
    // vendored to be worth 3x.
    let mut l_frames: Vec<Vec<f32>> = vec![Vec::new(); master.frames];
    let mut t_frames: Vec<Vec<f32>> = vec![Vec::new(); master.frames];
    // chunks_mut PANICS ON A CHUNK SIZE OF ZERO, and a master with no frames
    // produces exactly that: threads clamps to 1, and 0.div_ceil(1) is 0. A
    // truncated master whose header honestly says "0 frames" passes every
    // check Master::load makes, so it reached this line and aborted with
    // "chunk size must be non-zero" -- where the single-threaded version this
    // replaced fell through to the real error below.
    //
    // Both .max(1)s are load-bearing; neither is defensive noise.
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(master.frames).max(1);
    let per = master.frames.div_ceil(threads).max(1);
    log(&format!("  resampling {} frames across {threads} thread(s)", master.frames));
    std::thread::scope(|scope| {
        for (ci, (lch, tch)) in l_frames.chunks_mut(per).zip(t_frames.chunks_mut(per)).enumerate() {
            let (wc, wr, master) = (&wc, &wr, &*master);
            scope.spawn(move || {
                let mut mid = vec![0f32; hr * master.cols * 2];
                for (k, (lslot, tslot)) in lch.iter_mut().zip(tch.iter_mut()).enumerate() {
                    let f = ci * per + k;
                    let base = f * master.rows * master.cols * 2;
                    for (oy, wrow) in wr.iter().enumerate() {
                        for x in 0..master.cols {
                            let (mut al, mut at) = (0f32, 0f32);
                            for &(sy, w) in wrow {
                                let i = base + (sy * master.cols + x) * 2;
                                al += master.data[i] * w;
                                at += (master.data[i] * master.data[i + 1]) * w;
                            }
                            mid[(oy * master.cols + x) * 2] = al;
                            mid[(oy * master.cols + x) * 2 + 1] = at;
                        }
                    }
                    // Mid stores the additive moments (L, L*T). Divide only
                    // after both axes, so void does not cool an emitting cell.
                    let mut lf = vec![0f32; rows * cols];
                    let mut tf = vec![0f32; rows * cols];
                    for oy in 0..hr {
                        for (ox, wcol) in wc.iter().enumerate() {
                            let (mut al, mut at) = (0f32, 0f32);
                            for &(sx, w) in wcol {
                                al += mid[(oy * master.cols + sx) * 2] * w;
                                at += mid[(oy * master.cols + sx) * 2 + 1] * w;
                            }
                            lf[(y0 + oy) * cols + x0 + ox] = al;
                            tf[(y0 + oy) * cols + x0 + ox] = if al > 0.0 { at / al } else { 0.0 };
                        }
                    }
                    *lslot = lf;
                    *tslot = tf;
                }
            });
        }
    });

    phase("resample", log);

    // --- global exposure over the whole sequence (§4.1) ---------------------
    let mut lit: Vec<f32> = l_frames.iter().flatten().copied().filter(|&v| v > 0.0).collect();
    if lit.is_empty() { return Err("every cell is dark -- nothing to expose".into()) }
    lit.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let black = percentile(&lit, master.tone.0);
    let white = percentile(&lit, master.tone.1);
    let gamma = master.tone.2;
    log(&format!("  exposure: black P{} = {black:.6}, white P{} = {white:.6}, gamma {gamma}",
                 master.tone.0, master.tone.1));

    phase("exposure", log);

    let n = cols * rows;

    // THE BIN EDGES DO NOT DEPEND ON THE CELL.
    //
    // This was `pal_temps.windows(2).map(...).collect::<Vec<f32>>()` INSIDE the
    // per-cell loop: one heap allocation and one full pass over the palette for
    // every cell, of every frame, of every hysteresis iteration. At 320x90 that
    // is 28800 cells x frames x iterations allocations to compute the same
    // array every time.
    //
    // Hoisting it is where a derive's time actually was. Splitting the resample
    // across cores first bought 2%; this bought the rest.
    let t_edges: Vec<f32> = pal_temps.windows(2).map(|w| (w[0] + w[1]) / 2.0).collect();
    let tone = Tone::new(black, white, gamma);

    let quantise_frame = |l: &[f32], t: &[f32], state: &[u8], g: &mut Vec<u8>, c: &mut Vec<u8>| {
        g.clear(); c.clear();
        for i in 0..n {
            let target = tone.apply(l[i]) * ramp.peak;
            let glyph = ramp.hysteresis(target, state[i], hysteresis);
            // The residual is what the chosen glyph over- or under-states.
            // Colour carries it, which is what removes banding without
            // dithering (§4.3, I4).
            let residual = (target - ramp.coverage[glyph as usize]) / ramp.peak;
            let v = (0.5 + k_residual * residual).clamp(0.0, 1.0);
            let value_idx = ((v * (N_VALUES - 1) as f32).round() as i32).clamp(0, N_VALUES as i32 - 1) as u16;
            let t_idx = t_edges.partition_point(|&e| e < t[i]) as u16;
            // The void is the space character and carries no colour (I3).
            let colour = if glyph == 0 { 0 } else { (t_idx * N_VALUES + value_idx) as u8 };
            g.push(glyph); c.push(colour);
        }
    };

    // --- hysteresis to a fixed point (§4.4) --------------------------------
    let mut state: Vec<u8> = l_frames[0].iter()
        .map(|&l| ramp.ideal_index(tone.apply(l) * ramp.peak)).collect();
    let mut glyphs: Option<Vec<Vec<u8>>> = None;
    let mut colours: Vec<Vec<u8>> = Vec::new();
    for it in 0..12 {
        let mut gp = Vec::with_capacity(master.frames);
        let mut cp = Vec::with_capacity(master.frames);
        let (mut g, mut c) = (Vec::with_capacity(n), Vec::with_capacity(n));
        for f in 0..master.frames {
            quantise_frame(&l_frames[f], &t_frames[f], &state, &mut g, &mut c);
            state.copy_from_slice(&g);
            gp.push(g.clone()); cp.push(c.clone());
        }
        if let Some(prev) = &glyphs {
            if prev == &gp {
                log(&format!("  hysteresis converged after {it} iteration(s)"));
                colours = cp;
                glyphs = Some(gp);
                break;
            }
        }
        glyphs = Some(gp); colours = cp;
        if it == 11 { return Err("hysteresis did not converge in 12 iterations".into()) }
    }
    let glyphs = glyphs.unwrap();
    phase("hysteresis", log);

    // --- loop closure, exact (§10.3) ---------------------------------------
    // Re-quantise frame 0 from the state AFTER the last frame. If it does not
    // come back identical the loop has a seam, and nothing is returned.
    let (mut g0, mut c0) = (Vec::with_capacity(n), Vec::with_capacity(n));
    quantise_frame(&l_frames[0], &t_frames[0], glyphs.last().unwrap(), &mut g0, &mut c0);
    let bad = g0.iter().zip(&glyphs[0]).filter(|(a, b)| a != b).count();
    if bad > 0 { return Err(format!("LOOP CLOSURE FAILED: {bad} glyph cells differ on the wrap")) }
    let badc = c0.iter().zip(&colours[0]).filter(|(a, b)| a != b).count();
    if badc > 0 { return Err(format!("LOOP CLOSURE FAILED: {badc} colour cells differ on the wrap")) }
    log("  LOOP CLOSURE: frame 0 reproduces byte-identically from the final state");

    Ok(Derived { cols, rows, fps: master.fps, glyphs, colours })
}

// --- writing the cells file (bake/formats.py write_cells) -------------------

// The SAME magic and version the renderer reads (render/src/cells.rs) and the
// bake writes (bake/formats.py). Invented here first, which would have produced
// files nothing could open.
const CEL_MAGIC: &[u8; 4] = b"RCEL";
const CEL_VERSION: u16 = 1;

// COMPRESSION LEVEL IS A CHOICE, AND 19 WAS THE WRONG ONE HERE.
//
// This was hard-coded at zstd 19 -- near maximum -- and it was the single
// largest cost of deriving a hero: 12.3s of a 19.6s derive at 1920x1080, and
// well over half a minute at 3840x2160. A newly plugged monitor waits for that.
//
// These files are a LOCAL CACHE under /var/cache/nulllinux, written once and
// mmapped thereafter. What level 19 buys over level 3 is a few percent of a
// file nobody ships. What it costs is the entire wait.
//
// The shipped assets are a different matter and are written by the bake in
// Python, which is not on anyone's critical path and can take as long as it
// likes.
pub const CACHE_ZSTD_LEVEL: i32 = 9;

pub fn write_cells(path: &Path, d: &Derived, ramp: &Ramp, palette: &[[u8; 3]], level: i32) -> Result<(), String> {
    let mut header: Vec<u8> = Vec::new();
    header.extend_from_slice(CEL_MAGIC);
    header.extend_from_slice(&CEL_VERSION.to_le_bytes());
    header.extend_from_slice(&(d.cols as u16).to_le_bytes());
    header.extend_from_slice(&(d.rows as u16).to_le_bytes());
    header.extend_from_slice(&(d.glyphs.len() as u16).to_le_bytes());
    header.extend_from_slice(&d.fps.to_le_bytes());
    let rb = ramp.chars.as_bytes();
    header.push(rb.len() as u8);
    header.extend_from_slice(rb);
    // 256 does not fit in a byte -- this field is 16-bit by design (§5.2).
    header.extend_from_slice(&(palette.len() as u16).to_le_bytes());
    for p in palette { header.extend_from_slice(p); }

    let mut payload: Vec<u8> = Vec::with_capacity(d.glyphs.len() * d.cols * d.rows * 2);
    for (g, c) in d.glyphs.iter().zip(&d.colours) {
        payload.extend_from_slice(g);
        payload.extend_from_slice(c);
    }
    let body = zstd::encode_all(&payload[..], level).map_err(|e| e.to_string())?;

    let mut out = header;
    out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
    out.extend_from_slice(&body);
    // Written whole, then renamed by the caller: a reader that opens a
    // half-written cells file sees a truncated animation rather than an error.
    std::fs::write(path, &out).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod speed_is_not_a_licence_to_change_the_picture {
    use super::*;

    // The optimisations in this file are only allowed because they compute the
    // same numbers. These pin that, so a later "obvious" tidy-up -- folding the
    // division into a reciprocal, dropping the gamma branch -- fails here
    // rather than quietly moving glyphs.

    /// The hoisted form must equal the literal formula, bit for bit.
    #[test]
    fn hoisting_the_logs_changes_nothing() {
        let (black, white) = (0.000005_f32, 0.895874_f32);
        for &gamma in &[1.0_f32, 0.8, 2.2] {
            let tone = Tone::new(black, white, gamma);
            for i in 0..2000 {
                let l = (i as f32) * 0.0007;
                let literal = {
                    let num = l.max(1e-12).ln() - black.ln();
                    let den = white.ln() - black.ln();
                    (num / den).clamp(0.0, 1.0).powf(gamma)
                };
                assert_eq!(tone.apply(l).to_bits(), literal.to_bits(),
                           "l={l} gamma={gamma}: hoisting changed the value");
            }
        }
    }

    /// Skipping powf at gamma 1 is exact, not an approximation.
    #[test]
    fn powf_one_is_the_identity() {
        for i in 0..1000 {
            let v = (i as f32) / 999.0;
            assert_eq!(v.powf(1.0).to_bits(), v.to_bits(), "powf(1.0) moved {v}");
        }
        assert!(Tone::new(0.1, 0.9, 1.0).unit_gamma);
        assert!(!Tone::new(0.1, 0.9, 2.2).unit_gamma);
    }

    /// n_glyphs replaced chars().count(); it must still be the glyph count and
    /// not the byte count, because the ramp is not necessarily ASCII.
    #[test]
    fn glyph_count_counts_glyphs_not_bytes() {
        let r = Ramp {
            chars: " ·▒█".to_string(),           // 4 glyphs, 10 bytes
            coverage: vec![0.0, 0.3, 0.6, 1.0],
            peak: 1.0,
            bounds: vec![0.15, 0.45, 0.8],
            steps: vec![0.3, 0.3, 0.4],
            n_glyphs: " ·▒█".chars().count(),
        };
        assert_eq!(r.len(), 4);
        assert_ne!(r.chars.len(), 4, "the fixture is not testing anything");
    }

    /// The cache level is a cache level. If someone raises it back to 19 for
    /// tidiness, a derive gets twelve seconds slower for a file nobody ships.
    #[test]
    fn the_cache_is_not_compressed_for_shipping() {
        assert!(CACHE_ZSTD_LEVEL <= 12,
                "zstd {CACHE_ZSTD_LEVEL} on a local cache costs more time than the bytes are worth");
    }
}

#[cfg(test)]
mod a_bad_master_is_an_error_not_a_crash {
    use super::*;

    fn ramp() -> Ramp {
        Ramp {
            chars: " .:@".to_string(),
            coverage: vec![0.0, 0.3, 0.6, 1.0],
            peak: 1.0,
            bounds: vec![0.15, 0.45, 0.8],
            steps: vec![0.3, 0.3, 0.4],
            n_glyphs: 4,
        }
    }

    #[test]
    fn every_binary16_subnormal_has_the_ieee_value() {
        for frac in 1..=1023_u16 {
            let expected = frac as f32 * 2.0_f32.powi(-24);
            assert_eq!(f16_to_f32(frac), expected, "positive {frac:#06x}");
            assert_eq!(f16_to_f32(frac | 0x8000), -expected, "negative {frac:#06x}");
        }
        assert_eq!(f16_to_f32(0x0400), 2.0_f32.powi(-14));
        assert_eq!(f16_to_f32(0x8000).to_bits(), (-0.0_f32).to_bits());
        assert!(f16_to_f32(0x7c00).is_infinite());
        assert!(f16_to_f32(0x7e00).is_nan());
    }

    #[test]
    fn dark_subsamples_do_not_cool_a_lit_cell() {
        let row = [1.0, 6000.0, 0.0, 0.0, 0.01, 2000.0, 0.01, 2000.0,
                   2.0, 10000.0, 2.0, 10000.0, 0.0, 0.0, 0.0, 0.0];
        let m = Master { cols: 8, rows: 2, frames: 2, fps: 24,
                         tone: (0.0, 100.0, 1.0), data: row.repeat(4) };
        let d = derive(&m, 4, 1, &ramp(), &[2000.0, 6000.0, 10000.0],
                       1.5, 0.25, &mut |_| {}).unwrap();
        assert!(d.glyphs[0][0] > 0);
        assert_eq!(d.colours[0][0] / 8, 1, "the emitting sample is still 6000 K");
    }

    fn master(frames: usize, rows: usize, cols: usize) -> Master {
        Master { cols, rows, frames, fps: 24, tone: (0.0, 99.0, 1.0),
                 data: vec![0.0; frames * rows * cols * 2] }
    }

    fn load_fixture(cols: u16, rows: u16, frames: u16, fps: u16,
                    tone: [f32; 3], halves: &[u16], claimed: Option<u64>) -> Result<Master, String> {
        let mut bytes = MASTER_MAGIC.to_vec();
        for value in [MASTER_VERSION, cols, rows, frames, fps] {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        for value in tone { bytes.extend_from_slice(&value.to_le_bytes()); }
        let raw: Vec<u8> = halves.iter().flat_map(|v| v.to_le_bytes()).collect();
        bytes.extend_from_slice(&claimed.unwrap_or(raw.len() as u64).to_le_bytes());
        bytes.extend(zstd::encode_all(&raw[..], 1).unwrap());
        let unique = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("null-master-test-{}-{unique}", std::process::id()));
        std::fs::write(&path, bytes).unwrap();
        let result = Master::load(&path);
        std::fs::remove_file(&path).unwrap();
        result
    }

    #[test]
    fn ramp_rejects_missing_boundaries_unrepresentable_length_and_bad_coverage() {
        let docs = [
            serde_json::json!({"ramp": " ", "coverage": [0.0]}),
            serde_json::json!({"ramp": " .", "coverage": [-0.1, 0.5]}),
            serde_json::json!({"ramp": " .", "coverage": [0.0, 1.1]}),
            serde_json::json!({"ramp": " .", "coverage": [0.0, 1e40]}),
            serde_json::json!({"ramp": "a".repeat(256),
                "coverage": (0..256).map(|i| i as f64 / 255.0).collect::<Vec<_>>()}),
        ];
        let unique = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("null-ramp-test-{}-{unique}", std::process::id()));
        for doc in docs {
            std::fs::write(&path, doc.to_string()).unwrap();
            assert!(Ramp::load(&path).is_err(), "accepted {doc}");
        }
        std::fs::write(&path, r#"{"ramp":" ·▒█","coverage":[0,0.3,0.6,1]}"#).unwrap();
        assert!(Ramp::load(&path).is_ok(), "valid Unicode ramp must remain supported");
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn master_rejects_zero_geometry_and_timing() {
        for (cols, rows, frames, fps) in [(0, 1, 1, 24), (1, 0, 1, 24),
                                         (1, 1, 0, 24), (1, 1, 1, 0)] {
            let data = if cols * rows * frames > 0 { vec![0x3800, 0x6800] } else { vec![] };
            assert!(load_fixture(cols, rows, frames, fps, [0.0, 99.0, 1.0], &data, None).is_err());
        }
    }

    #[test]
    fn master_rejects_invalid_exposure_and_nonfinite_samples() {
        for tone in [[f32::NAN, 99.0, 1.0], [0.0, 101.0, 1.0],
                     [50.0, 20.0, 1.0], [0.0, 99.0, 0.0]] {
            assert!(load_fixture(1, 1, 1, 24, tone, &[0x3800, 0x6800], None).is_err());
        }
        for pair in [[0x7e00, 0x6800], [0x3800, 0x7c00], [0xbc00, 0x6800]] {
            assert!(load_fixture(1, 1, 1, 24, [0.0, 99.0, 1.0], &pair, None).is_err());
        }
    }

    #[test]
    fn master_refuses_oversized_header_before_decompression() {
        let result = load_fixture(65535, 65535, 240, 24, [0.0, 99.0, 1.0], &[], Some(600 * 1024 * 1024));
        assert!(result.err().unwrap().contains("limit"));
    }

    /// A header that says "no frames" used to abort the process with
    /// "chunk size must be non-zero" from inside chunks_mut. It has to come
    /// back as a Result, because the caller's job is to say which file was bad.
    #[test]
    fn zero_frames_returns_an_error() {
        let mut log = |_: &str| {};
        let r = derive(&master(0, 36, 64), 16, 6, &ramp(), &[3000.0, 6000.0], 1.5, 0.25, &mut log);
        assert!(r.is_err(), "a zero-frame master must be an error, not a panic or a result");
    }

    /// Fewer frames than cores is the ordinary case on a small master, and it
    /// is the arithmetic most likely to produce a zero or a short chunk.
    #[test]
    fn fewer_frames_than_threads_still_covers_every_frame() {
        let mut log = |_: &str| {};
        for frames in 1..=5 {
            let mut m = master(frames, 8, 8);
            // Something for the exposure step to find, or it errs for a
            // different and less interesting reason.
            for v in m.data.iter_mut() { *v = 0.5 }
            let d = derive(&m, 8, 8, &ramp(), &[3000.0, 6000.0], 1.5, 0.25, &mut log)
                .unwrap_or_else(|e| panic!("{frames} frame(s): {e}"));
            assert_eq!(d.glyphs.len(), frames, "{frames} frame(s): lost a frame in the split");
            assert_eq!(d.colours.len(), frames, "{frames} frame(s): lost a colour plane");
        }
    }
}
