//! A pseudo-terminal for the column (NULL.md §7.3).
//!
//! No new dependency and no fork of our own: the pty is opened, the slave is
//! handed to `Command` as all three standard streams, and the controlling
//! terminal is taken in one `pre_exec` closure. Forking and then doing
//! anything non-trivial before the exec is only safe if you are certain of
//! every allocation in between, and `Command` already gets that right.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

pub struct Pty {
    master: OwnedFd,
    pub child: Child,
}

fn cvt(r: libc::c_int) -> io::Result<libc::c_int> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

fn set_winsize(fd: RawFd, cols: u16, rows: u16) -> io::Result<()> {
    let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    cvt(unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) }).map(|_| ())
}

impl Pty {
    /// Spawn `argv` on a new pty of exactly (cols, rows).
    pub fn spawn(argv: &[String], cols: u16, rows: u16, env: &[(String, String)])
        -> io::Result<Pty>
    {
        // O_CLOEXEC on the master is the easy half: a child holding it open
        // would never let us see our own hangup.
        let master_raw = cvt(unsafe {
            libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC)
        })?;
        let master = unsafe { OwnedFd::from_raw_fd(master_raw) };
        cvt(unsafe { libc::grantpt(master_raw) })?;
        cvt(unsafe { libc::unlockpt(master_raw) })?;

        let mut name = [0i8; 128];
        cvt(unsafe { libc::ptsname_r(master_raw, name.as_mut_ptr(), name.len()) })?;
        let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }.to_owned();

        // O_CLOEXEC on the SLAVE is the subtle half, and the one that bites.
        // Every other process this program spawns inherits an inheritable
        // slave, so an unrelated long-lived child holds the column's terminal
        // open: the hosted program exits, the master never reports end-of-file,
        // and the column keeps a finished menu on screen for ever, waiting for
        // a hangup that something three seconds older is preventing.
        let slave_raw = cvt(unsafe {
            libc::open(path.as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC)
        })?;
        let slave = unsafe { OwnedFd::from_raw_fd(slave_raw) };

        set_winsize(master_raw, cols, rows)?;

        // Three copies for the three standard streams. F_DUPFD_CLOEXEC rather
        // than dup() then fcntl(): the two-call form leaves a window in which
        // the copy exists WITHOUT the flag for a concurrent fork to inherit
        // through, and this program spawns other processes.
        let dup_cloexec = |fd: RawFd| -> io::Result<OwnedFd> {
            let n = cvt(unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) })?;
            Ok(unsafe { OwnedFd::from_raw_fd(n) })
        };
        let (i, o, e) = (dup_cloexec(slave_raw)?, dup_cloexec(slave_raw)?, dup_cloexec(slave_raw)?);

        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..])
            .stdin(Stdio::from(i))
            .stdout(Stdio::from(o))
            .stderr(Stdio::from(e))
            .env("TERM", "xterm-256color")
            .env("COLORTERM", "truecolor")
            .env("LINES", rows.to_string())
            .env("COLUMNS", cols.to_string());
        for (k, v) in env { cmd.env(k, v); }

        unsafe {
            cmd.pre_exec(move || {
                // Not optional, and skipping it fails in three ways that look
                // like three different bugs: the resize signal is never
                // delivered so resizing does nothing, interrupt is never
                // delivered, and closing the master does not hang the child up
                // -- so quitting a menu leaves the program running for ever
                // with nowhere to draw.
                if libc::setsid() < 0 { return Err(io::Error::last_os_error()) }
                if libc::ioctl(0, libc::TIOCSCTTY, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let child = cmd.spawn()?;
        drop(slave);       // the child has its own copies; ours must go, or
                           // the master never sees a hangup
        Ok(Pty { master, child })
    }

    pub fn fd(&self) -> RawFd { self.master.as_raw_fd() }

    pub fn resize(&self, cols: u16, rows: u16) -> io::Result<()> {
        set_winsize(self.master.as_raw_fd(), cols, rows)
    }

    /// Read what the program has emitted. Ok(0) means it hung up.
    pub fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        let n = unsafe {
            libc::read(self.master.as_raw_fd(), buf.as_mut_ptr() as *mut _, buf.len())
        };
        if n < 0 {
            let e = io::Error::last_os_error();
            // EIO on a pty master is the normal way a hangup arrives.
            if e.raw_os_error() == Some(libc::EIO) { return Ok(0) }
            return Err(e);
        }
        Ok(n as usize)
    }

    pub fn write(&self, buf: &[u8]) -> io::Result<usize> {
        let n = unsafe {
            libc::write(self.master.as_raw_fd(), buf.as_ptr() as *const _, buf.len())
        };
        if n < 0 { return Err(io::Error::last_os_error()) }
        Ok(n as usize)
    }

    pub fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        // Signal a child that has NOT already exited. Signalling one that has
        // is how a previous build came to reap the wrong thing.
        if self.is_alive() {
            unsafe { libc::kill(self.child.id() as i32, libc::SIGHUP) };
            std::thread::sleep(std::time::Duration::from_millis(50));
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn sh(cmd: &str) -> Vec<String> {
        vec!["sh".into(), "-c".into(), cmd.into()]
    }

    #[test]
    fn a_program_runs_and_its_output_arrives() {
        let p = Pty::spawn(&sh("printf hello"), 20, 4, &[]).unwrap();
        let mut buf = [0u8; 256];
        let mut got = String::new();
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            match p.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => got.push_str(&String::from_utf8_lossy(&buf[..n])),
                Err(_) => break,
            }
            if got.contains("hello") { break }
        }
        assert!(got.contains("hello"), "got {got:?}");
    }

    #[test]
    fn the_child_gets_a_controlling_terminal() {
        // Without setsid + TIOCSCTTY the child has no controlling terminal, so
        // `tty` reports "not a tty" -- and the resize signal and interrupt
        // never arrive either.
        let p = Pty::spawn(&sh("tty"), 20, 4, &[]).unwrap();
        let mut buf = [0u8; 256];
        let mut got = String::new();
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            match p.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => got.push_str(&String::from_utf8_lossy(&buf[..n])),
                Err(_) => break,
            }
        }
        assert!(got.contains("/dev/pts/"), "no controlling terminal: {got:?}");
    }

    #[test]
    fn the_size_the_column_asks_for_is_the_size_the_program_sees() {
        let p = Pty::spawn(&sh("stty size"), 57, 21, &[]).unwrap();
        let mut buf = [0u8; 256];
        let mut got = String::new();
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            match p.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => got.push_str(&String::from_utf8_lossy(&buf[..n])),
                Err(_) => break,
            }
        }
        assert!(got.contains("21 57"), "wrong window size: {got:?}");
    }

    #[test]
    fn an_unrelated_child_does_not_hold_the_terminal_open() {
        // THE close-on-exec test.
        //
        // If the pty slave is inheritable, an unrelated long-lived process
        // spawned from here holds the column's terminal open: the hosted
        // program exits, the master never reports end-of-file, and the column
        // keeps a finished menu on screen for ever.
        //
        // In a previous build this surfaced only above three test threads,
        // which is the worst way for it to surface.
        let p = Pty::spawn(&sh("printf done"), 20, 4, &[]).unwrap();

        // An unrelated process, spawned AFTER the pty exists, outliving the
        // hosted program. It inherits our descriptors -- or must not.
        let mut sleeper = Command::new("sleep").arg("10").spawn().unwrap();

        let mut buf = [0u8; 256];
        let start = Instant::now();
        let mut hung_up = false;
        while start.elapsed() < Duration::from_secs(5) {
            match p.read(&mut buf) {
                Ok(0) => { hung_up = true; break }
                Ok(_) => {}
                Err(_) => { hung_up = true; break }
            }
        }
        let _ = sleeper.kill();
        let _ = sleeper.wait();
        assert!(hung_up, "the master never reported end-of-file: an unrelated \
                          process is holding the slave open");
    }
}
