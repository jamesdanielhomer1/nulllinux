//! The column (NULL.md §7.3).
//!
//! A vertical layer surface that IS a terminal. It hosts real programs on a
//! pseudo-terminal rather than reimplementing them, and paints their screen
//! into its own cells with its own atlas and its own palette.
//!
//! Pressing a key does not open a window beside the column. The column BECOMES
//! that thing, and pressing again puts it back. The tempting intermediate -- a
//! floating window positioned exactly where the column is -- is a second
//! surface with its own font resolution sitting on top of one that unmapped
//! underneath, and the rule that positions it outlives the illusion and ends
//! up opening things invisibly behind the column.

use nulllinux::atlas::Atlas;
use nulllinux::grid::{Cell, TextGrid};
use nulllinux::palette::{Palette, Role};
use nulllinux::pty::Pty;
use nulllinux::vt::Vt;

use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_keyboard, delegate_layer, delegate_output,
    delegate_registry, delegate_seat, delegate_shm,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers}, Capability, SeatHandler, SeatState},
    shell::{
        wlr_layer::{Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler,
                    LayerSurface, LayerSurfaceConfigure},
        WaylandSurface,
    },
    shm::{slot::{Buffer, SlotPool}, Shm, ShmHandler},
};
use std::os::fd::{AsFd, AsRawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::os::unix::net::UnixDatagram;
use std::time::{Duration, Instant};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_keyboard, wl_output, wl_seat, wl_shm, wl_surface},
    Connection, QueueHandle,
};

/// The three widths, each justified by measurement (§7.3), recorded here
/// because a width chosen for a reason that is not written down is a width
/// somebody will change.
const NARROW: usize = 30;   // the instrument column
const PICK: usize = 65;     // the longest live keys row is 63 characters, plus two walls
const WIDE: usize = 82;     // btop refuses below 80 columns, plus two walls

fn socket_path() -> String {
    let d = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    format!("{d}/null-column.sock")
}

struct Slot { buffer: Buffer, gen: u64 }

struct Host {
    pty: Pty,
    vt: Vt,
    label: String,
}

struct Column {
    registry_state: RegistryState,
    output_state: OutputState,
    seat_state: SeatState,
    shm: Shm,
    pool: SlotPool,
    compositor: CompositorState,
    layer_shell: LayerShell,
    qh: QueueHandle<Column>,
    /// None while hidden.
    ///
    /// A layer surface is unmapped by DESTROYING it, not by attaching a null
    /// buffer. The null-buffer route is a dead end for anything that has to
    /// come back: the compositor will not configure a surface that is not on
    /// screen, and it rejects an attach that acks a stale configure serial --
    /// so the surface waits for a configure it can never receive, and forcing
    /// the attach earns "wrong configure serial" and death. Destroy it; build
    /// a fresh one on the way back.
    layer: Option<LayerSurface>,
    keyboard: Option<wl_keyboard::WlKeyboard>,

    atlas: Atlas,
    bold: Option<Atlas>,
    pal: Palette,
    grid: TextGrid,

    cols: usize,
    rows: usize,
    px_w: u32,
    px_h: u32,
    configured: bool,
    exit: bool,
    slots: Vec<Slot>,
    next_slot: usize,

    host: Option<Host>,
    pinned: bool,
    /// Where the width is going, and how it is getting there.
    ///
    /// The compositor must NOT animate this surface's geometry: it would scale
    /// our buffer into a box that is not its size, and a scaled bitmap grid is
    /// the one artefact this whole system exists to avoid (§6.3). But that
    /// forbids the COMPOSITOR interpolating, not motion itself -- so the width
    /// is stepped here, and every intermediate is a whole number of cells and
    /// therefore exactly as sharp as the endpoints.
    target_cols: usize,
    anim_from: usize,
    anim_start: Option<Instant>,
    /// Set when something that AFFECTS THE PICTURE has changed.
    ///
    /// Drawing every tick spins the surface: each draw commits, the compositor
    /// replies, the poll returns immediately, and round it goes. Measured at
    /// 75% of a core for a column sitting still. This is the same defect the
    /// bar and the wallpaper each had, arriving a third time by a third door
    /// (§7.2).
    content_dirty: bool,
    /// The idle panel, and the machinery to refresh it without spinning.
    glance: Glance,
    cpu: nulllinux::sysinfo::CpuSampler,
    last_sample: std::time::Instant,
    prev_net: (u64, u64),
    prev_io: (u64, u64),
    /// Recent history, newest last. Kept here and not in Glance: Glance exists
    /// to answer "did a displayed value change", and a ring that shifts every
    /// sample would answer yes for ever.
    cores: Vec<f32>,
    core_sampler: nulllinux::sysinfo::CoreSampler,
    /// When the slow text fields were last read, and whether the panel was on
    /// screen last tick -- together these ask for a full sample every three
    /// seconds, and immediately on the tick the panel reappears.
    last_full: std::time::Instant,
    was_visible: bool,
    spectrum: nulllinux::spectrum::Spectrum,
    now_playing: Option<String>,
    procs: Vec<(String, f32, u64, usize)>,
    prev_procs: std::collections::HashMap<u32, u64>,
    last_procs: std::time::Instant,
    last_np: std::time::Instant,
    ramp: Vec<char>,
    hint_menu: String,
    hint_keys: String,
    /// Are any windows visible right now? Watched on the compositor's event
    /// stream, exactly as the wallpaper watches it (§6.4).
    windows_present: Arc<AtomicBool>,
    /// Is a buffer currently attached? A surface with no buffer is unmapped.
    mapped: bool,
    /// Set when the surface must re-request its size and zone.
    geometry_dirty: bool,
    /// Set between asking for a new size and the compositor confirming it.
    ///
    /// A buffer must NOT be attached in that window: it would be a buffer of
    /// the new width on a surface still configured at the old one, which the
    /// compositor is entitled to reject and which leaves the exclusive zone
    /// looking as though it were never applied (§6.3).
    awaiting_configure: bool,

    repeat: Option<(Vec<u8>, Instant, Duration)>,
    repeat_rate: Duration,
    repeat_delay: Duration,

    draws: u64,
}

/// The repository root, derived from THIS executable's own location.
///
/// Not a literal. A hard-coded "/root/nulllinux" is an install location baked into
/// a binary, so moving the checkout -- which is exactly what moving the
/// session off root requires -- silently pointed every hosted command at a
/// directory that was no longer readable. The binary lives at
/// <root>/render/target/release/<name>, so the root is four levels up.
/// What the idle column shows, sampled once a second.
///
/// Compared field by field against the previous sample so the surface redraws
/// when a DISPLAYED value changes rather than on every tick -- the loop
/// already wakes four times a second and this must not turn that into four
/// redraws (§7.2).
#[derive(PartialEq, Default, Clone)]
struct Glance {
    cpu: u8,
    load: (f32, f32, f32),
    mem_used: u64,
    mem_total: u64,
    disk_used: u64,
    disk_total: u64,
    temp: Option<i16>,
    net: Option<(String, u8)>,
    swap_used: u64,
    swap_total: u64,
    rx_rate: u64,
    tx_rate: u64,
    io_r: u64,
    io_w: u64,
    batt: Option<(u8, bool, Option<u64>)>,
    up_min: u64,
}

/// The rows the bottom of the column keeps for itself: the footer's rule and
/// its two hint lines, and the equaliser. Everything above yields to these.
const FOOTER_H: usize = 4;
const EQ_H: usize = 6;

impl Glance {
    /// `full` asks for every field. `full = false` asks only for the three
    /// series the history graphs are built from -- CPU, memory and network --
    /// and carries everything else forward from `prev` unchanged.
    ///
    /// The distinction exists because the rings now advance whether or not the
    /// panel is on screen, and a full sample is not four /proc reads: it walks
    /// /sys/class/hwmon for a temperature, /sys/class/net for an interface and
    /// /sys/class/power_supply for a battery, every second. Those are all text
    /// fields. Nobody can read a text field on a surface that is not mapped,
    /// and none of them feed a graph, so off screen they are pure cost.
    fn sample(cpu: &mut nulllinux::sysinfo::CpuSampler, prev_net: &mut (u64, u64),
              prev_io: &mut (u64, u64), elapsed: f32, full: bool, prev: &Glance) -> Glance {
        let (mem_used, mem_total) = nulllinux::sysinfo::memory().unwrap_or((0, 0));
        let swap = nulllinux::sysinfo::swap().unwrap_or((0, 0));
        let (disk_used, disk_total) = if full {
            nulllinux::sysinfo::disk_usage("/").unwrap_or((0, 0))
        } else { (prev.disk_used, prev.disk_total) };
        let mut g = Glance {
            // BOTH of these return a FRACTION, not a percentage -- their
            // documentation says so and this code twice did not read it, so
            // every CPU figure under 50% rounded to 0 and every signal
            // strength read as no signal. Percentages are stored here, so the
            // change detection compares whole numbers rather than floats that
            // differ in the last bit and redraw for ever.
            cpu: (cpu.sample().unwrap_or(0.0) * 100.0).round().clamp(0.0, 100.0) as u8,
            load: if full { nulllinux::sysinfo::load_average().unwrap_or((0.0, 0.0, 0.0)) }
                  else { prev.load },
            mem_used, mem_total, disk_used, disk_total,
            // Cheap: the same /proc/meminfo the memory reading comes from.
            swap_used: swap.0, swap_total: swap.1,
            // Back behind `full`, now that it is a text field rather than a
            // graph. It was on the 1 Hz path so its history would accrue while
            // the panel was hidden; with no history to accrue, that is 0.06%
            // of a core spent on a number nobody can see. The sensor sweep is
            // still worth having cheap -- it blocked the draw timer for 5.7 ms
            // a call before, and 0.75 ms now.
            temp: if full { nulllinux::sysinfo::temperature().map(|t| t.round() as i16) }
                  else { prev.temp },
            // wireless_quality returns a FRACTION, not a percentage. Rounding
            // it without scaling made every reading 0%, which read as "no
            // signal" on a working connection.
            // The NETWORK's name where it is free, the interface's where it
            // is not -- "BRSK-863077" is what a person calls this connection;
            // "wlp0s20f3" is what the kernel calls the card it arrives on.
            net: if full {
                nulllinux::sysinfo::wireless_interface().map(|iface| {
                    let (q, ssid) = nulllinux::sysinfo::wireless_link_cached()
                        .unwrap_or((0.0, None));
                    (ssid.unwrap_or(iface), (q * 100.0).round().clamp(0.0, 100.0) as u8)
                })
            } else { prev.net.clone() },
            rx_rate: 0,
            tx_rate: 0,
            io_r: 0,
            io_w: 0,
            batt: if full {
                nulllinux::sysinfo::battery().map(|b| (b.percent, b.charging, b.secs_left))
            } else { prev.batt },
            // MINUTES, not seconds: at second resolution this field alone
            // would mark the surface dirty every single second forever.
            up_min: if full { nulllinux::sysinfo::uptime().map(|d| d.as_secs() / 60).unwrap_or(0) }
                    else { prev.up_min },
            ..Default::default()
        };
        if let Some((rx, tx)) = nulllinux::sysinfo::net_bytes() {
            if prev_net.0 > 0 && elapsed > 0.0 {
                g.rx_rate = ((rx.saturating_sub(prev_net.0)) as f32 / elapsed) as u64;
                g.tx_rate = ((tx.saturating_sub(prev_net.1)) as f32 / elapsed) as u64;
            }
            *prev_net = (rx, tx);
        }
        if let Some((r, w)) = nulllinux::sysinfo::disk_io() {
            if prev_io.0 > 0 && elapsed > 0.0 {
                g.io_r = ((r.saturating_sub(prev_io.0)) as f32 / elapsed) as u64;
                g.io_w = ((w.saturating_sub(prev_io.1)) as f32 / elapsed) as u64;
            }
            *prev_io = (r, w);
        }
        g
    }
}

/// The chord bound to a given description, read from the configuration.
///
/// NOT written here. The idle column used to say "SUPER+T monitor", which was
/// true when it was typed and false the moment the bindings were rebuilt --
/// super+t floats a window now. A hint that can disagree with the keyboard is
/// worse than no hint, so it is looked up by the description the binding
/// already carries for the key list (§8.3).
fn chord_for(root: &str, want: &str) -> Option<String> {
    let text = std::fs::read_to_string(format!("{root}/config/sway/bindings.conf")).ok()?;
    let mut pending: Option<String> = None;
    for line in text.lines() {
        let t = line.trim();
        if let Some(d) = t.strip_prefix("#:") {
            pending = Some(d.trim().to_string());
            continue;
        }
        if let Some(rest) = t.strip_prefix("bindsym ") {
            if pending.as_deref() == Some(want) {
                let chord = rest.split_whitespace().next()?;
                return Some(chord.replace("$mod", "SUPER").to_uppercase());
            }
            pending = None;
        }
    }
    None
}

fn null_root() -> String {
    if let Ok(v) = std::env::var("NULL_ROOT") {
        return v;
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.ancestors().nth(4).map(|p| p.to_path_buf()))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| ".".into())
}

fn main() {
    let root = null_root();
    let args: Vec<String> = std::env::args().skip(1).collect();

    // --send is the client half, living in the SAME binary that binds the
    // socket. The path is defined here and nowhere else: a second channel
    // spelled in two places is the defect this exists to avoid.
    if let Some(i) = args.iter().position(|a| a == "--send") {
        let msg = args[i + 1..].join(" ");
        let s = UnixDatagram::unbound().expect("socket");
        match s.send_to(msg.as_bytes(), socket_path()) {
            Ok(_) => return,
            Err(e) => { eprintln!("column: no column listening ({e})"); std::process::exit(1) }
        }
    }

    let atlas = Atlas::load(&format!("{root}/assets/atlas-interface.bin"))
        .unwrap_or_else(|e| { eprintln!("column: {e}"); std::process::exit(1) });
    let bold = Atlas::load(&format!("{root}/assets/atlas-interface-bold.bin")).ok();
    let pal = Palette::load(&format!("{root}/assets/palette.json"))
        .unwrap_or_else(|e| { eprintln!("column: {e}"); std::process::exit(1) });
    // Hosted programs get this palette's sixteen, not the VGA sixteen. Set
    // before anything can be hosted, because it takes only on the first call.
    nulllinux::vt::set_ansi16(pal.ansi16());

    let conn = Connection::connect_to_env().expect("no Wayland display");
    let (globals, mut queue) = registry_queue_init(&conn).expect("registry");
    let qh = queue.handle();
    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("wlr-layer-shell");
    let shm = Shm::bind(&globals, &qh).expect("wl_shm");

    // THE COMPOSITOR KNOWS HOW TALL THE SCREEN IS; THIS DID NOT.
    //
    // This read `(1080 - bar_px)` -- the height of the panel on the machine the
    // project was written on. The surface is anchored TOP and BOTTOM, so the
    // compositor gives it the full remaining height for the asking, and asking
    // is passing 0 on that axis. It already recomputes `rows` from the
    // configured height (see configure below); it simply never asked.
    //
    // On a 1440-tall screen the column stopped 205 px short of the bottom.
    //
    // The bar reserves its own zone, so the column starts below it anyway.
    let bar_px = 2 * atlas.cell_h;
    // Provisional only -- replaced by the first configure. Kept as a sane
    // starting size so the pool below is not allocated at zero.
    let rows = (1080 - bar_px) / atlas.cell_h;
    let cols = NARROW;
    let px_w = (cols * atlas.cell_w) as u32;
    let px_h = (rows * atlas.cell_h) as u32;


    let pool = SlotPool::new((WIDE * atlas.cell_w * rows * atlas.cell_h * 4 * 2) as usize, &shm)
        .expect("pool");
    // The surface is created on the first tick that wants it, not here: show
    // and hide are create and destroy (§6.3).
    let grid = TextGrid::new(cols, rows, pal.get(Role::Background));

    // Bind the socket, but only after proving nobody is listening. A `ping`
    // that is accepted means a column is already on screen and this instance
    // keeps its hands off; one that fails means the file is a leftover. Without
    // the probe, any second instance silently steals every menu keybind from
    // the column actually on screen.
    let path = socket_path();
    let probe = UnixDatagram::unbound().ok()
        .map(|s| s.send_to(b"ping", &path).is_ok()).unwrap_or(false);
    if probe {
        eprintln!("column: another column is already listening -- not taking the socket");
        std::process::exit(1);
    }
    let _ = std::fs::remove_file(&path);
    let ctrl = UnixDatagram::bind(&path).expect("bind control socket");
    ctrl.set_nonblocking(true).ok();

    let mut col = Column {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        seat_state: SeatState::new(&globals, &qh),
        shm, pool,
        compositor, layer_shell, qh: qh.clone(),
        layer: None,
        keyboard: None,
        atlas, bold, pal, grid,
        cols, rows, px_w, px_h,
        configured: false, exit: false,
        slots: Vec::new(), next_slot: 0,
        host: None, pinned: false,
        target_cols: cols, anim_from: cols, anim_start: None,
        content_dirty: true,
        glance: Glance::default(),
        cpu: nulllinux::sysinfo::CpuSampler::new(),
        last_sample: std::time::Instant::now() - std::time::Duration::from_secs(2),
        prev_net: (0, 0),
        prev_io: (0, 0),
        cores: Vec::new(),
        core_sampler: Default::default(),
        last_full: std::time::Instant::now(), was_visible: false,
        // Bars match the width they will be drawn in, and the frame rate is
        // deliberately low: an equaliser is glanced at, not studied (§10.7).
        // 8 frames a second, not 12 and not a display rate. §10.7 warns that
        // this dependency multiplies a surface's cost, and it does: measured
        // at 12 fps the column went from 0.75% of a core to 7%. The frame rate
        // is the only honest lever, so it is set low and the figure is
        // recorded rather than the warning being ignored.
        now_playing: None,
        procs: Vec::new(),
        prev_procs: std::collections::HashMap::new(),
        last_procs: std::time::Instant::now(),
        last_np: std::time::Instant::now() - std::time::Duration::from_secs(9),
        spectrum: nulllinux::spectrum::Spectrum::start(
            NARROW.saturating_sub(4),
            std::env::var("NULL_SPECTRUM_FPS").ok()
                .and_then(|v| v.parse().ok()).unwrap_or(8),
            &std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into())),
        ramp: std::fs::read_to_string(format!("{root}/assets/ramp-interface.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
            .and_then(|v| v.get("ramp").and_then(|r| r.as_str()).map(|s| s.chars().collect()))
            .unwrap_or_else(|| " .:-=+*#%@".chars().collect()),
        hint_menu: chord_for(&root, "The menu").unwrap_or_else(|| "?".into()),
        hint_keys: chord_for(&root, "Every key binding")
                       .unwrap_or_else(|| "?".into()),
        windows_present: {
            let f = Arc::new(AtomicBool::new(false));
            nulllinux::ipc::spawn_occlusion_watch(f.clone());
            f
        },
        mapped: false,
        geometry_dirty: false, awaiting_configure: false,
        repeat: None,
        repeat_rate: Duration::from_millis(40),
        repeat_delay: Duration::from_millis(600),
        draws: 0,
    };

    let mut buf = [0u8; 4096];
    loop {
        queue.flush().ok();
        // The idle figures. The loop already wakes four times a second; this
        // turns a wake into a REDRAW only when a displayed value has moved.
        if col.sample_glance() { col.content_dirty = true }
        // Only while the panel is visible: nothing under a host or an unmapped
        // surface should be redrawing for sound nobody can see.
        if col.spectrum_visible() && col.spectrum.poll() { col.content_dirty = true }
        col.tick(&qh);
        queue.flush().ok();

        let read_guard = queue.prepare_read();
        let wl = conn.as_fd().as_raw_fd();
        let cs = ctrl.as_raw_fd();
        let pt = col.host.as_ref().map(|h| h.pty.fd()).unwrap_or(-1);

        let mut fds = vec![
            libc::pollfd { fd: wl, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: cs, events: libc::POLLIN, revents: 0 },
        ];
        if pt >= 0 { fds.push(libc::pollfd { fd: pt, events: libc::POLLIN, revents: 0 }) }
        // CAVA'S PIPE IS DELIBERATELY NOT POLLED.
        //
        // It was, and the column span at 99.7% of a core with no audio playing
        // at all: the pipe reports itself ready whether or not a frame is in
        // it, so poll returned instantly for ever. A descriptor that is always
        // ready is not a wake source, it is a busy loop with extra steps.
        //
        // It is drained on this loop's own timer instead, which is a rate this
        // program chooses rather than one the pipe imposes.

        // A timeout only when a key repeat is pending: the compositor states a
        // rate and a delay once and then says nothing more, so every repeat is
        // this client's own timer (§7.3).
        let timeout = if col.anim_start.is_some() {
            // While the width is moving the loop has to run at frame rate, or
            // the "animation" is three steps and a jump. Each step still waits
            // for its own configure, so this bounds the wait rather than
            // busy-spinning.
            8
        } else {
            match &col.repeat {
                Some((_, at, _)) => at.saturating_duration_since(Instant::now()).as_millis() as i32,
                // While the equaliser is on screen the wait is the frame
                // interval: that is what sets its rate, and it is bounded by
                // construction rather than by whatever the pipe does.
                None if col.spectrum_visible() => 125,
                // Without a host there is no descriptor to wake on, and the map
                // state depends on the compositor's window count -- so the wait
                // is bounded rather than indefinite.
                None => 250,
            }
        };
        unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout.max(0)) };

        // The compositor going away must END the column, not spin or hang it: a
        // dead Wayland fd polls ready for ever, and a client that ignores the
        // hangup becomes an orphan its supervisor never sees exit (§7.3). A
        // hangup, a failed read, or a dispatch error all mean the display is gone.
        let mut lost = fds[0].revents & (libc::POLLHUP | libc::POLLERR) != 0;
        if let Some(g) = read_guard {
            if fds[0].revents & libc::POLLIN != 0 {
                if g.read().is_err() { lost = true; }
            }
        }
        if queue.dispatch_pending(&mut col).is_err() { lost = true; }
        if lost { col.exit = true; }

        if fds[1].revents & libc::POLLIN != 0 {
            while let Ok((n, _)) = ctrl.recv_from(&mut buf) {
                let msg = String::from_utf8_lossy(&buf[..n]).trim().to_string();
                if msg != "ping" {
                    if std::env::var_os("COLUMN_STATS").is_some() {
                        eprintln!("command: {msg:?}");
                    }
                    col.command(&msg)
                }
                if n == 0 { break }
            }
        }
        if fds.len() > 2 {
            // Any descriptor in a wait set needs an end-of-file check: one
            // whose writer has exited reports ready on every call and the
            // timeout stops applying (§7.2).
            if fds[2].revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                col.stop_host();
            } else if fds[2].revents & libc::POLLIN != 0 {
                col.pump_host();
            }
        }
        col.service_repeat();
        if col.exit { break }
    }
    let _ = std::fs::remove_file(socket_path());
}

impl Column {
    /// How long a width change takes. Long enough to read as motion, short
    /// enough that a menu still feels instant.
    const ANIM: Duration = Duration::from_millis(165);

    /// Ask for a new width. The change is stepped, not jumped.
    fn animate_to(&mut self, cols: usize) {
        if cols == self.target_cols { return }
        self.anim_from = self.cols;
        self.target_cols = cols;
        self.anim_start = Some(Instant::now());
    }

    /// Advance the width one step. Returns true while still moving.
    fn step_animation(&mut self) -> bool {
        let Some(start) = self.anim_start else { return false };
        let t = (start.elapsed().as_secs_f32() / Self::ANIM.as_secs_f32()).min(1.0);
        // Ease IN-OUT rather than ease-out. Ease-out moves fastest at the very
        // start, which is exactly where each step is waiting on its own
        // configure round-trip -- so the first move jumped sixteen cells while
        // the rest were one or two. In-out spends its speed in the middle,
        // where the loop can actually keep up, and the steps come out even.
        let e = if t < 0.5 {
            4.0 * t * t * t
        } else {
            let u = -2.0 * t + 2.0;
            1.0 - u * u * u / 2.0
        };
        let from = self.anim_from as f32;
        let to = self.target_cols as f32;
        // Rounded to whole CELLS. A fractional width would have to be
        // resampled by somebody, and that somebody would be the compositor.
        let w = (from + (to - from) * e).round() as usize;
        let w = w.max(1);
        if w != self.cols {
            self.cols = w;
            self.geometry_dirty = true;
            self.content_dirty = true;
        }
        if t >= 1.0 {
            self.anim_start = None;
            self.cols = self.target_cols;
            return false;
        }
        true
    }

    fn width_for(&self, topic: &str) -> usize {
        match topic {
            "monitor" => WIDE,
            // nmtui lays out for eighty and centres its dialogs; below that it
            // still runs but the forms wrap into each other.
            "netconfig" => WIDE,
            "mixer" => WIDE,
            "files" => PICK,
            "" => NARROW,
            _ => PICK,
        }
    }

    fn command(&mut self, msg: &str) {
        let mut it = msg.split_whitespace();
        match it.next() {
            Some("open") => {
                let topic = it.next().unwrap_or("").to_string();
                self.start_host(&topic);
            }
            Some("close") => self.stop_host(),
            Some("pin") => { self.pinned = !self.pinned; self.geometry_dirty = true;
                             self.content_dirty = true }
            Some("stop") => self.exit = true,
            _ => {}
        }
    }

    fn start_host(&mut self, topic: &str) {
        // Pressing the same topic again puts the column back, which is what
        // "the column becomes that thing, and pressing again puts it back"
        // means in practice.
        if self.host.as_ref().map(|h| h.label == topic).unwrap_or(false) {
            self.stop_host();
            return;
        }
        self.stop_host();

        let root = null_root();

        // The topic arrives over a socket, so it is validated before it is put
        // anywhere near a shell. Lower-case and dashes is the whole vocabulary
        // of a menu topic; anything else is not a typo, it is someone else.
        if topic.is_empty()
            || !topic.chars().all(|c| c.is_ascii_lowercase() || c == '-')
            || topic.len() > 32
        {
            return;
        }

        // EVERY menu topic is hostable, not a hard-coded pair. Only "monitor"
        // and "keys" used to be, and every other topic silently did nothing --
        // so the bindings that opened the menu had never worked. A dispatch
        // that returns for the default case is one that fails in silence, and
        // this one did for months.
        let argv: Vec<String> = match topic {
            "monitor" => vec!["btop".into()],
            // NetworkManager's own TUI. Measured before it was allowed in:
            // 976 printable cells, zero codepoints the font cannot draw
            // (§10.5). It is the one tool here that can do the things a
            // hand-rolled picker should not try to -- static addresses, VPNs,
            // 802.1x, editing a saved connection rather than rejoining it.
            "netconfig" => vec!["nmtui".into()],
            // The PipeWire mixer. Per-stream volume and routing, which the
            // settings panel deliberately does not attempt.
            // Through the wrapper, not straight to wiremix: with no daemon
            // to talk to it prints "Initializing..." and waits for ever,
            // which looks exactly like working.
            "mixer" => vec![format!("{root}/bin/null-mixer")],
            _ => vec!["sh".into(), "-c".into(),
                      format!("NULL_COLUMN=1 NULL_ROOT={root} {root}/bin/null-menu {topic}")],
        };

        let w = self.width_for(topic);
        let inner_cols = w.saturating_sub(2);
        let inner_rows = self.rows.saturating_sub(2);

        // btop rewrites its own configuration on exit, so it is pointed at a
        // copy rather than at anything this repository owns (§10.5).
        let cfg = format!("{}/null-column-config",
                          std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into()));
        std::fs::create_dir_all(format!("{cfg}/btop")).ok();
        std::fs::copy(format!("{root}/config/btop/btop.conf"),
                      format!("{cfg}/btop/btop.conf")).ok();

        // newt reads its whole colour scheme from one environment variable, in
        // ANSI colour NAMES -- so it inherits this palette through the same
        // remap every other hosted program now does, and there is no second
        // copy of any colour to keep in step. Flat, dark, warm-labelled: the
        // scheme the rest of nullLinux uses, said in newt's vocabulary.
        //
        // Set for every hosted program, not just nmtui: it costs one variable
        // and anything else linked against newt gets it for free.
        let newt = [
            "root=white,black", "border=white,black", "window=white,black",
            "shadow=black,black", "title=yellow,black",
            "button=black,white", "actbutton=black,yellow",
            "checkbox=white,black", "actcheckbox=black,yellow",
            "entry=white,black", "disentry=gray,black",
            "label=yellow,black", "listbox=white,black", "actlistbox=black,white",
            "sellistbox=yellow,black", "actsellistbox=black,yellow",
            "textbox=white,black", "acttextbox=black,white",
            "helpline=white,black", "roottext=white,black",
            "emptyscale=black,black", "fullscale=black,yellow",
            "compactbutton=white,black",
        ].join(":");

        match Pty::spawn(&argv, inner_cols as u16, inner_rows as u16,
                         &[("XDG_CONFIG_HOME".into(), cfg),
                           ("NEWT_COLORS".into(), newt)]) {
            Ok(pty) => {
                self.host = Some(Host {
                    pty,
                    vt: Vt::new(inner_cols, inner_rows),
                    label: topic.to_string(),
                });
                self.animate_to(w);
            }
            Err(e) => eprintln!("column: cannot host {topic}: {e}"),
        }
    }

    fn stop_host(&mut self) {
        if self.host.take().is_some() {
            self.animate_to(NARROW);
        }
    }

    fn pump_host(&mut self) {
        let mut buf = [0u8; 65536];
        let mut ended = false;
        if let Some(h) = self.host.as_mut() {
            match h.pty.read(&mut buf) {
                Ok(0) => ended = true,
                Ok(n) => { h.vt.feed(&buf[..n]); }
                Err(_) => ended = true,
            }
        }
        // The hosted program wrote something, so the picture changed.
        self.content_dirty = true;
        // The surface does not have to know WHY the program went. Killing a
        // hosted program from outside takes the column back to its narrow
        // width within a second, with no keybind involved -- which is the
        // whole of "close again when you're done" (§7.3).
        if ended { self.stop_host() }
    }

    fn service_repeat(&mut self) {
        let due = matches!(&self.repeat, Some((_, at, _)) if *at <= Instant::now());
        if !due { return }
        if let Some((bytes, at, _)) = self.repeat.as_mut() {
            let b = bytes.clone();
            *at = Instant::now() + Duration::from_millis(40);
            if let Some(h) = self.host.as_ref() { let _ = h.pty.write(&b); }
        }
    }

    fn apply_geometry(&mut self) {
        if !self.geometry_dirty { return }
        self.geometry_dirty = false;
        self.px_w = (self.cols * self.atlas.cell_w) as u32;
        let Some(layer) = self.layer.as_ref() else { return };
        layer.set_size(self.px_w, 0);   // 0 = full height, see run()

        // The zone is claimed exactly when there is something to tile beside:
        // pinned, or hosting. Changing size and zone on a MAPPED surface
        // reflows tiled windows within a millisecond and needs no unmap.
        // Claim the zone whenever the surface is on screen AND there is
        // something it could cover.
        //
        // This subsumes the old "pinned or hosting" rule and fixes what that
        // rule missed. The column retracts only when a window has appeared and
        // it is neither pinned nor hosting -- so under the old rule the whole
        // retract played with a zone of zero, and for those two hundred
        // milliseconds the column sat ON TOP of the window it was getting out
        // of the way of.
        //
        // With the zone tracking the animated width, the window grows as the
        // column shrinks and is never covered at any point.
        //
        // On a bare desktop there are no windows, so nothing is claimed --
        // which is the case §7.3 was actually describing.
        let covering = self.windows_present.load(Ordering::Relaxed);
        let zone = if self.pinned || self.host.is_some() || covering {
            self.px_w as i32
        } else {
            0
        };
        layer.set_exclusive_zone(zone);
        if std::env::var_os("COLUMN_STATS").is_some() {
            eprintln!("geometry: cols={} px_w={} zone={} hosting={} pinned={}",
                      self.cols, self.px_w, zone, self.host.is_some(), self.pinned);
        }

        layer.set_keyboard_interactivity(if self.host.is_some() {
            // Exclusive only while hosting. A readout column that held focus
            // would be a trap: every keystroke meant for the terminal beside
            // it would go nowhere.
            KeyboardInteractivity::Exclusive
        } else {
            KeyboardInteractivity::None
        });
        // The grid is rebuilt when the configure arrives, not here: this only
        // ASKS for a size, and asking is not being granted one.
        self.awaiting_configure = true;
        self.content_dirty = true;
        layer.commit();
    }

    /// The three states (§7.3), decided in ONE place so they cannot drift:
    ///
    ///   hosting or pinned  -> mapped, claiming its width
    ///   desktop bare       -> mapped, claiming nothing
    ///   anything else      -> UNMAPPED
    ///
    /// The third is the one that is easy to omit, and omitting it gives a
    /// column that sits on top of the windows rather than beside them.
    fn should_be_mapped(&self) -> bool {
        self.pinned || self.host.is_some() || !self.windows_present.load(Ordering::Relaxed)
    }

    /// Build a fresh layer surface. This is what "show" means.
    fn create_surface(&mut self) {
        if self.layer.is_some() { return }
        let surface = self.compositor.create_surface(&self.qh);
        // `None` IS DELIBERATE HERE, and is not the bug it is in the bar and
        // the wallpaper. Those are per-screen furniture and must be pinned, one
        // process per output. The column is ONE summonable panel with one IPC
        // socket, and it should open on the screen you are working on -- which
        // is exactly what `None` means to the compositor: the focused output.
        // Because show and hide are create and destroy (§6.3), it re-picks the
        // focused output every time it opens, so it follows you between
        // monitors for free. Pinning it would nail it to one screen.
        let layer = self.layer_shell.create_layer_surface(
            &self.qh, surface, Layer::Top, Some("null-column"), None);
        layer.set_anchor(Anchor::LEFT | Anchor::TOP | Anchor::BOTTOM);
        layer.set_size((self.cols * self.atlas.cell_w) as u32, 0);
        layer.set_exclusive_zone(0);
        layer.set_keyboard_interactivity(KeyboardInteractivity::None);
        // The initial commit carries NO buffer: the compositor answers with a
        // configure, and only then may a buffer be attached (§6.3).
        layer.commit();
        self.layer = Some(layer);
        self.configured = false;
        self.mapped = false;
        self.awaiting_configure = false;
        self.slots.clear();
    }

    /// Destroy the layer surface. This is what "hide" means.
    ///
    /// A layer surface is unmapped by DESTROYING it, not by attaching a null
    /// buffer. The null-buffer route is a dead end for anything that has to
    /// come back, and it fails in two mutually reinforcing ways: the
    /// compositor will not configure a surface that is not on screen, so a
    /// re-show waits for a configure that can never arrive; and forcing the
    /// attach without one is answered with "wrong configure serial" and the
    /// client is killed. Destroy it and build a fresh one.
    fn destroy_surface(&mut self) {
        if self.layer.is_none() { return }
        // Release the zone before the surface goes, or the compositor can be
        // left reserving space for something that no longer exists (§6.3).
        if let Some(l) = self.layer.as_ref() {
            l.set_exclusive_zone(0);
            l.commit();
        }
        self.layer = None;              // dropping it destroys it
        self.mapped = false;
        self.configured = false;
        self.awaiting_configure = false;
        self.slots.clear();
        self.anim_start = None;
        self.cols = NARROW;
        self.target_cols = NARROW;
    }

    fn tick(&mut self, qh: &QueueHandle<Self>) {
        // NOT gated on `configured` here. With the surface created on demand
        // there is nothing to configure until this function creates it, so a
        // guard at the top returns for ever and no surface is ever built --
        // which is exactly what happened. The configured check belongs after
        // the create branch, not before it.
        let want = self.should_be_mapped();
        if std::env::var_os("COLUMN_STATS").is_some() {
            eprintln!("tick: want={} live={} mapped={} cols={} target={} anim={} awaiting={}",
                      want, self.layer.is_some(), self.mapped, self.cols,
                      self.target_cols, self.anim_start.is_some(), self.awaiting_configure);
        }

        if !want {
            // Retract before vanishing. Destroying the surface outright makes
            // the column pop out of existence; sliding it shut first reads as
            // it leaving.
            if self.layer.is_some() && self.mapped && self.cols > 1 {
                self.animate_to(1);
                self.step_animation();
                self.apply_geometry();
                if !self.awaiting_configure && self.content_dirty {
                    self.content_dirty = false;
                    self.draw();
                }
                return;
            }
            self.destroy_surface();
            return;
        }

        if self.layer.is_none() {
            // Coming back: a FRESH surface, opening from a sliver. Nothing is
            // drawn this tick -- the compositor has to configure it first.
            self.cols = 1;
            self.anim_from = 1;
            self.target_cols = self.width_for(
                self.host.as_ref().map(|h| h.label.as_str()).unwrap_or(""));
            self.create_surface();
            self.anim_start = Some(Instant::now());
            self.geometry_dirty = true;
            return;
        }
        if !self.configured { return }

        self.step_animation();
        self.apply_geometry();

        // Wait for a configure only when the surface is MAPPED.
        //
        // An unmapped surface has no buffer, and a compositor does not
        // configure a surface that is not on screen -- so waiting for one
        // before the first attach waits for ever. That is what stalled the
        // column at 27 cells with awaiting=true and no configure in sight,
        // after it had correctly decided to come back.
        //
        // It is the mirror of the wallpaper's deadlock: there, a surface
        // suspended before its first draw never mapped and so never received a
        // callback. Same shape, opposite direction -- the first frame has to go
        // out before the compositor will talk to you (§6.3).
        if self.awaiting_configure && self.mapped { return }
        // ... and nothing is drawn when nothing has changed.
        if !self.content_dirty { return }
        self.content_dirty = false;
        self.draw();
        let _ = qh;
    }

    /// Refresh the idle figures, at most once a second.
    ///
    /// Only while the panel is actually visible: hosting covers it, and an
    /// occluded surface must not be sampling anything (§6.4). Returns true
    /// when a DISPLAYED value moved, which is the only reason to redraw.
    fn sample_glance(&mut self) -> bool {
        // Visible means: not hosting something over it, and actually mapped.
        let visible = self.host.is_none() && self.should_be_mapped();
        // What is playing, asked for every few seconds rather than every one:
        // this costs a process, and a track title does not change faster than
        // a person can read it.
        let mut np_changed = false;
        if visible && self.last_np.elapsed() >= std::time::Duration::from_secs(5) {
            self.last_np = std::time::Instant::now();
            let next = std::process::Command::new("playerctl")
                .args(["metadata", "--format", "{{artist}} - {{title}}"])
                .output().ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|t| !t.is_empty() && t != "-");
            if next != self.now_playing { self.now_playing = next; np_changed = true }
        }

        let elapsed = self.last_sample.elapsed();
        if elapsed < std::time::Duration::from_secs(1) { return np_changed }
        self.last_sample = std::time::Instant::now();
        // A full sample every THREE seconds, not every one -- and at once on
        // the tick the panel reappears, so it never shows a stale temperature
        // while it waits for the interval.
        //
        // TEMP, LINK, BATT, DISK and UP are the fields this decides. None of
        // them can move meaningfully inside a second: UP is counted in
        // minutes, a battery percentage takes minutes, and free disk space on
        // an idle machine takes longer than that. Reading them at 1 Hz cost
        // about a percent of a core to display numbers that were identical
        // three times out of three.
        let appeared = visible && !self.was_visible;
        let full = visible
            && (appeared || self.last_full.elapsed() >= std::time::Duration::from_secs(3));
        if full { self.last_full = std::time::Instant::now() }
        self.was_visible = visible;
        let next = Glance::sample(&mut self.cpu, &mut self.prev_net, &mut self.prev_io,
                                  elapsed.as_secs_f32(), full, &self.glance);
        // EVERY THREE SECONDS, not every one. Reading 263 process directories
        // a second cost 1.3% of a core on its own -- more than the whole panel
        // did before it. And a three-second delta is a steadier reading than a
        // one-second one, so this is cheaper AND better, which is the only
        // kind of optimisation worth taking without argument.
        // Per core, only while the panel is on screen. There is no history to
        // accumulate here -- it is an instantaneous spread across cores, not a
        // series -- so sampling it unseen would buy nothing at all.
        if visible { self.cores = self.core_sampler.sample() } else { self.cores.clear() }

        if appeared {
            // SEED, on the tick the panel appears. A process's CPU share is a
            // delta between two readings, so the first reading after a reveal
            // produces nothing at all -- BUSIEST came up empty and stayed
            // empty for a whole interval, which on a panel whose entire job is
            // to be glanced at is most of the time anyone looks at it.
            //
            // Throwing this reading away costs one /proc walk per reveal and
            // buys a populated section a second later instead of three.
            nulllinux::sysinfo::top_processes(&mut self.prev_procs, 1.0, 4);
            self.last_procs = std::time::Instant::now()
                .checked_sub(std::time::Duration::from_secs(2))
                .unwrap_or_else(std::time::Instant::now);
        } else if visible && self.last_procs.elapsed() >= std::time::Duration::from_secs(3) {
            let pe = self.last_procs.elapsed().as_secs_f32();
            self.last_procs = std::time::Instant::now();
            self.procs = nulllinux::sysinfo::top_processes(&mut self.prev_procs, pe, 4);
        }

        self.glance = next;
        // HISTORY accrues whether or not anyone is looking; DRAWING does not.
        //
        // The gate used to sit at the top of this function, which meant the
        // rings only advanced while the panel was on screen -- so a graph of
        // "the last 26 samples" could span an hour of wall clock with holes in
        // it wherever a window had been open. A sparkline survived that as
        // decoration. A five-row graph with a stated ceiling is presented as a
        // record, and it has to be one.
        //
        // What stays behind the gate is everything that costs: playerctl (a
        // process) and the /proc process scan (263 directories). What runs
        // regardless is four small /proc reads -- /proc/stat, /proc/meminfo,
        // /proc/net/dev, /proc/diskstats -- which is what a sparkline always
        // cost, and is the price of the window meaning what it says.
        //
        // Sampling on the timer also fixes the rate arithmetic: `elapsed` is
        // now always about a second, where before the first sample after the
        // panel reappeared divided a burst by however long it had been hidden.
        visible
    }


    /// Is the equaliser actually on screen, and therefore worth reading for?
    fn spectrum_visible(&self) -> bool {
        self.host.is_none() && self.should_be_mapped() && self.spectrum.available()
    }

    /// The idle panel.
    ///
    /// Deliberately NOT the bar again. The bar already carries the current
    /// numbers across the top of the screen; a strip down the side can show
    /// what a row cannot -- where those numbers have BEEN, and what the audio
    /// is doing right now.
    fn draw_glance(&mut self, cols: usize, rows: usize) {
        let (dim, neutral, line) =
            (self.pal.get(Role::Dim), self.pal.get(Role::Neutral), self.pal.get(Role::Line));
        let g = self.glance.clone();
        let inner = cols.saturating_sub(4);
        if inner < 18 || rows < 20 { return }
        let x0 = 2usize;
        let ramp = self.ramp.clone();
        let mut y = 2usize;

        // Numbers, not graphs.
        //
        // This section was five filled history graphs and James's verdict on
        // them was that they looked mid. He is right, and the reason is worth
        // writing down: at twenty-six columns a history is twenty-six samples,
        // which is not enough of a series to show a trend and is more than
        // enough texture to make the panel look busy. The readings themselves
        // are what the panel is for, and they were the smallest thing on it.
        //
        // The rings, the scales, the bands and the fill are all gone with
        // them. Keeping a graph nobody wanted would have meant keeping the
        // sampling that fed it, which was most of what this panel cost.
        let small = |c: &mut Self, y: &mut usize, name: &str, value: String| {
            c.grid.text(x0, *y, name, dim);
            let vx = x0 + inner.saturating_sub(value.chars().count());
            c.grid.text(vx, *y, &value, neutral);
            *y += 1;
        };
        // Two numbers on one line, each labelled -- the form the rx/tx pair
        // already used, now that there is room for it everywhere.
        let pair = |c: &mut Self, y: &mut usize, la: &str, a: String, lb: &str, b: String| {
            c.grid.text(x0, *y, &format!("{la} {a}"), dim);
            c.grid.text(x0 + inner / 2, *y, &format!("{lb} {b}"), dim);
            *y += 1;
        };

        small(self, &mut y, "CPU", format!("{}%", g.cpu));
        self.grid.text(x0, y, &format!("load {:.2} {:.2} {:.2}",
                                       g.load.0, g.load.1, g.load.2), line);
        y += 2;

        if g.mem_total > 0 {
            small(self, &mut y, "MEM", format!("{} / {}",
                nulllinux::sysinfo::si(g.mem_used), nulllinux::sysinfo::si(g.mem_total)));
        }
        if g.swap_total > 0 {
            small(self, &mut y, "SWAP", format!("{} / {}",
                nulllinux::sysinfo::si(g.swap_used), nulllinux::sysinfo::si(g.swap_total)));
        }
        if g.disk_total > 0 {
            small(self, &mut y, "DISK", format!("{} / {}",
                nulllinux::sysinfo::si(g.disk_used), nulllinux::sysinfo::si(g.disk_total)));
        }
        y += 1;

        small(self, &mut y, "NET", format!("{}/s", nulllinux::sysinfo::si(g.rx_rate + g.tx_rate)));
        pair(self, &mut y, "rx", format!("{:>7}/s", nulllinux::sysinfo::si(g.rx_rate)),
                           "tx", format!("{:>7}/s", nulllinux::sysinfo::si(g.tx_rate)));
        small(self, &mut y, "IO", format!("{}/s", nulllinux::sysinfo::si(g.io_r + g.io_w)));
        pair(self, &mut y, "r ", format!("{:>7}/s", nulllinux::sysinfo::si(g.io_r)),
                           "w ", format!("{:>7}/s", nulllinux::sysinfo::si(g.io_w)));
        y += 1;

        // TEMP sits with the other single readings now rather than above
        // them, because without a graph there is nothing to put it beside.
        if let Some(t) = g.temp { small(self, &mut y, "TEMP", format!("{t}°C")); }
        if let Some((iface, q)) = &g.net {
            // The cap is the room that is actually there, not ten -- ten was
            // sized for "wlp0s20f3" and cut "BRSK-863077" to "BRSK-86307",
            // which is not this network's name and is not any network's name.
            let tail = format!(" {q}%");
            let room = inner.saturating_sub(4 + 1 + tail.chars().count());
            let name: String = iface.chars().take(room).collect();
            small(self, &mut y, "LINK", format!("{name}{tail}"));
        }
        if let Some((pct, charging, secs)) = g.batt {
            // The percentage is the number the hardware reports; the TIME is
            // the number a person actually wants, and it was missing. It
            // appears only when the battery is moving -- on the mains at 100%
            // there is no rate to divide by and nothing honest to say.
            let eta = match secs {
                Some(t) => format!(" {}:{:02}", t / 3600, (t % 3600) / 60),
                None => String::new(),
            };
            small(self, &mut y, "BATT",
                  format!("{}%{}{}", pct, if charging { " +" } else { "" }, eta));
        }
        let (d, hh, mm) = (g.up_min / 1440, (g.up_min % 1440) / 60, g.up_min % 60);
        small(self, &mut y, "UP", if d > 0 { format!("{d}d {hh:02}:{mm:02}") }
                                  else { format!("{hh:02}:{mm:02}") });

        // ---- everything below here yields to the bottom of the column ----
        //
        // The footer and the equaliser are anchored to the bottom and are a
        // FIXED size. Everything after this point varies: BUSIEST is up to
        // four rows, PLAYING appears only when something is playing. Those two
        // used to run first and take what they wanted, and the bottom drew
        // only with what was left -- so adding the temperature graph deleted
        // the equaliser, silently, and starting a track would have deleted it
        // again.
        //
        // A panel that drops a whole section to fit one more process row has
        // its priorities backwards. The reserve is taken first now, and the
        // variable sections fit inside what remains or show fewer rows.
        // ONE derivation, used by both ends.
        //
        // This reserve and the equaliser's own "do I fit" test used to be two
        // separate pieces of arithmetic about the same rows, and they drifted
        // by one: the CORES block checked for four rows and consumed five, so
        // it silently deleted the equaliser -- the identical failure the
        // reserve was introduced to fix, reintroduced within the hour by the
        // next section added above it.
        //
        // Two expressions that must agree will eventually not. Both ends now
        // read FOOTER_H, EQ_H and `limit` from here, and `limit` means exactly
        // one thing: the last row the variable sections may write on.
        let (fy, ey, bottom_from) = nulllinux::panel::bottom_reserve(rows, FOOTER_H, EQ_H);

        // What is actually eating the machine. The bar cannot show this: it
        // needs a name and two numbers per row, and it has one row.
        let room = bottom_from.saturating_sub(y + 2);
        if !self.procs.is_empty() && room > 0 {
            y += 1;
            self.grid.text(x0, y, "BUSIEST", dim);
            y += 1;
            let procs = self.procs.clone();
            for (name, share, rss, n) in procs.iter().take(room.min(4)) {
                let right = format!("{:>3.0}% {:>6}", share * 100.0, nulllinux::sysinfo::si(*rss));
                let room = inner.saturating_sub(right.chars().count() + 1);
                // The process count, when there is more than one. Without it a
                // program that is quietly forty processes looks like one
                // enormous one, and the reader has no way to tell which.
                let label = if *n > 1 { format!("{name} x{n}") } else { name.clone() };
                let short: String = label.chars().take(room).collect();
                self.grid.text(x0, y, &short, neutral);
                self.grid.text(x0 + inner.saturating_sub(right.chars().count()), y, &right, dim);
                y += 1;
            }
            y += 1;
        }

        if let Some(np) = self.now_playing.clone() {
            if y + 3 < bottom_from {
            y += 1;
            self.grid.text(x0, y, "PLAYING", dim);
            y += 1;
            // Wrapped, not truncated: a title cut at the column edge is a
            // different title.
            for chunk in np.chars().collect::<Vec<_>>().chunks(inner).take(2) {
                if y >= bottom_from { break }
                self.grid.text(x0, y, &chunk.iter().collect::<String>(), neutral);
                y += 1;
            }
            }
        }

        // How the load is SPREAD, under the list of what is causing it.
        //
        // The CPU graph at the top is the aggregate over time; this is the
        // distribution right now. One thread pinned at 100% and eight threads
        // at 12% draw the same line up there and mean entirely different
        // things, and until now the panel could not tell them apart.
        //
        // It comes LAST, after PLAYING, because it is the one thing here
        // that is equally true a second from now: a track title is transient
        // and wanted, and the spread of load can be had by looking again.
        //
        // Bars rather than a filled series, with gaps, because the axis here
        // is a LIST of cores and every other filled shape on this panel is a
        // history -- the frame says "last 26s" and that must not be read as
        // applying to this.
        // NULL_LAYOUT_DEBUG=1 prints the three numbers this decision turns on.
        // Kept because this arithmetic has now been wrong three times in both
        // directions, and each time the symptom was a section that was simply
        // not there -- which a screenshot shows and a log does not.
        if std::env::var_os("NULL_LAYOUT_DEBUG").is_some() {
            eprintln!("layout: rows={rows} y={y} bottom_from={bottom_from} cores={}",
                      self.cores.len());
        }
        // This block writes rows y+1 (label) through y+3 (the second bar row),
        // so the LAST ROW WRITTEN is y+3 and that is what must clear `limit`.
        // Asking for y+4 was the same mistake in the other direction: it left
        // a row unused and dropped the section that was meant to fill it.
        if !self.cores.is_empty() && y + 3 < bottom_from {
            y += 1;
            let busiest = self.cores.iter().cloned().fold(0.0f32, f32::max);
            self.grid.text(x0, y, "CORES", dim);
            // Just the peak. How many cores there are is visible from the
            // bars, and a count next to it read as "8 x something".
            let tail = format!("peak {:.0}%", busiest * 100.0);
            self.grid.text(x0 + inner.saturating_sub(tail.chars().count()), y, &tail, line);
            y += 1;
            let (cores, ramp2) = (self.cores.clone(), self.ramp.clone());
            nulllinux::panel::bars(&mut self.grid, x0, y, inner, 2, &cores, &ramp2, &self.pal);
            y += 2;
        }


        // ---- the bottom of the column, built upwards from the footer ----
        if fy > y + 2 {
            for x in x0..cols.saturating_sub(2) { self.grid.set(x, fy, '─', line) }
            let (menu, keys) = (self.hint_menu.clone(), self.hint_keys.clone());
            self.grid.text(x0, fy + 1, &menu, neutral);
            self.grid.text(x0, fy + 2, &keys, neutral);
            let right = cols.saturating_sub(2);
            if menu.chars().count() + 6 < right { self.grid.text(right - 5, fy + 1, "menu", dim); }
            if keys.chars().count() + 6 < right { self.grid.text(right - 5, fy + 2, "keys", dim); }
        }

        // The equaliser sits directly above that rule, tall enough to read.
        // Same `limit` the sections above yielded to, so the two cannot drift.
        let eh = EQ_H;
        if ey >= 2 && y <= bottom_from {
            self.grid.text(x0, ey - 1, "SPECTRUM", dim);
            if self.spectrum.available() && !self.spectrum.bars.is_empty() {
                let bars = self.spectrum.bars.clone();
                let maxv = self.spectrum.max.max(1) as f32;
                for (i, v) in bars.iter().take(inner).enumerate() {
                    let level = (*v as f32 / maxv).clamp(0.0, 1.0);
                    for r in 0..eh {
                        // Rows fill from the bottom; the partial row carries
                        // the remainder as ink density, like every meter here.
                        let from_bottom = (eh - 1 - r) as f32;
                        let frac = (level * eh as f32 - from_bottom).clamp(0.0, 1.0);
                        let ch = if frac <= 0.0 { '·' }
                                 else {
                                     let idx = ((frac * (ramp.len() - 1) as f32).round() as usize)
                                                   .min(ramp.len() - 1);
                                     ramp[idx]
                                 };
                        let fg = if frac <= 0.0 { line } else { self.pal.by_level(level) };
                        self.grid.set(x0 + i, ey + r, ch, fg);
                    }
                }
            } else {
                // ABSENT IS STATED. Flat bars would read as silence.
                let why = self.spectrum.reason.clone()
                    .unwrap_or_else(|| "no audio source".into());
                // Wrapped over the rows the equaliser would have used. The
                // first version truncated at the column edge, so the reason
                // read "cava exited -- is an audio" and stopped.
                let chars: Vec<char> = why.chars().collect();
                for (i, chunk) in chars.chunks(inner).take(eh).enumerate() {
                    self.grid.text(x0, ey + i, &chunk.iter().collect::<String>(), line);
                }
            }
        }
    }

    fn draw(&mut self) {
        let (line, dim, neutral) =
            (self.pal.get(Role::Line), self.pal.get(Role::Dim), self.pal.get(Role::Neutral));
        self.grid.clear();
        // Draw at the grid's own size -- the size the compositor confirmed --
        // not at the animation's current target.
        let (cols, rows) = (self.grid.cols, self.grid.rows);

        // The frame. Square corners for a persistent surface (§7.1).
        for x in 0..cols { self.grid.set(x, 0, '─', line); self.grid.set(x, rows - 1, '─', line) }
        for y in 0..rows { self.grid.set(0, y, '│', line); self.grid.set(cols - 1, y, '│', line) }
        self.grid.set(0, 0, '┌', line);
        self.grid.set(cols - 1, 0, '┐', line);
        self.grid.set(0, rows - 1, '└', line);
        self.grid.set(cols - 1, rows - 1, '┘', line);

        let label = match self.host.as_ref() {
            Some(h) => h.label.to_uppercase(),
            None => "COLUMN".into(),
        };
        self.grid.text(2, 0, &format!(" {label} "), dim);
        if self.pinned {
            // The same glyph the wifi list draws for a secured network,
            // because "locked" is the same word. A second glyph would be a
            // second name for one idea.
            self.grid.set(cols.saturating_sub(3), 0, '*', neutral);
        }

        if let Some(h) = self.host.as_ref() {
            for y in 0..h.vt.rows.min(rows.saturating_sub(2)) {
                for x in 0..h.vt.cols.min(cols.saturating_sub(2)) {
                    let c = h.vt.cell(x, y);
                    let fg = c.attrs.fg.unwrap_or(neutral);
                    // The background comes through too. Without it a program
                    // that marks its selection by inverting it marks nothing.
                    self.grid.set_full(x + 1, y + 1,
                        Cell { ch: c.ch, fg, bg: c.attrs.bg, bold: c.attrs.bold });
                }
            }
        } else {
            self.draw_glance(cols, rows);
        }

        if self.slots.is_empty() {
            let stride = self.px_w as i32 * 4;
            for _ in 0..2 {
                if let Ok((buffer, canvas)) = self.pool.create_buffer(
                    self.px_w as i32, self.px_h as i32, stride, wl_shm::Format::Argb8888) {
                    self.grid.fill(canvas);
                    self.slots.push(Slot { buffer, gen: 0 });
                }
            }
        }
        let n = self.slots.len();
        if n == 0 { return }
        let mut chosen = None;
        for k in 0..n {
            let i = (self.next_slot + k) % n;
            if self.slots[i].buffer.canvas(&mut self.pool).is_some() { chosen = Some(i); break }
        }
        let Some(i) = chosen else { return };
        self.next_slot = (i + 1) % n;

        let target = self.slots[i].gen;
        let cur = self.grid.generation;
        let stride_px = self.px_w as usize;
        let canvas = self.slots[i].buffer.canvas(&mut self.pool).unwrap();
        self.grid.blit(&self.atlas, canvas, stride_px, target, self.bold.as_ref());
        self.slots[i].gen = cur;

        let Some(layer) = self.layer.as_ref() else { return };
        let surface = layer.wl_surface().clone();
        surface.damage_buffer(0, 0, self.px_w as i32, self.px_h as i32);
        let _ = self.slots[i].buffer.attach_to(&surface);
        layer.commit();
        self.mapped = true;
        self.draws += 1;
    }
}

fn encode(ev: &KeyEvent, mods: &Modifiers) -> Option<Vec<u8>> {
    // Any chord carrying the compositor's modifier is dropped, so that if the
    // compositor ever stopped eating its own bindings first, SUPER+1 could not
    // type a 1 into a hosted program (§7.3).
    if mods.logo { return None }
    match ev.keysym {
        Keysym::Return | Keysym::KP_Enter => Some(b"\r".to_vec()),
        // 0x7f, not 0x08. The oldest disagreement in terminals, settled by
        // what the programs read: every modern terminfo says kbs=\177, and
        // sending 0x08 leaves a filter you cannot clear.
        Keysym::BackSpace => Some(vec![0x7f]),
        Keysym::Tab => Some(b"\t".to_vec()),
        Keysym::Escape => Some(vec![0x1b]),
        Keysym::Up => Some(b"\x1b[A".to_vec()),
        Keysym::Down => Some(b"\x1b[B".to_vec()),
        Keysym::Right => Some(b"\x1b[C".to_vec()),
        Keysym::Left => Some(b"\x1b[D".to_vec()),
        Keysym::Home => Some(b"\x1b[H".to_vec()),
        Keysym::End => Some(b"\x1b[F".to_vec()),
        Keysym::Page_Up => Some(b"\x1b[5~".to_vec()),
        Keysym::Page_Down => Some(b"\x1b[6~".to_vec()),
        Keysym::Delete => Some(b"\x1b[3~".to_vec()),
        _ => {
            if let Some(t) = &ev.utf8 {
                if mods.ctrl {
                    let c = t.bytes().next()?;
                    if c.is_ascii_alphabetic() { return Some(vec![c.to_ascii_uppercase() - 64]) }
                }
                if !t.is_empty() { return Some(t.as_bytes().to_vec()) }
            }
            None
        }
    }
}

impl KeyboardHandler for Column {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
             _: &wl_surface::WlSurface, _: u32, _: &[u32], _: &[Keysym]) {}
    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
             _: &wl_surface::WlSurface, _: u32) { self.repeat = None }
    fn press_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
                 _: u32, event: KeyEvent) {
        let mods = Modifiers::default();
        if let Some(bytes) = encode(&event, &mods) {
            if let Some(h) = self.host.as_ref() { let _ = h.pty.write(&bytes); }
            self.repeat = Some((bytes, Instant::now() + self.repeat_delay, self.repeat_rate));
        }
    }
    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
                   _: u32, _: KeyEvent) { self.repeat = None }
    fn update_modifiers(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard,
                        _: u32, _: Modifiers, _: u32) {}
}

impl SeatHandler for Column {
    fn seat_state(&mut self) -> &mut SeatState { &mut self.seat_state }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(&mut self, _: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat,
                      cap: Capability) {
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = self.seat_state.get_keyboard(qh, &seat, None).ok();
        }
    }
    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat,
                         cap: Capability) {
        if cap == Capability::Keyboard {
            if let Some(k) = self.keyboard.take() { k.release() }
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl CompositorHandler for Column {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {}
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl LayerShellHandler for Column {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) { self.exit = true }
    fn configure(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface,
                 cfg: LayerSurfaceConfigure, _: u32) {
        if cfg.new_size.0 != 0 { self.px_w = cfg.new_size.0 }
        if cfg.new_size.1 != 0 { self.px_h = cfg.new_size.1 }
        self.rows = (self.px_h as usize / self.atlas.cell_h).max(3);

        // Accept the size the compositor gives, whatever it is, and draw at
        // THAT rather than at the animation's current target.
        //
        // Gating the draw on an exact match with self.cols deadlocks the
        // moment the width is animated: each step requests a new size, the
        // next step requests another before the previous configure lands, the
        // match never holds, and the surface animates its geometry while never
        // drawing a frame -- so it never maps and never reappears. The
        // animation REQUESTS sizes; the draw FOLLOWS configures.
        let cfg_cols = (self.px_w as usize / self.atlas.cell_w).max(1);
        if self.grid.cols != cfg_cols || self.grid.rows != self.rows {
            self.grid = TextGrid::new(cfg_cols, self.rows, self.pal.get(Role::Background));
            self.slots.clear();
        }
        self.awaiting_configure = false;
        self.content_dirty = true;
        if std::env::var_os("COLUMN_STATS").is_some() {
            eprintln!("configure: px={}x{} grid_cols={} anim_cols={}",
                      self.px_w, self.px_h, cfg_cols, self.cols);
        }
        if !self.configured {
            self.configured = true;
            self.grid = TextGrid::new(self.cols, self.rows, self.pal.get(Role::Background));
        }
    }
}

impl OutputHandler for Column {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl ShmHandler for Column { fn shm_state(&mut self) -> &mut Shm { &mut self.shm } }
impl ProvidesRegistryState for Column {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState, SeatState];
}
delegate_compositor!(Column);
delegate_output!(Column);
delegate_shm!(Column);
delegate_layer!(Column);
delegate_seat!(Column);
delegate_keyboard!(Column);
delegate_registry!(Column);
