//! The audio spectrum, from cava (NULL.md §7.5, §10.7).
//!
//! §10.7 warns by name that "adding a single audio-spectrum dependency can
//! multiply a status surface's cost several-fold". That is the risk here, and
//! it is answered in two ways rather than hoped about:
//!
//!   * cava runs at a LOW frame rate, not a display rate. An equaliser is read
//!     at a glance, not studied.
//!   * a SILENT frame costs nothing. When every bar is zero and was zero
//!     before, the surface is not marked dirty, so the spectrum costs while
//!     there is sound and nothing at all while there is not -- which is most
//!     of the time.
//!
//! If cava cannot start, or the audio daemon is not there, this reports
//! unavailable and the caller says so. A row of permanently flat bars would
//! look like silence rather than like absence.

use std::os::fd::{AsRawFd, RawFd};
use std::process::{Child, Command, Stdio};

pub struct Spectrum {
    child: Option<Child>,
    fd: RawFd,
    buf: Vec<u8>,
    pub bars: Vec<u8>,
    pub max: u8,
    pub silent: bool,
    pub reason: Option<String>,
}

impl Spectrum {
    /// Levels cava is asked for.
    ///
    /// Matched to what SIX ROWS can actually draw, not to what cava can
    /// produce. Asking for 16 levels when the picture has 6 rows means most
    /// frames differ in a way nobody can see -- and every one of those
    /// differences was a full redraw of the surface. Two sub-steps per row is
    /// enough for the partial-cell density and no more.
    pub const MAX: u8 = 12;

    /// Start cava against a generated configuration.
    ///
    /// The configuration is written by this program rather than shipped: the
    /// bar count has to match the width the column will draw it in, and two
    /// copies of that number would drift.
    pub fn start(bars: usize, framerate: u32, runtime_dir: &str) -> Spectrum {
        let dir = format!("{runtime_dir}/null-cava");
        let _ = std::fs::create_dir_all(&dir);
        let cfg = format!("{dir}/config");
        let source = std::env::var("NULL_CAVA_SOURCE").unwrap_or_default();
        let method = std::env::var("NULL_CAVA_METHOD").unwrap_or_else(|_| "pulse".into());
        let body = format!(
            "[general]\nframerate = {framerate}\nbars = {bars}\nautosens = 1\n\
             [input]\nmethod = {method}\n{}\
             [output]\nmethod = raw\nraw_target = /dev/stdout\ndata_format = ascii\n\
             ascii_max_range = {}\nchannels = mono\n",
            if source.is_empty() { String::new() } else { format!("source = {source}\n") },
            Self::MAX);
        if std::fs::write(&cfg, body).is_err() {
            return Self::unavailable("cannot write the cava configuration");
        }

        match Command::new("cava").arg("-p").arg(&cfg)
            .stdout(Stdio::piped()).stderr(Stdio::null()).stdin(Stdio::null()).spawn()
        {
            Ok(c) => {
                let fd = match c.stdout.as_ref() {
                    Some(o) => o.as_raw_fd(),
                    None => return Self::unavailable("cava produced no output stream"),
                };
                // Non-blocking: this fd is polled alongside the compositor's,
                // and a blocking read here would stall the whole surface.
                unsafe {
                    let f = libc::fcntl(fd, libc::F_GETFL);
                    libc::fcntl(fd, libc::F_SETFL, f | libc::O_NONBLOCK);
                }
                Spectrum { child: Some(c), fd, buf: Vec::new(),
                           bars: vec![0; bars], max: Self::MAX, silent: true, reason: None }
            }
            Err(e) => Self::unavailable(&format!("cava did not start: {e}")),
        }
    }

    fn unavailable(why: &str) -> Spectrum {
        Spectrum { child: None, fd: -1, buf: Vec::new(), bars: Vec::new(),
                   max: Self::MAX, silent: true, reason: Some(why.to_string()) }
    }

    pub fn available(&self) -> bool { self.child.is_some() && self.reason.is_none() }
    pub fn fd(&self) -> RawFd { self.fd }

    /// Drain whatever cava has produced and keep the LATEST frame.
    ///
    /// The latest, not each in turn: if this loop falls behind, the interesting
    /// thing is what the audio is doing now, and replaying a backlog would
    /// draw the past slowly.
    ///
    /// Returns true when the drawn picture should change.
    pub fn poll(&mut self) -> bool {
        if self.child.is_none() { return false }
        let mut chunk = [0u8; 4096];
        loop {
            let n = unsafe {
                libc::read(self.fd, chunk.as_mut_ptr() as *mut libc::c_void, chunk.len())
            };
            if n > 0 { self.buf.extend_from_slice(&chunk[..n as usize]); } else { break }
        }
        if let Some(c) = self.child.as_mut() {
            if matches!(c.try_wait(), Ok(Some(_))) {
                self.child = None;
                self.reason = Some("cava exited -- is an audio daemon running?".into());
                self.bars.clear();
                return true;
            }
        }
        let mut last: Option<Vec<u8>> = None;
        while let Some(nl) = self.buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buf.drain(..=nl).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]);
            let vals: Vec<u8> = text.split(';')
                .filter(|t| !t.trim().is_empty())
                .filter_map(|t| t.trim().parse::<u8>().ok())
                .collect();
            if !vals.is_empty() { last = Some(vals) }
        }
        // A very long line with no newline means this is not cava's raw ascii
        // output; drop it rather than growing without bound.
        if self.buf.len() > 64 * 1024 { self.buf.clear() }

        let Some(vals) = last else { return false };
        let silent = vals.iter().all(|&v| v == 0);
        let changed = vals != self.bars;
        self.bars = vals;
        let was_silent = self.silent;
        self.silent = silent;
        // Silence that was already silence is not a redraw.
        changed && !(silent && was_silent)
    }
}

impl Drop for Spectrum {
    fn drop(&mut self) {
        if let Some(c) = self.child.as_mut() { let _ = c.kill(); let _ = c.wait(); }
    }
}
