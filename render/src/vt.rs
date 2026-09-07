//! A terminal emulator, sized to what the hosted programs were MEASURED to
//! emit (NULL.md §7.3, §10.5).
//!
//! The only defensible reason to write one is knowing exactly how small it can
//! be. The subset below is that measurement: every escape form observed from
//! fzf and btop on a pseudo-terminal of the size the column gives them.
//!
//!   fzf   CSI A B G K h l m n p          9 distinct forms, 0 scroll ops
//!   btop  CSI A B C D f h l m            8 distinct forms, 0 scroll ops
//!
//! Two properties matter more than coverage:
//!
//! * What it does not implement, it SKIPS WHOLE. The state machine consumes an
//!   unrecognised sequence rather than printing its bytes. That single property
//!   is what keeps a surprise from becoming confetti on screen.
//!
//! * The scrolling machinery is implemented anyway, though nothing measured
//!   needs it. A terminal that silently mishandles a line feed at the bottom of
//!   a region will one day be handed a program that uses one.

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Attrs {
    pub fg: Option<[u8; 3]>,
    pub bg: Option<[u8; 3]>,
    pub bold: bool,
}

impl Default for Attrs {
    fn default() -> Self { Attrs { fg: None, bg: None, bold: false } }
}

#[derive(Clone, Copy, PartialEq)]
pub struct VtCell {
    pub ch: char,
    pub attrs: Attrs,
}

impl Default for VtCell {
    fn default() -> Self { VtCell { ch: ' ', attrs: Attrs::default() } }
}

#[derive(PartialEq)]
enum State {
    Ground,
    Esc,
    Csi,
    /// Consuming a sequence we do not implement, to its terminator. This is
    /// the "skip whole" property.
    OscString,
    /// The single byte after a charset designator such as `ESC ( B`.
    ///
    /// This state exists because its absence was VISIBLE: the escape handler's
    /// default arm consumed only the `(`, so the `B` fell through and was
    /// PRINTED. ncurses emits `ESC ( B` constantly, so a hosted program's
    /// output came out sprayed with stray capital Bs and its columns pushed
    /// out of line. "Skip whole" has to mean the whole sequence.
    CharsetDesignate,
}

pub struct Vt {
    pub cols: usize,
    pub rows: usize,
    grid: Vec<VtCell>,
    alt: Option<Vec<VtCell>>,
    cx: usize,
    cy: usize,
    saved: (usize, usize),
    attrs: Attrs,
    state: State,
    params: Vec<u32>,
    param_acc: Option<u32>,
    private: Option<u8>,
    intermediates: Vec<u8>,
    utf8: Vec<u8>,
    utf8_need: usize,
    /// fzf turns autowrap OFF so it can write the last column safely.
    autowrap: bool,
    /// Deferred wrap: the cursor sits past the last column until the next
    /// printable arrives. Wrapping eagerly puts a character on the wrong row.
    pending_wrap: bool,
    pub cursor_visible: bool,
    scroll_top: usize,
    scroll_bot: usize,
    pub dirty: bool,
}

/// The 16 ANSI colours a hosted program will be given.
///
/// Set once, by whoever owns a palette, before anything is hosted. Until then
/// the standard VGA ramp stands, so a terminal used without a palette still
/// draws something sane.
///
/// This exists because the note that used to sit inside `idx256` said "the
/// surface remaps them" and NOTHING EVER DID. Every 16-colour program hosted
/// in the column -- and the whole point of hosting is programs like nmtui that
/// have only those 16 -- drew in stock VGA blue and magenta inside a desktop
/// whose every other colour is sampled from a black hole. The comment
/// described an intention and read like a description of the code.
static ANSI16: std::sync::OnceLock<[[u8; 3]; 16]> = std::sync::OnceLock::new();

/// Give hosted programs this palette's sixteen. Only the first call counts.
pub fn set_ansi16(table: [[u8; 3]; 16]) { let _ = ANSI16.set(table); }

fn idx256(n: u32) -> [u8; 3] {
    let n = n as u8;
    match n {
        0..=15 => {
            const B: [[u8; 3]; 16] = [
                [0,0,0],[170,0,0],[0,170,0],[170,85,0],[0,0,170],[170,0,170],[0,170,170],[170,170,170],
                [85,85,85],[255,85,85],[85,255,85],[255,255,85],[85,85,255],[255,85,255],[85,255,255],[255,255,255]];
            ANSI16.get().unwrap_or(&B)[n as usize]
        }
        16..=231 => {
            let c = n - 16;
            let (r, g, b) = (c / 36, (c % 36) / 6, c % 6);
            let f = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
            [f(r), f(g), f(b)]
        }
        _ => { let v = 8 + (n - 232) * 10; [v, v, v] }
    }
}

impl Vt {
    pub fn new(cols: usize, rows: usize) -> Self {
        Vt {
            cols, rows,
            grid: vec![VtCell::default(); cols * rows],
            alt: None,
            cx: 0, cy: 0, saved: (0, 0),
            attrs: Attrs::default(),
            state: State::Ground,
            params: Vec::new(), param_acc: None, private: None,
            intermediates: Vec::new(),
            utf8: Vec::new(), utf8_need: 0,
            autowrap: true, pending_wrap: false,
            cursor_visible: true,
            scroll_top: 0, scroll_bot: rows.saturating_sub(1),
            dirty: true,
        }
    }

    pub fn cell(&self, x: usize, y: usize) -> VtCell {
        if x >= self.cols || y >= self.rows { return VtCell::default() }
        self.grid[y * self.cols + x]
    }

    pub fn cursor(&self) -> (usize, usize) { (self.cx, self.cy) }

    /// Resize by CLIPPING, not reflowing.
    ///
    /// Every program measured repaints from scratch on a resize signal, so the
    /// host's entire duty is to resize the grid and let the kernel raise the
    /// signal. That is a decision, not a shortcut (§10.5).
    pub fn resize(&mut self, cols: usize, rows: usize) {
        if cols == self.cols && rows == self.rows { return }
        let mut g = vec![VtCell::default(); cols * rows];
        for y in 0..rows.min(self.rows) {
            for x in 0..cols.min(self.cols) {
                g[y * cols + x] = self.grid[y * self.cols + x];
            }
        }
        self.grid = g;
        self.cols = cols;
        self.rows = rows;
        self.cx = self.cx.min(cols.saturating_sub(1));
        self.cy = self.cy.min(rows.saturating_sub(1));
        self.scroll_top = 0;
        self.scroll_bot = rows.saturating_sub(1);
        self.alt = None;
        self.dirty = true;
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for &b in bytes { self.byte(b) }
    }

    fn byte(&mut self, b: u8) {
        match self.state {
            State::Ground => self.ground(b),
            State::Esc => self.esc(b),
            State::CharsetDesignate => self.state = State::Ground,
            State::Csi => self.csi(b),
            State::OscString => {
                // Consume to BEL or ST. Skipping whole is what stops an
                // unknown sequence becoming confetti.
                if b == 0x07 { self.state = State::Ground }
                else if b == 0x5c && self.intermediates.last() == Some(&0x1b) {
                    self.state = State::Ground;
                }
                self.intermediates.clear();
                if b == 0x1b { self.intermediates.push(b) }
            }
        }
    }

    fn ground(&mut self, b: u8) {
        if self.utf8_need > 0 {
            self.utf8.push(b);
            self.utf8_need -= 1;
            if self.utf8_need == 0 {
                let s = String::from_utf8_lossy(&self.utf8).into_owned();
                self.utf8.clear();
                for ch in s.chars() { self.put(ch) }
            }
            return;
        }
        match b {
            0x1b => { self.state = State::Esc; self.intermediates.clear() }
            0x0d => { self.cx = 0; self.pending_wrap = false; self.dirty = true }  // CR: the only C0 fzf emits, hundreds of times a screen
            0x0a => { self.line_feed(); }
            0x08 => { if self.cx > 0 { self.cx -= 1 } self.pending_wrap = false }
            0x09 => { self.cx = ((self.cx / 8) + 1) * 8; if self.cx >= self.cols { self.cx = self.cols - 1 } }
            0x07 => {}
            0x00..=0x1f => {}
            0x20..=0x7f => self.put(b as char),
            0xc0..=0xdf => { self.utf8.clear(); self.utf8.push(b); self.utf8_need = 1 }
            0xe0..=0xef => { self.utf8.clear(); self.utf8.push(b); self.utf8_need = 2 }
            0xf0..=0xf7 => { self.utf8.clear(); self.utf8.push(b); self.utf8_need = 3 }
            _ => {}
        }
    }

    fn put(&mut self, ch: char) {
        if self.pending_wrap && self.autowrap {
            self.cx = 0;
            self.line_feed();
            self.pending_wrap = false;
        }
        if self.cy < self.rows && self.cx < self.cols {
            let i = self.cy * self.cols + self.cx;
            let c = VtCell { ch, attrs: self.attrs };
            if self.grid[i] != c { self.grid[i] = c; self.dirty = true }
        }
        if self.cx + 1 >= self.cols {
            // Deferred: the cursor stays put until the next printable, so a
            // program writing the last column does not scroll the screen.
            self.pending_wrap = true;
        } else {
            self.cx += 1;
        }
    }

    fn line_feed(&mut self) {
        self.pending_wrap = false;
        if self.cy == self.scroll_bot { self.scroll_up(1) } else if self.cy + 1 < self.rows { self.cy += 1 }
        self.dirty = true;
    }

    fn scroll_up(&mut self, n: usize) {
        for _ in 0..n {
            for y in self.scroll_top..self.scroll_bot {
                for x in 0..self.cols {
                    self.grid[y * self.cols + x] = self.grid[(y + 1) * self.cols + x];
                }
            }
            for x in 0..self.cols {
                self.grid[self.scroll_bot * self.cols + x] = VtCell::default();
            }
        }
        self.dirty = true;
    }

    fn esc(&mut self, b: u8) {
        match b {
            b'[' => { self.state = State::Csi; self.params.clear(); self.param_acc = None;
                      self.private = None; self.intermediates.clear() }
            b']' => { self.state = State::OscString; self.intermediates.clear() }
            b'7' => { self.saved = (self.cx, self.cy); self.state = State::Ground }
            b'8' => { let (x, y) = self.saved; self.cx = x; self.cy = y; self.state = State::Ground }
            b'M' => { if self.cy == self.scroll_top { /* reverse index */ } else if self.cy > 0 { self.cy -= 1 }
                      self.state = State::Ground }
            b'D' => { self.line_feed(); self.state = State::Ground }
            // Charset designation: `ESC ( B`, `ESC ) 0` and friends. The
            // designator is one byte and the SET is the byte after it, which
            // must be swallowed too -- it is not text.
            b'(' | b')' | b'*' | b'+' | b'-' | b'.' | b'/' => {
                self.state = State::CharsetDesignate
            }
            _ => { self.state = State::Ground }        // skip whole
        }
    }

    fn csi(&mut self, b: u8) {
        match b {
            b'0'..=b'9' => {
                let v = self.param_acc.unwrap_or(0).saturating_mul(10) + (b - b'0') as u32;
                self.param_acc = Some(v.min(65535));
                return;
            }
            // Capped: a program emitting an endless run of ';' or intermediate
            // bytes stays in this state, and an uncapped push would grow without
            // bound on untrusted output. 32 params covers every real sequence.
            b';' => { let v = self.param_acc.take().unwrap_or(0);
                      if self.params.len() < 32 { self.params.push(v) } return }
            b'?' | b'<' | b'=' | b'>' => { self.private = Some(b); return }
            0x20..=0x2f => { if self.intermediates.len() < 8 { self.intermediates.push(b) } return }
            _ => {}
        }
        if let Some(v) = self.param_acc.take() { if self.params.len() < 32 { self.params.push(v) } }
        let p = |i: usize, d: u32| *self.params.get(i).unwrap_or(&0) as u32 * 0 + self.params.get(i).copied().filter(|v| *v != 0).unwrap_or(d);
        let p0 = p(0, 1) as usize;

        match (self.private, b) {
            // Private modes. Real behaviour for exactly three; the mouse and
            // bracketed-paste modes are accepted and ignored, which is what
            // "skip whole" means for something we understand but do not need.
            (Some(b'?'), b'h') | (Some(b'?'), b'l') => {
                let set = b == b'h';
                for &m in self.params.iter() {
                    match m {
                        1049 => {
                            if set {
                                if self.alt.is_none() {
                                    self.alt = Some(self.grid.clone());
                                    self.grid = vec![VtCell::default(); self.cols * self.rows];
                                    self.cx = 0; self.cy = 0;
                                }
                            } else if let Some(g) = self.alt.take() {
                                self.grid = g;
                            }
                            self.dirty = true;
                        }
                        25 => self.cursor_visible = set,
                        7 => self.autowrap = set,
                        _ => {}     // mouse, bracketed paste: accepted, ignored
                    }
                }
            }
            (_, b'A') => { self.cy = self.cy.saturating_sub(p0); self.pending_wrap = false }
            (_, b'B') => { self.cy = (self.cy + p0).min(self.rows.saturating_sub(1)); self.pending_wrap = false }
            (_, b'C') => { self.cx = (self.cx + p0).min(self.cols.saturating_sub(1)); self.pending_wrap = false }
            (_, b'D') => { self.cx = self.cx.saturating_sub(p0); self.pending_wrap = false }
            (_, b'G') => { self.cx = (p0 - 1).min(self.cols.saturating_sub(1)); self.pending_wrap = false }
            // H and f are the SAME function. btop emits only f, never H, and
            // treating them differently breaks it completely (§10.5).
            (_, b'H') | (_, b'f') => {
                self.cy = (p(0, 1) as usize - 1).min(self.rows.saturating_sub(1));
                self.cx = (p(1, 1) as usize - 1).min(self.cols.saturating_sub(1));
                self.pending_wrap = false;
            }
            (_, b'J') => {
                let mode = self.params.first().copied().unwrap_or(0);
                let (from, to) = match mode {
                    0 => (self.cy * self.cols + self.cx, self.grid.len()),
                    1 => (0, self.cy * self.cols + self.cx + 1),
                    _ => (0, self.grid.len()),
                };
                for i in from..to.min(self.grid.len()) { self.grid[i] = VtCell::default() }
                self.dirty = true;
            }
            (_, b'K') => {
                let mode = self.params.first().copied().unwrap_or(0);
                let row = self.cy * self.cols;
                let (from, to) = match mode {
                    0 => (row + self.cx, row + self.cols),
                    1 => (row, row + self.cx + 1),
                    _ => (row, row + self.cols),
                };
                for i in from..to.min(self.grid.len()) { self.grid[i] = VtCell::default() }
                self.dirty = true;
            }
            (_, b'm') => self.sgr(),
            (_, b'r') => {
                self.scroll_top = (p(0, 1) as usize - 1).min(self.rows.saturating_sub(1));
                self.scroll_bot = (p(1, self.rows as u32) as usize - 1).min(self.rows.saturating_sub(1));
            }
            (_, b'S') => { let n = p0; self.scroll_up(n) }
            _ => {}                                   // skip whole
        }
        self.state = State::Ground;
    }

    fn sgr(&mut self) {
        if self.params.is_empty() { self.params.push(0) }
        let mut i = 0;
        while i < self.params.len() {
            match self.params[i] {
                0 => self.attrs = Attrs::default(),
                1 => self.attrs.bold = true,
                // 22 is bold-off WITHOUT resetting colour. btop emits it over a
                // thousand times a screen, and collapsing it into 0 turns the
                // whole display the wrong colour (§10.5).
                22 => self.attrs.bold = false,
                39 => self.attrs.fg = None,
                49 => self.attrs.bg = None,
                30..=37 => self.attrs.fg = Some(idx256(self.params[i] - 30)),
                40..=47 => self.attrs.bg = Some(idx256(self.params[i] - 40)),
                90..=97 => self.attrs.fg = Some(idx256(self.params[i] - 90 + 8)),
                100..=107 => self.attrs.bg = Some(idx256(self.params[i] - 100 + 8)),
                38 | 48 => {
                    let fg = self.params[i] == 38;
                    match self.params.get(i + 1) {
                        Some(5) => {
                            if let Some(&n) = self.params.get(i + 2) {
                                let c = idx256(n);
                                if fg { self.attrs.fg = Some(c) } else { self.attrs.bg = Some(c) }
                            }
                            i += 2;
                        }
                        Some(2) => {
                            let r = self.params.get(i + 2).copied().unwrap_or(0) as u8;
                            let g = self.params.get(i + 3).copied().unwrap_or(0) as u8;
                            let b = self.params.get(i + 4).copied().unwrap_or(0) as u8;
                            if fg { self.attrs.fg = Some([r, g, b]) } else { self.attrs.bg = Some([r, g, b]) }
                            i += 4;
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
            i += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(v: &Vt, y: usize) -> String {
        (0..v.cols).map(|x| v.cell(x, y).ch).collect::<String>().trim_end().to_string()
    }

    #[test]
    fn writes_and_wraps_only_when_the_next_character_arrives() {
        // Deferred wrap. Wrapping eagerly at the last column puts the NEXT
        // character on the wrong row, and scrolls a screen that should not.
        let mut v = Vt::new(4, 3);
        v.feed(b"abcd");
        assert_eq!(line(&v, 0), "abcd");
        assert_eq!(v.cursor(), (3, 0), "cursor stays on the last column");
        v.feed(b"e");
        assert_eq!(line(&v, 1), "e");
    }

    #[test]
    fn autowrap_off_lets_a_program_write_the_last_column() {
        // fzf turns autowrap OFF precisely so it can write the last column
        // without the screen scrolling under it.
        //
        // With DECAWM off the cursor STOPS at the right margin and each further
        // character overwrites what is there -- so "abcdef" in four columns
        // ends "abcf", not "abcd". The first version of this test asserted
        // "abcd" and was simply wrong about the terminal; the behaviour it was
        // testing is the one that matters, which is that nothing wraps.
        let mut v = Vt::new(4, 2);
        v.feed(b"\x1b[?7l");
        v.feed(b"abcdef");
        assert_eq!(line(&v, 0), "abcf", "last column overwritten, not wrapped");
        assert_eq!(line(&v, 1), "", "nothing wrapped to the next row");
    }

    #[test]
    fn hvp_and_cup_are_the_same_function() {
        // btop emits ONLY f, never H. Treating f as anything else breaks it
        // completely -- 2555 uses on one screen.
        let mut a = Vt::new(10, 5);
        let mut b = Vt::new(10, 5);
        a.feed(b"\x1b[3;5HX");
        b.feed(b"\x1b[3;5fX");
        assert_eq!(a.cursor(), b.cursor());
        assert_eq!(line(&a, 2), line(&b, 2));
        assert_eq!(line(&a, 2), "    X");
    }

    #[test]
    fn sgr_22_clears_bold_without_touching_colour() {
        // btop emits SGR 22 over a thousand times a screen. Collapsing it into
        // 0 turns the whole display the wrong colour.
        let mut v = Vt::new(4, 1);
        v.feed(b"\x1b[38;2;10;20;30m\x1b[1mA\x1b[22mB");
        assert_eq!(v.cell(0, 0).attrs.bold, true);
        assert_eq!(v.cell(1, 0).attrs.bold, false);
        assert_eq!(v.cell(1, 0).attrs.fg, Some([10, 20, 30]), "colour survived");
    }

    #[test]
    fn unknown_sequences_are_skipped_whole_not_printed() {
        // The single property that keeps a surprise from becoming confetti.
        let mut v = Vt::new(12, 1);
        v.feed(b"A\x1b[>4;2mB\x1b]0;a title\x07C");
        assert_eq!(line(&v, 0), "ABC");
    }

    #[test]
    fn charset_designation_is_swallowed_whole() {
        // ncurses emits ESC ( B constantly. The escape handler used to consume
        // only the '(', so the 'B' was printed -- hosted programs came out
        // sprayed with stray capital Bs and their columns pushed out of line.
        let mut v = Vt::new(20, 2);
        v.feed(b"\x1b(Bhello");
        assert_eq!(line(&v, 0), "hello", "the charset byte must not be printed");

        let mut v = Vt::new(20, 2);
        v.feed(b"\x1b)0\x1b*B\x1b+Bok");
        assert_eq!(line(&v, 0), "ok", "every designator form is swallowed whole");
    }

    #[test]
    fn alternate_screen_restores_what_was_under_it() {
        let mut v = Vt::new(6, 2);
        v.feed(b"under");
        v.feed(b"\x1b[?1049h");
        assert_eq!(line(&v, 0), "", "alt screen starts blank");
        v.feed(b"over");
        v.feed(b"\x1b[?1049l");
        assert_eq!(line(&v, 0), "under");
    }

    #[test]
    fn line_feed_at_the_bottom_scrolls() {
        // Nothing measured needs this. It is implemented anyway, because a
        // terminal that silently mishandles it will one day be handed a
        // program that uses one.
        let mut v = Vt::new(4, 2);
        v.feed(b"a\r\nb\r\nc");
        assert_eq!(line(&v, 0), "b");
        assert_eq!(line(&v, 1), "c");
    }

    #[test]
    fn a_one_row_terminal_does_not_panic() {
        // A degenerate size took the whole surface down in a previous build.
        let mut v = Vt::new(4, 1);
        v.feed(b"abc\r\ndef\r\n\x1b[2J\x1b[5;5H\x1b[K");
        assert_eq!(v.rows, 1);
    }

    #[test]
    fn resize_clips_rather_than_reflowing() {
        let mut v = Vt::new(10, 3);
        v.feed(b"abcdefghij");
        v.resize(5, 3);
        assert_eq!(line(&v, 0), "abcde");
    }

    #[test]
    fn a_pathological_csi_does_not_grow_without_bound() {
        // A hosted program emitting an endless run of ';' stays in the CSI state.
        // Without a cap, params grows one entry per ';' -- unbounded memory off
        // untrusted output. Feed a long run and require the terminator still lands
        // in Ground with the grid intact and params bounded.
        let mut v = Vt::new(6, 1);
        let mut junk = vec![0x1b, b'['];
        junk.extend(std::iter::repeat(b';').take(100_000));
        junk.extend_from_slice(b"m");          // a valid SGR terminator
        v.feed(&junk);
        v.feed(b"ok");
        assert_eq!(line(&v, 0), "ok", "recovers to Ground and keeps drawing");
    }

    #[test]
    fn erase_in_line_respects_its_mode() {
        let mut v = Vt::new(6, 1);
        v.feed(b"abcdef\x1b[1G\x1b[2C\x1b[K");
        assert_eq!(line(&v, 0), "ab");
    }
}
