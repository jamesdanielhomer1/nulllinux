//! Reader for the quantised animation format (NULL.md §5.2).

use std::fs::File;
use std::io::{BufReader, Read};

const MAGIC: &[u8; 4] = b"RCEL";
const VERSION: u16 = 1;

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

fn rd<const N: usize>(r: &mut impl Read) -> std::io::Result<[u8; N]> {
    let mut b = [0u8; N];
    r.read_exact(&mut b)?;
    Ok(b)
}

impl Cells {
    pub fn load(path: &str) -> Result<Self, String> {
        let f = File::open(path).map_err(|e| format!("{path}: {e}"))?;
        let mut r = BufReader::new(f);

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

        let rl = rd::<1>(&mut r).map_err(|e| e.to_string())?[0] as usize;
        let mut rb = vec![0u8; rl];
        r.read_exact(&mut rb).map_err(|e| e.to_string())?;
        let ramp: Vec<char> = rb.iter().map(|&b| b as char).collect();

        // 256 does not fit in a byte -- this field is 16-bit by design (§5.2).
        let pl = u16::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?) as usize;
        let mut pbuf = vec![0u8; pl * 3];
        r.read_exact(&mut pbuf).map_err(|e| e.to_string())?;
        let palette: Vec<[u8; 3]> = pbuf.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect();

        let raw_len = u64::from_le_bytes(rd(&mut r).map_err(|e| e.to_string())?) as usize;
        let mut comp = Vec::new();
        r.read_to_end(&mut comp).map_err(|e| e.to_string())?;
        let planes = zstd::decode_all(&comp[..]).map_err(|e| format!("{path}: {e}"))?;
        if planes.len() != raw_len {
            return Err(format!(
                "{path}: payload is {} bytes, header says {raw_len}", planes.len()
            ));
        }
        let want = cols as usize * rows as usize * 2 * frames as usize;
        if planes.len() != want {
            return Err(format!("{path}: payload {} bytes, geometry needs {want}", planes.len()));
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
