//! The screen lock, drawn like the greeter (NULL.md §7.1, §8.5).
//!
//! WHY NOT swaylock. swaylock can only draw a background and its own centred
//! ring -- it cannot show the greeter's animated hero or its bottom pass-panel,
//! so the lock looked nothing like the login it mirrors. This is a small
//! ext-session-lock-v1 client that reuses the hero renderer and draws the
//! greeter's panel minus the user row: one system, whether you are logging in
//! or unlocking.
//!
//! SECURITY. The lock surface and input capture are the compositor's job via
//! ext-session-lock-v1: if this process ever dies the session STAYS locked (the
//! compositor paints a solid colour and waits), so a rendering bug cannot open
//! the screen. Authentication is PAM, fail-CLOSED: only PAM_SUCCESS on BOTH
//! pam_authenticate and pam_acct_mgmt unlocks; every other path rejects.

use std::ffi::{c_char, c_int, c_void, CString};
use std::process::Command;
use std::ptr;
use std::time::Instant;

use nulllinux::atlas::Atlas;
use nulllinux::cells::Cells;
use nulllinux::palette::{Palette, Role};
use nulllinux::raster;

use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_keyboard, delegate_output, delegate_registry,
    delegate_seat, delegate_session_lock, delegate_shm,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers},
        Capability, SeatHandler, SeatState,
    },
    session_lock::{
        SessionLock, SessionLockHandler, SessionLockState, SessionLockSurface,
        SessionLockSurfaceConfigure,
    },
    shm::{slot::SlotPool, Shm, ShmHandler},
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_keyboard, wl_output, wl_seat, wl_surface},
    Connection, QueueHandle,
};

// ---------------------------------------------------------------- PAM --------
//
// The password reaches the PAM conversation callback through appdata_ptr. Only
// PAM_SUCCESS on both authenticate and account management returns true; any
// other outcome, and any allocation or setup failure, returns false. There is
// no path that unlocks without PAM saying yes.
#[repr(C)]
struct PamMessage { msg_style: c_int, msg: *const c_char }
#[repr(C)]
struct PamResponse { resp: *mut c_char, resp_retcode: c_int }
#[repr(C)]
struct PamConv {
    conv: extern "C" fn(c_int, *mut *const PamMessage, *mut *mut PamResponse, *mut c_void) -> c_int,
    appdata_ptr: *mut c_void,
}
#[link(name = "pam")]
extern "C" {
    fn pam_start(service: *const c_char, user: *const c_char, conv: *const PamConv, handle: *mut *mut c_void) -> c_int;
    fn pam_authenticate(handle: *mut c_void, flags: c_int) -> c_int;
    fn pam_acct_mgmt(handle: *mut c_void, flags: c_int) -> c_int;
    fn pam_end(handle: *mut c_void, status: c_int) -> c_int;
}
const PAM_SUCCESS: c_int = 0;
const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_CONV_ERR: c_int = 19;
const PAM_BUF_ERR: c_int = 5;

extern "C" fn pam_conv(n: c_int, msg: *mut *const PamMessage,
                       resp: *mut *mut PamResponse, appdata: *mut c_void) -> c_int {
    if n <= 0 || appdata.is_null() || msg.is_null() || resp.is_null() { return PAM_CONV_ERR }
    let pw = unsafe { &*(appdata as *const CString) };
    let arr = unsafe { libc::calloc(n as usize, std::mem::size_of::<PamResponse>()) as *mut PamResponse };
    if arr.is_null() { return PAM_BUF_ERR }
    for i in 0..n as isize {
        let m = unsafe { &**msg.offset(i) };
        let r = unsafe { &mut *arr.offset(i) };
        r.resp_retcode = 0;
        r.resp = ptr::null_mut();
        if m.msg_style == PAM_PROMPT_ECHO_OFF {
            let bytes = pw.as_bytes_with_nul();
            let p = unsafe { libc::malloc(bytes.len()) as *mut c_char };
            if p.is_null() { return PAM_BUF_ERR }
            unsafe { ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, p, bytes.len()) };
            r.resp = p;
        }
    }
    unsafe { *resp = arr; }
    PAM_SUCCESS
}

fn authenticate(user: &str, password: &str) -> bool {
    let (Ok(cs), Ok(cu), Ok(cp)) =
        (CString::new("null-lock"), CString::new(user), CString::new(password))
        else { return false };
    let conv = PamConv { conv: pam_conv, appdata_ptr: &cp as *const CString as *mut c_void };
    let mut handle: *mut c_void = ptr::null_mut();
    let mut ok = false;
    unsafe {
        if pam_start(cs.as_ptr(), cu.as_ptr(), &conv, &mut handle) == PAM_SUCCESS {
            ok = pam_authenticate(handle, 0) == PAM_SUCCESS
              && pam_acct_mgmt(handle, 0) == PAM_SUCCESS;
            pam_end(handle, if ok { PAM_SUCCESS } else { 1 });
        }
    }
    ok
}

// --------------------------------------------------------------- assets ------
//
// Per output, the same choice the wallpaper makes: shell out to `machine
// choose-assets W H`, which prints the cells and atlas that fit this screen.
// Reused rather than reimplemented (§9.1-ish: one place decides).
fn assets_for(root: &str, w: u32, h: u32) -> Option<(Cells, Atlas)> {
    let out = Command::new(format!("{root}/bin/machine"))
        .args(["choose-assets", &w.to_string(), &h.to_string()])
        .output().ok()?;
    if !out.status.success() { return None }
    let line = String::from_utf8_lossy(&out.stdout);
    let mut it = line.split_whitespace();
    let cells_p = it.next()?;
    let atlas_p = it.next()?;
    let cells = Cells::load(cells_p).ok()?;
    let atlas = Atlas::load(atlas_p).ok()?;
    Some((cells, atlas))
}

// A string drawn straight into a BGRA buffer at a pixel origin, one atlas cell
// per character -- the panel is a handful of short lines, so a full TextGrid is
// more than it needs. Clipped to the buffer; a missing glyph draws the same
// centred dot the hero renderer uses.
#[allow(clippy::too_many_arguments)]
fn text(buf: &mut [u8], stride_px: usize, a: &Atlas, x0: usize, y0: usize,
        s: &str, fg: [u8; 3], bg: [u8; 3]) {
    for (ci, ch) in s.chars().enumerate() {
        let bits = a.glyph(ch as u32).or_else(|| a.glyph('·' as u32));
        let cx0 = x0 + ci * a.cell_w;
        for cy in 0..a.cell_h {
            let row = (y0 + cy) * stride_px;
            for cx in 0..a.cell_w {
                let o = (row + cx0 + cx) * 4;
                if o + 3 >= buf.len() { continue }
                let lit = bits.map_or(false, |b| b[cy * a.cell_w + cx] != 0);
                let p = if lit { fg } else { bg };
                buf[o] = p[2]; buf[o + 1] = p[1]; buf[o + 2] = p[0]; buf[o + 3] = 0xff;
            }
        }
    }
}

#[derive(PartialEq, Clone, Copy)]
enum Auth { Idle, Wrong }

struct Surf {
    output: wl_output::WlOutput,
    lock_surface: SessionLockSurface,
    w: u32,
    h: u32,
    cells: Option<Cells>,
    atlas: Option<Atlas>,
    configured: bool,
    last_frame: Option<usize>,
}

struct Lock {
    registry_state: RegistryState,
    output_state: OutputState,
    compositor_state: CompositorState,
    shm: Shm,
    seat_state: SeatState,
    session_lock_state: SessionLockState,
    session_lock: Option<SessionLock>,
    pool: SlotPool,
    keyboard: Option<wl_keyboard::WlKeyboard>,

    root: String,
    pal: Palette,
    bg: [u8; 3],
    hostname: String,
    user: String,

    surfaces: Vec<Surf>,
    start: Instant,
    password: String,
    auth: Auth,
    exit: bool,
}

impl Lock {
    fn ensure_surface(&mut self, output: wl_output::WlOutput, qh: &QueueHandle<Self>) {
        if self.surfaces.iter().any(|s| s.output == output) { return }
        let Some(lock) = &self.session_lock else { return };
        let surface = self.compositor_state.create_surface(qh);
        let ls = lock.create_lock_surface(surface, &output, qh);
        self.surfaces.push(Surf {
            output, lock_surface: ls, w: 0, h: 0,
            cells: None, atlas: None, configured: false, last_frame: None,
        });
    }

    fn frame_index(&self, cells: &Cells) -> usize {
        if cells.frames == 0 { return 0 }
        let period = cells.frames as f64 / cells.fps.max(1) as f64;
        let t = self.start.elapsed().as_secs_f64() % period;
        ((t * cells.fps as f64) as usize).min(cells.frames as usize - 1)
    }

    fn draw(&mut self, qh: &QueueHandle<Self>, i: usize) {
        let (w, h) = (self.surfaces[i].w, self.surfaces[i].h);
        if w == 0 || h == 0 { return }
        let stride = w as i32 * 4;
        // The frame index needs &self; take it BEFORE the pool is borrowed for
        // the canvas, or the two borrows collide.
        let idx = match &self.surfaces[i].cells { Some(c) => self.frame_index(c), None => 0 };
        let (buffer, canvas) = match self.pool.create_buffer(
            w as i32, h as i32, stride, wayland_client::protocol::wl_shm::Format::Argb8888) {
            Ok(v) => v, Err(_) => return,
        };

        // Ground first: everything the hero and panel do not cover is the
        // palette background, never transparent (§6.3).
        for px in canvas.chunks_exact_mut(4) {
            px[0] = self.bg[2]; px[1] = self.bg[1]; px[2] = self.bg[0]; px[3] = 0xff;
        }

        // The hero, centred, if this surface has assets. A lock with no hero is
        // still a lock -- the ground and the panel are enough.
        // Where the hero ends, so the input box can sit just beneath it. A
        // sensible fallback for a surface with no hero: the middle of the screen.
        if let (Some(cells), Some(atlas)) = (&self.surfaces[i].cells, &self.surfaces[i].atlas) {
            let hero_w = cells.cols as usize * atlas.cell_w;
            let hero_h = cells.rows as usize * atlas.cell_h;
            // Centred and lifted a little, as the greeter draws it, so the input
            // box has clear room directly beneath it.
            let ox = (w as usize).saturating_sub(hero_w) / 2;
            let oy = (h as usize).saturating_sub(hero_h) / 2;
            let oy = oy.saturating_sub(h as usize / 12);
            raster::blit_frame(cells, atlas, idx, canvas, w as usize, self.bg, (ox, oy), None);
        }
        self.surfaces[i].last_frame = Some(idx);

        // The hero grid carries wide empty margins, so its cell height is no
        // guide to where the ART ends. Measure what was actually drawn: the
        // lowest row of the canvas that carries a non-background pixel is the
        // visible bottom of the hero, and the input box sits just under it.
        let hero_bottom = {
            let (bb, bg, br) = (self.bg[2], self.bg[1], self.bg[0]);
            let mut bottom = (h as usize) / 2; // fallback: mid-screen if nothing drew
            'scan: for y in (0..h as usize).rev() {
                let row = y * w as usize;
                for x in 0..w as usize {
                    let o = (row + x) * 4;
                    if canvas[o] != bb || canvas[o + 1] != bg || canvas[o + 2] != br {
                        bottom = y; break 'scan;
                    }
                }
            }
            bottom
        };

        // The panel: the greeter's frame, minus the user row. Drawn with the
        // interface atlas if we have one, else skipped (the ground still locks).
        if let Some(atlas) = &self.surfaces[i].atlas {
            let cw = atlas.cell_w;
            let line = self.pal.get(Role::Line);
            let dim = self.pal.get(Role::Dim);
            let neutral = self.pal.get(Role::Neutral);
            let accent = self.pal.get(Role::Accent);
            let error = self.pal.get(Role::Error);

            // ┌─ hostname ─────┐ / pass … / └────────┘ -- sized to the box the
            // greeter draws (a label, a gap, and a field), in cells.
            let title = format!(" {} ", self.hostname);
            let inner = (4 + 1 + 30).max(title.chars().count() + 2); // cols across the frame
            let top: String = {
                let dashes = inner.saturating_sub(2 + title.chars().count());
                format!("┌─{}{}┐", title, "─".repeat(dashes))
            };
            let bot: String = format!("└{}┘", "─".repeat(inner.saturating_sub(2)));

            // Password masked, one dot per character -- never the plaintext. Use
            // U+2022 BULLET, not U+25CF BLACK CIRCLE: the Terminus strikes carry no
            // U+25CF, so the old ● fell back (atlas.rs) to the tiny U+00B7 middle
            // dot -- a 2px sliver that read as no feedback at all. U+2022 is a
            // proper round dot present in every strike. Accent is state; Wrong
            // flashes error.
            let mask: String = "•".repeat(self.password.chars().count());
            let (pass_fg, label_fg) = match self.auth {
                Auth::Idle => (accent, dim),
                Auth::Wrong => (error, error),
            };

            let panel_w_px = top.chars().count() * cw;
            let px = (w as usize).saturating_sub(panel_w_px) / 2;
            // Just beneath the hero, clear of it -- higher than the old bottom
            // anchor -- and clamped so the three-row box never runs off screen.
            let base = (hero_bottom + atlas.cell_h * 3 / 2)
                .min((h as usize).saturating_sub(3 * atlas.cell_h));
            let ch = atlas.cell_h;
            text(canvas, w as usize, atlas, px, base,            &top, line, self.bg);
            text(canvas, w as usize, atlas, px, base + ch,       "pass", label_fg, self.bg);
            text(canvas, w as usize, atlas, px + 5 * cw, base + ch, &mask, pass_fg, self.bg);
            text(canvas, w as usize, atlas, px, base + 2 * ch,   &bot, line, self.bg);
            let _ = neutral;
        }

        let surface = self.surfaces[i].lock_surface.wl_surface().clone();
        surface.frame(qh, surface.clone());
        buffer.attach_to(&surface).ok();
        surface.commit();
    }

    fn redraw_all(&mut self, qh: &QueueHandle<Self>) {
        for i in 0..self.surfaces.len() {
            if self.surfaces[i].configured { self.draw(qh, i) }
        }
    }

    fn submit(&mut self, qh: &QueueHandle<Self>) {
        // Empty password never bothers PAM.
        if self.password.is_empty() { return }
        if authenticate(&self.user, &self.password) {
            if let Some(l) = self.session_lock.take() { l.unlock(); }
            self.exit = true;
        } else {
            self.password.clear();
            self.auth = Auth::Wrong;
            self.redraw_all(qh);
        }
    }
}

impl SessionLockHandler for Lock {
    fn locked(&mut self, _c: &Connection, qh: &QueueHandle<Self>, session_lock: SessionLock) {
        // main holds the SessionLock; this passed clone is not stored.
        let _ = &session_lock;
        for output in self.output_state.outputs() {
            self.ensure_surface(output, qh);
        }
        // The session is SECURE the moment this fires -- the compositor will not
        // show the desktop again until we unlock. Announce it once so null-lock
        // can return (and let suspend proceed) while we keep drawing and taking
        // the password. Never written again, so a closed reader cannot hurt us.
        use std::io::Write;
        let mut out = std::io::stdout();
        let _ = out.write_all(b"LOCKED\n");
        let _ = out.flush();
    }

    fn finished(&mut self, _c: &Connection, _qh: &QueueHandle<Self>, _l: SessionLock) {
        // The compositor tore the lock down (it stays locked itself); nothing
        // left for us to draw.
        self.exit = true;
    }

    fn configure(&mut self, _c: &Connection, qh: &QueueHandle<Self>,
                 surface: SessionLockSurface, cfg: SessionLockSurfaceConfigure, _serial: u32) {
        let (w, h) = cfg.new_size;
        let Some(i) = self.surfaces.iter().position(
            |s| s.lock_surface.wl_surface() == surface.wl_surface()) else { return };
        let changed = self.surfaces[i].w != w || self.surfaces[i].h != h;
        self.surfaces[i].w = w;
        self.surfaces[i].h = h;
        self.surfaces[i].configured = true;
        if changed || self.surfaces[i].cells.is_none() {
            match assets_for(&self.root, w, h) {
                Some((c, a)) => { self.surfaces[i].cells = Some(c); self.surfaces[i].atlas = Some(a); }
                None => { self.surfaces[i].cells = None; self.surfaces[i].atlas = None; }
            }
        }
        self.draw(qh, i);
    }
}

impl CompositorHandler for Lock {
    fn frame(&mut self, _c: &Connection, qh: &QueueHandle<Self>, surface: &wl_surface::WlSurface, _t: u32) {
        if let Some(i) = self.surfaces.iter().position(|s| s.lock_surface.wl_surface() == surface) {
            if self.surfaces[i].configured { self.draw(qh, i) }
        }
    }
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl KeyboardHandler for Lock {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
             _: &wl_surface::WlSurface, _: u32, _: &[u32], _: &[Keysym]) {}
    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32) {}
    fn update_modifiers(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, _: Modifiers, _: u32) {}
    fn update_repeat_info(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: smithay_client_toolkit::seat::keyboard::RepeatInfo) {}

    fn press_key(&mut self, _c: &Connection, qh: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
                 _serial: u32, event: KeyEvent) {
        match event.keysym {
            Keysym::Return | Keysym::KP_Enter => { self.submit(qh); }
            Keysym::BackSpace => { self.password.pop(); self.auth = Auth::Idle; self.redraw_all(qh); }
            Keysym::Escape => { self.password.clear(); self.auth = Auth::Idle; self.redraw_all(qh); }
            _ => {
                if let Some(t) = event.utf8 {
                    // Printable only: control characters never enter the buffer.
                    if !t.is_empty() && !t.chars().any(|c| c.is_control()) {
                        self.password.push_str(&t);
                        self.auth = Auth::Idle;
                        self.redraw_all(qh);
                    }
                }
            }
        }
    }
    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, _: KeyEvent) {}
}

impl SeatHandler for Lock {
    fn seat_state(&mut self) -> &mut SeatState { &mut self.seat_state }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(&mut self, _: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            if let Ok(kb) = self.seat_state.get_keyboard(qh, &seat, None) {
                self.keyboard = Some(kb);
            }
        }
    }
    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Keyboard {
            if let Some(kb) = self.keyboard.take() { kb.release() }
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl OutputHandler for Lock {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _c: &Connection, qh: &QueueHandle<Self>, output: wl_output::WlOutput) {
        // A monitor plugged in while locked gets the hero too; ensure_surface
        // is idempotent, so racing locked() cannot double-create it.
        self.ensure_surface(output, qh);
    }
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl ShmHandler for Lock {
    fn shm_state(&mut self) -> &mut Shm { &mut self.shm }
}

impl ProvidesRegistryState for Lock {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState, SeatState];
}

delegate_compositor!(Lock);
delegate_output!(Lock);
delegate_seat!(Lock);
delegate_keyboard!(Lock);
delegate_shm!(Lock);
delegate_session_lock!(Lock);
delegate_registry!(Lock);

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok().map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "nulllinux".into())
}

fn main() {
    // Argument handling, like the other components: this takes none.
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        None => {}
        Some("-h") | Some("--help") => {
            println!("usage: lock");
            println!();
            println!("  Locks the screen via ext-session-lock-v1, drawn like the greeter");
            println!("  (the hero and a pass panel), authenticating the current user via PAM.");
            println!("  Takes no arguments.");
            return;
        }
        Some(other) => { eprintln!("lock: unknown argument '{other}'"); std::process::exit(2); }
    }

    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN); }
    let root = std::env::var("NULL_ROOT").unwrap_or_else(|_| "/opt/nulllinux".into());
    let user = std::env::var("USER").ok()
        .or_else(|| std::env::var("LOGNAME").ok())
        .unwrap_or_default();
    if user.is_empty() {
        eprintln!("lock: cannot tell who to authenticate (no $USER); refusing to lock blind");
        std::process::exit(1);
    }
    // palette.json is a core asset every surface needs. If it is somehow gone
    // this is a broken install; rather than draw in a degenerate palette, exit
    // non-zero so null-lock falls through to swaylock -- the screen still LOCKS,
    // with the proven locker, which is the property that must never fail (§8.5).
    let pal = match Palette::load(&format!("{root}/assets/palette.json")) {
        Ok(p) => p,
        Err(e) => { eprintln!("lock: no palette ({e}); leaving the screen to the fallback locker"); std::process::exit(4); }
    };
    let bg = pal.get(Role::Background);

    let conn = match Connection::connect_to_env() {
        Ok(c) => c, Err(e) => { eprintln!("lock: no Wayland display: {e}"); std::process::exit(1) }
    };
    let (globals, mut queue) = match registry_queue_init(&conn) {
        Ok(v) => v, Err(e) => { eprintln!("lock: {e}"); std::process::exit(1) }
    };
    let qh = queue.handle();

    let session_lock_state = SessionLockState::new(&globals, &qh);
    let shm = Shm::bind(&globals, &qh).expect("wl_shm");
    let pool = SlotPool::new(4 * 1024 * 1024, &shm).expect("shm pool");

    let mut lock = Lock {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        compositor_state: CompositorState::bind(&globals, &qh).expect("wl_compositor"),
        shm,
        seat_state: SeatState::new(&globals, &qh),
        session_lock_state,
        session_lock: None,
        pool,
        keyboard: None,
        root,
        pal,
        bg,
        hostname: hostname(),
        user,
        surfaces: Vec::new(),
        start: Instant::now(),
        password: String::new(),
        auth: Auth::Idle,
        exit: false,
    };

    // Take the lock and KEEP the handle. Dropping it sends `destroy`, which the
    // compositor refuses while locked ("the session lock may not be destroyed
    // while locked") -- discarding the return here killed the client the instant
    // it locked, leaving the compositor's red fallback on screen. It is held
    // until submit() calls unlock() on it.
    match lock.session_lock_state.lock(&qh) {
        Ok(sl) => lock.session_lock = Some(sl),
        Err(_) => {
            eprintln!("lock: the compositor does not support ext-session-lock-v1");
            std::process::exit(3);
        }
    }

    // Manual event loop, like the other components: dispatch, and wake often
    // enough to advance the hero animation. A blocked dispatch would freeze the
    // animation; polling the wayland fd with a timeout does not.
    use std::os::fd::{AsFd, AsRawFd};
    let wl_fd = conn.as_fd().as_raw_fd();
    loop {
        queue.flush().ok();
        if let Some(g) = queue.prepare_read() {
            let mut fds = [libc::pollfd { fd: wl_fd, events: libc::POLLIN, revents: 0 }];
            // ~30 Hz wake: enough for the animation, cheap on a potato.
            let n = unsafe { libc::poll(fds.as_mut_ptr(), 1, 33) };
            if n > 0 && fds[0].revents & libc::POLLIN != 0 { g.read().ok(); }
            else { drop(g); }
        }
        queue.dispatch_pending(&mut lock).ok();
        // TEST ONLY -- never compiled into the shipped binary. The headless test
        // VM has no keyboard device, so no keymap ever reaches us and sctk drops
        // every key; live typing cannot be exercised there. This injects one
        // password attempt through the SAME submit()/PAM path a Return keypress
        // would take, once the lock surface is up. It authenticates for real --
        // it cannot unlock without the correct password -- so it verifies the
        // submit -> PAM -> unlock -> exit path end to end.
        #[cfg(feature = "lock-test-hook")]
        {
            use std::sync::atomic::{AtomicBool, Ordering};
            static DONE: AtomicBool = AtomicBool::new(false);
            if !DONE.load(Ordering::Relaxed)
                && lock.session_lock.is_some()
                && lock.surfaces.iter().any(|s| s.configured) {
                if let Ok(pw) = std::env::var("NULL_LOCK_TEST_PW") {
                    DONE.store(true, Ordering::Relaxed);
                    lock.password = pw;
                    lock.submit(&qh);
                }
            }
        }
        if lock.exit { break }
        // Advance the animation on the outputs that carry a hero.
        lock.redraw_all(&qh);
        if lock.exit { break }
    }
    // The lock is done -- either we unlocked (submit sent unlock_and_destroy) or
    // the compositor tore it down (finished()). Flush whatever submit queued to
    // the socket, then exit(0) WITHOUT running Drop.
    //
    // Skipping Drop is deliberate. Once the lock object is destroyed, the
    // per-output lock surfaces still held in self.surfaces would each send their
    // own destroy on drop -- destroys for children whose parent lock is already
    // gone. There is nothing worth cleaning up in a process about to die, so we
    // leave it to the compositor, which reaps the connection when the socket
    // closes. (Not a workaround for a hang: exiting is simply cleaner than a
    // teardown whose every request is redundant or racing the parent's.)
    queue.flush().ok();
    let _ = conn;
    std::process::exit(0);
}
