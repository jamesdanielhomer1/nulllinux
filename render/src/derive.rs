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
            let mut e = -1i32;
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
        let raw_len = u64::from_le_bytes(rd(&mut r)?) as usize;

        let mut comp = Vec::new();
        r.read_to_end(&mut comp).map_err(|e| e.to_string())?;
        let payload = zstd::decode_all(&comp[..]).map_err(|e| format!("{}: {e}", path.display()))?;
        if payload.len() != raw_len {
            return Err(format!("{}: payload {} bytes, header says {raw_len}", path.display(), payload.len()));
        }
        let want = frames * rows * cols * 2 * 2;
        if payload.len() != want {
            return Err(format!("{}: {} bytes for {frames}x{rows}x{cols}x2 f16, expected {want}",
                               path.display(), payload.len()));
        }
        let data = payload.chunks_exact(2)
            .map(|c| f16_to_f32(u16::from_le_bytes([c[0], c[1]])))
            .collect();
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
        if coverage.windows(2).any(|w| w[1] <= w[0]) {
            return Err(format!("{}: ramp is not monotonic in measured coverage (§2.3)", path.display()));
        }
        let peak = *coverage.last().unwrap();
        let bounds: Vec<f32> = coverage.windows(2).map(|w| (w[0] + w[1]) / 2.0).collect();
        let steps: Vec<f32> = coverage.windows(2).map(|w| w[1] - w[0]).collect();
        Ok(Ramp { chars, coverage, peak, bounds, steps })
    }

    fn len(&self) -> usize { self.chars.chars().count() }

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
    let num = l.max(1e-12).ln() - black.ln();
    let den = white.ln() - black.ln();
    (num / den).clamp(0.0, 1.0).powf(gamma)
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
    let (hc, hr) = fit_preserving_aspect(master.cols, master.rows, cols, rows);
    log(&format!("master {}x{} -> hero {hc}x{hr} inside a {cols}x{rows} grid ({}% of the cells)",
                 master.cols, master.rows, 100 * hc * hr / (cols * rows)));

    let wc = area_weights(master.cols, hc);
    let wr = area_weights(master.rows, hr);
    let (y0, x0) = ((rows - hr) / 2, (cols - hc) / 2);

    // Separable area resample, in the HDR domain. Quantisation happens once,
    // afterwards -- never the other way round, because glyph indices cannot be
    // averaged: the mean of '.' and '@' is a different glyph, not a tone.
    let mut l_frames: Vec<Vec<f32>> = Vec::with_capacity(master.frames);
    let mut t_frames: Vec<Vec<f32>> = Vec::with_capacity(master.frames);
    let mut mid = vec![0f32; hr * master.cols * 2];
    for f in 0..master.frames {
        let base = f * master.rows * master.cols * 2;
        for (oy, wrow) in wr.iter().enumerate() {
            for x in 0..master.cols {
                let (mut al, mut at) = (0f32, 0f32);
                for &(sy, w) in wrow {
                    let i = base + (sy * master.cols + x) * 2;
                    al += master.data[i] * w;
                    at += master.data[i + 1] * w;
                }
                mid[(oy * master.cols + x) * 2] = al;
                mid[(oy * master.cols + x) * 2 + 1] = at;
            }
        }
        // The void outside the hero carries the coolest temperature present, so
        // the palette does not read it as a different kind of nothing.
        let mut tmin = f32::INFINITY;
        for oy in 0..hr { for x in 0..master.cols {
            let t = mid[(oy * master.cols + x) * 2 + 1];
            if t < tmin { tmin = t }
        }}
        let mut lf = vec![0f32; rows * cols];
        let mut tf = vec![tmin; rows * cols];
        for oy in 0..hr {
            for (ox, wcol) in wc.iter().enumerate() {
                let (mut al, mut at) = (0f32, 0f32);
                for &(sx, w) in wcol {
                    al += mid[(oy * master.cols + sx) * 2] * w;
                    at += mid[(oy * master.cols + sx) * 2 + 1] * w;
                }
                lf[(y0 + oy) * cols + x0 + ox] = al;
                tf[(y0 + oy) * cols + x0 + ox] = at;
            }
        }
        l_frames.push(lf);
        t_frames.push(tf);
    }

    // --- global exposure over the whole sequence (§4.1) ---------------------
    let mut lit: Vec<f32> = l_frames.iter().flatten().copied().filter(|&v| v > 0.0).collect();
    if lit.is_empty() { return Err("every cell is dark -- nothing to expose".into()) }
    lit.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let black = percentile(&lit, master.tone.0);
    let white = percentile(&lit, master.tone.1);
    let gamma = master.tone.2;
    log(&format!("  exposure: black P{} = {black:.6}, white P{} = {white:.6}, gamma {gamma}",
                 master.tone.0, master.tone.1));

    let n = cols * rows;
    let quantise_frame = |l: &[f32], t: &[f32], state: &[u8], g: &mut Vec<u8>, c: &mut Vec<u8>| {
        g.clear(); c.clear();
        for i in 0..n {
            let target = tone_curve(l[i], black, white, gamma) * ramp.peak;
            let glyph = ramp.hysteresis(target, state[i], hysteresis);
            // The residual is what the chosen glyph over- or under-states.
            // Colour carries it, which is what removes banding without
            // dithering (§4.3, I4).
            let residual = (target - ramp.coverage[glyph as usize]) / ramp.peak;
            let v = (0.5 + k_residual * residual).clamp(0.0, 1.0);
            let value_idx = ((v * (N_VALUES - 1) as f32).round() as i32).clamp(0, N_VALUES as i32 - 1) as u16;
            let t_idx = pal_temps.windows(2).map(|w| (w[0] + w[1]) / 2.0)
                .collect::<Vec<f32>>().partition_point(|&e| e < t[i]) as u16;
            // The void is the space character and carries no colour (I3).
            let colour = if glyph == 0 { 0 } else { (t_idx * N_VALUES + value_idx) as u8 };
            g.push(glyph); c.push(colour);
        }
    };

    // --- hysteresis to a fixed point (§4.4) --------------------------------
    let mut state: Vec<u8> = l_frames[0].iter()
        .map(|&l| ramp.ideal_index(tone_curve(l, black, white, gamma) * ramp.peak)).collect();
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

pub fn write_cells(path: &Path, d: &Derived, ramp: &Ramp, palette: &[[u8; 3]]) -> Result<(), String> {
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
    let body = zstd::encode_all(&payload[..], 19).map_err(|e| e.to_string())?;

    let mut out = header;
    out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
    out.extend_from_slice(&body);
    // Written whole, then renamed by the caller: a reader that opens a
    // half-written cells file sees a truncated animation rather than an error.
    std::fs::write(path, &out).map_err(|e| format!("{}: {e}", path.display()))
}
