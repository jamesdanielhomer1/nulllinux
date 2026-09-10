//! Reader for the quantised animation format (NULL.md §5.2).

use std::fs::File;
use std::io::{BufReader, Read};

const MAGIC: &[u8; 4] = b"RCEL";
const VERSION: u16 = 1;
// Enough for large multi-frame displays, but never an unbounded decoder allocation.
const MAX_PAYLOAD: usize = 512 * 1024 * 1024;

pub struct Cells {
    pub cols: u16,
    pub rows: u16,
    pub frames: u16,
    pub fps: u16,
    pub ramp: Vec<char>,
    pub palette: Vec<[u8; 3]>,
    /// Per frame: glyph plane then colour plane, each cols*rows bytes.
    planes: Vec<u8>,
}

#[cfg(test)]
mod validation_tests {
    use super::*;

    fn encoded(cols: u16, rows: u16, frames: u16, fps: u16, palette_len: u16,
               raw_len: u64, raw: &[u8]) -> Vec<u8> {
        let mut d = MAGIC.to_vec();
        for v in [VERSION, cols, rows, frames, fps] { d.extend_from_slice(&v.to_le_bytes()); }
        d.extend_from_slice(&[1, b'#']);
        d.extend_from_slice(&palette_len.to_le_bytes());
        d.extend(vec![0; palette_len as usize * 3]);
        d.extend_from_slice(&raw_len.to_le_bytes());
        d.extend(zstd::encode_all(raw, 1).unwrap());
        d
    }

    #[test]
    fn zero_geometry_timing_and_empty_palette_are_rejected() {
        for (c, r, f, fps, p) in [(0,1,1,12,1), (1,0,1,12,1), (1,1,0,12,1),
                                  (1,1,1,0,1), (1,1,1,12,0), (1,1,1,12,257)] {
            let data = encoded(c, r, f, fps, p, 2, &[0,0]);
            assert!(Cells::read(&data[..], "test").is_err());
        }
    }

    #[test]
    fn palette_and_glyph_indices_are_validated() {
        for raw in [[0,255], [1,0]] {
            let data = encoded(1,1,1,12,1,2,&raw);
            assert!(Cells::read(&data[..], "test").is_err());
        }
        let data = encoded(1,1,1,12,1,2,&[0,0]);
        assert_eq!(Cells::read(&data[..], "test").unwrap().glyphs(0), &[0]);
    }

    #[test]
    fn decoder_rejects_excess_output_and_absurd_headers() {
        for data in [encoded(1,1,1,12,1,2,&[0;1024]),
                     encoded(1,1,1,12,1,u64::MAX,&[]),
                     encoded(u16::MAX,u16::MAX,u16::MAX,12,1,0,&[])] {
            assert!(Cells::read(&data[..], "test").is_err());
        }
    }
}

fn rd<const N: usize>(r: &mut impl Read) -> std::io::Result<[u8; N]> {
    let mut b = [0u8; N];
    r.read_exact(&mut b)?;
    Ok(b)
}

impl Cells {
    pub fn load(path: &str) -> Result<Self, String> {
        let f = File::open(path).map_err(|e| format!("{path}: {e}"))?;
        Self::read(BufReader::new(f), path)
    }

    fn read(mut r: impl Read, path: &str) -> Result<Self, String> {

        let magic: [u8; 4] = rd(&mut r).map_err(|e| e.to_string())?;
        if &magic != MAGIC {
            return Err(format!("{path}: not a quantised cell file"));
        }
        let version = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?);
        if version != VERSION {
            return Err(format!("{path}: version {version}, expected {VERSION}"));
        }
        let cols = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?);
        let rows = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?);
        let frames = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?);
        let fps = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?);
        if cols == 0 || rows == 0 || frames == 0 || fps == 0 {
            return Err(format!("{path}: dimensions, frame count and fps must be positive"));
        }

        let rl = rd::<1>(&mut r).map_err(|e| e.to_string())?[0] as usize;
        if rl == 0 { return Err(format!("{path}: empty glyph ramp")); }
        let mut rb = vec![0u8; rl];
        r.read_exact(&mut rb).map_err(|e| e.to_string())?;
        let ramp: Vec<char> = rb.iter().map(|&b| b as char).collect();

        // 256 does not fit in a byte -- this field is 16-bit by design (§5.2).
        let pl = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?) as usize;
        if pl == 0 || pl > 256 { return Err(format!("{path}: palette must contain 1..=256 entries")); }
        let mut pbuf = vec![0u8; pl * 3];
        r.read_exact(&mut pbuf).map_err(|e| e.to_string())?;
        let palette: Vec<[u8; 3]> = pbuf.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect();

        let raw_len = u64::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?);
        let want = (cols as usize).checked_mul(rows as usize)
            .and_then(|n| n.checked_mul(2)).and_then(|n| n.checked_mul(frames as usize))
            .filter(|&n| n <= MAX_PAYLOAD)
            .ok_or_else(|| format!("{path}: cell payload exceeds {MAX_PAYLOAD} bytes"))?;
        if raw_len != want as u64 {
            return Err(format!("{path}: header payload {raw_len} bytes, geometry needs {want}"));
        }
        let decoder = zstd::stream::read::Decoder::new(r).map_err(|e| format!("{path}: {e}"))?;
        let mut planes = Vec::new();
        decoder.take(raw_len + 1).read_to_end(&mut planes).map_err(|e| format!("{path}: {e}"))?;
        if planes.len() as u64 != raw_len {
            return Err(format!(
                "{path}: payload is {} bytes, header says {raw_len}", planes.len()
            ));
        }
        let n = cols as usize * rows as usize;
        for frame in planes.chunks_exact(n * 2) {
            if frame[..n].iter().any(|&i| i as usize >= rl)
                || frame[n..].iter().any(|&i| i as usize >= pl) {
                return Err(format!("{path}: glyph or palette index out of range"));
            }
        }

        Ok(Cells { cols, rows, frames, fps, ramp, palette, planes })
    }

    #[inline]
    pub fn cell_count(&self) -> usize { self.cols as usize * self.rows as usize }

    #[inline]
    /// Test-only: build an in-memory Cells without a file. planes is, per
    /// frame, cols*rows glyph bytes then cols*rows colour bytes -- the same
    /// layout glyphs()/colours() index below.
    #[cfg(test)]
    pub(crate) fn synthetic(cols: u16, rows: u16, frames: u16,
                            ramp: Vec<char>, palette: Vec<[u8; 3]>, planes: Vec<u8>) -> Self {
        Cells { cols, rows, frames, fps: 12, ramp, palette, planes }
    }

    pub fn glyphs(&self, frame: usize) -> &[u8] {
        let n = self.cell_count();
        let off = frame * n * 2;
        &self.planes[off..off + n]
    }

    #[inline]
    pub fn colours(&self, frame: usize) -> &[u8] {
        let n = self.cell_count();
        let off = frame * n * 2 + n;
        &self.planes[off..off + n]
    }

    /// Which frame the loop is on, from a monotonic clock.
    ///
    /// Phase comes from the clock rather than a per-surface accumulator, so
    /// every surface playing this asset agrees on which frame it is -- a
    /// surface that counts its own frames drifts from one that dropped some.
    pub fn frame_at(&self, elapsed: std::time::Duration) -> usize {
        let period = self.frames as f64 / self.fps as f64;
        let t = elapsed.as_secs_f64() % period;
        ((t * self.fps as f64) as usize).min(self.frames as usize - 1)
    }
}
