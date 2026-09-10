//! The bar (NULL.md §7.2).
//!
//! A persistent strip, drawn by this system's own renderer rather than by a
//! bar toolkit. The reason is measurable, not aesthetic: a general-purpose
//! toolkit brings its own text stack and its own cell metrics, and puts a
//! second grid on screen.
//!
//! ONE SLEEP, EVERY SOURCE. There is no polling loop. A single poll waits on
//! the compositor connection, the compositor's event stream, and the next
//! second boundary; cheap readings are taken on a wakeup that is happening
//! anyway.

use nulllinux::atlas::Atlas;
use nulllinux::grid::TextGrid;
use nulllinux::palette::{Palette, Role};
use nulllinux::panel::{self, UNMEASURED};
use nulllinux::sysinfo::{self, CpuSampler};

use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_layer, delegate_output, delegate_registry, delegate_shm,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    shell::{
        wlr_layer::{Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler,
                    LayerSurface, LayerSurfaceConfigure},
        WaylandSurface,
    },
    shm::{slot::{Buffer, SlotPool}, Shm, ShmHandler},
};
use std::os::fd::{AsFd, AsRawFd};
use std::time::{SystemTime, UNIX_EPOCH};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_shm, wl_surface},
    Connection, QueueHandle,
};

const ROWS: usize = 2;

struct Slot { buffer: Buffer, gen: u64 }

struct Bar {
    registry_state: RegistryState,
    output_state: OutputState,
    shm: Shm,
    pool: SlotPool,
    layer: LayerSurface,

    atlas: Atlas,
    pal: Palette,
    ramp: Vec<char>,
    grid: TextGrid,

    px_w: u32,
    px_h: u32,
    configured: bool,
    exit: bool,
    slots: Vec<Slot>,
    next_slot: usize,

    cpu: CpuSampler,
    cpu_trail: Vec<f32>,
    workspaces: String,
    window_title: String,

    pub draws: u64,
    pub rows_copied: u64,
}

/// The repository root, derived from THIS executable's own location.
///
/// Not a literal. A hard-coded "/root/nulllinux" is an install location baked into
/// a binary, so moving the checkout -- which is exactly what moving the
/// session off root requires -- silently pointed every hosted command at a
/// directory that was no longer readable. The binary lives at
/// <root>/render/target/release/<name>, so the root is four levels up.
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
    // --atlas / --ramp OVERRIDE THE INSTALLED PAIR, so one bar per screen can
    // each be given the strike that suits that screen. A 4K monitor beside a
    // 1366x768 laptop wants different sized text on each, and a single
    // installed atlas can only be right for one of them.
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let opt = |n: &str| argv.iter().position(|a| a == n).and_then(|i| argv.get(i + 1)).cloned();
    let atlas_path = opt("--atlas").unwrap_or_else(|| format!("{root}/assets/atlas-interface.bin"));
    let ramp_path  = opt("--ramp").unwrap_or_else(|| format!("{root}/assets/ramp-interface.json"));

    let atlas = Atlas::load(&atlas_path)
        .unwrap_or_else(|e| { eprintln!("bar: {e}"); std::process::exit(1) });
    let pal = Palette::load(&format!("{root}/assets/palette.json"))
        .unwrap_or_else(|e| { eprintln!("bar: {e}"); std::process::exit(1) });
    let ramp: Vec<char> = std::fs::read_to_string(&ramp_path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get("ramp").and_then(|r| r.as_str()).map(|s| s.chars().collect()))
        .unwrap_or_else(|| " .:-=+*#%@".chars().collect());

    // --print draws the layout to stdout and exits: the surface can be
    // inspected without a compositor, which is what makes a width regression
    // visible in a test rather than only on screen.
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(i) = args.iter().position(|a| a == "--print") {
        let cols: usize = args.get(i + 1).and_then(|s| s.parse().ok()).unwrap_or(192);
        let mut g = TextGrid::new(cols, ROWS, pal.get(Role::Background));
        let mut cpu = CpuSampler::new();
        cpu.sample();
        // A CPU fraction needs two samples. Without the pause the second lands
        // in the same jiffy, the delta is zero, and the row honestly reports
        // "no reading" -- correct, but not what --print is for.
        std::thread::sleep(std::time::Duration::from_millis(120));
        draw_into(&mut g, &pal, &ramp, &mut cpu, &mut Vec::new(), "1", "(no window)");
        for y in 0..ROWS {
            let mut line = String::new();
            for x in 0..cols {
                line.push(g_char(&g, x, y));
            }
            // NOT trimmed: every row of a fixed-width surface must be exactly
            // the surface width, and trimming would hide a short row (§10.4).
            println!("{}", line);
        }
        return;
    }

    let conn = Connection::connect_to_env().expect("no Wayland display");
    let (globals, mut queue) = registry_queue_init(&conn).expect("registry");
    let qh = queue.handle();
    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("wlr-layer-shell");
    let shm = Shm::bind(&globals, &qh).expect("wl_shm");

    // THE COMPOSITOR KNOWS HOW WIDE THE SCREEN IS; THIS DID NOT.
    //
    // This read `1920 / atlas.cell_w` -- the width of the panel on the machine
    // the project was written on. The surface is anchored LEFT and RIGHT, so
    // the compositor will give it the full output width for the asking, and
    // asking is passing 0: a layer surface that is anchored to opposite edges
    // and requests 0 on that axis is told what the real extent is.
    //
    // On a 2560-wide screen the bar was 1920 wide and the remaining 640 px was
    // bare background -- on every machine that is not this one.
    let px_h = (ROWS * atlas.cell_h) as u32;
    // A provisional grid, replaced the moment the first configure arrives with
    // the true width. It is never drawn at this size.
    let cols = 1;

    let surface = compositor.create_surface(&qh);
    // PINNED when `--output NAME` is given. `None` means "compositor, you
    // choose", which is right with one monitor and wrong with two: every bar
    // lands on the same screen and the others get none. One bar per output.
    let want = args.iter().position(|a| a == "--output").and_then(|i| args.get(i + 1)).cloned();
    let wl_out = match want.as_deref() {
        Some(n) => match nulllinux::outputs::find_output(&conn, n) {
            Ok(o) => Some(o),
            Err(e) => { eprintln!("bar: {e}"); std::process::exit(1) }
        },
        None => None,
    };
    let layer = layer_shell.create_layer_surface(&qh, surface, Layer::Top, Some("null-bar"), wl_out.as_ref());
    layer.set_anchor(Anchor::TOP | Anchor::LEFT | Anchor::RIGHT);
    layer.set_exclusive_zone(px_h as i32);
    layer.set_keyboard_interactivity(KeyboardInteractivity::None);
    layer.set_size(0, px_h);   // 0 = "you tell me", see above
    layer.commit();

    // Sized on the first configure, once the width is known.
    let pool = SlotPool::new((px_h * 4) as usize, &shm).expect("pool");
    let grid = TextGrid::new(cols, ROWS, pal.get(Role::Background));

    let mut bar = Bar {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        shm, pool, layer, atlas, pal, ramp, grid,
        px_w: 0, px_h, configured: false, exit: false,
        slots: Vec::new(), next_slot: 0,
        cpu: CpuSampler::new(), cpu_trail: Vec::new(),
        workspaces: String::from("1"), window_title: String::new(),
        draws: 0, rows_copied: 0,
    };
    bar.cpu.sample();

    // The compositor's event stream, as a descriptor we can wait on alongside
    // the Wayland connection -- not a thread, and not a poll of our own.
    let mut ipc_ev = nulllinux::ipc::subscribe_stream();

    // The surface redraws when something CHANGES, not on every wakeup. The
    // poll returns as soon as the compositor replies to our own commit, so
    // redrawing unconditionally spins the surface at refresh rate for a
    // readout that moves once a second -- measured at ~74 draws/s before this,
    // which is the exact cost §7.2 exists to prevent.
    let mut last_second = u64::MAX;
    let mut dirty = true;

    loop {
        let now_s = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        if now_s != last_second { last_second = now_s; dirty = true }
        if dirty {
            queue.flush().ok();
            bar.redraw(&qh);
            dirty = false;
        }
        queue.flush().ok();

        let read_guard = queue.prepare_read();
        let wl_fd = conn.as_fd().as_raw_fd();
        let ipc_fd = ipc_ev.as_ref().map(|s| s.as_raw_fd()).unwrap_or(-1);

        // ONE sleep. Its timeout is the next second boundary, so the clock is
        // not a separate timer and nothing polls.
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let ms_to_second = 1000 - (now.subsec_millis() as i32);

        let mut fds = vec![libc::pollfd { fd: wl_fd, events: libc::POLLIN, revents: 0 }];
        if ipc_fd >= 0 {
            fds.push(libc::pollfd { fd: ipc_fd, events: libc::POLLIN, revents: 0 });
        }
        unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, ms_to_second) };

        let mut lost = fds[0].revents & (libc::POLLHUP | libc::POLLERR) != 0;
        if let Some(g) = read_guard {
            if fds[0].revents & libc::POLLIN != 0 && g.read().is_err() { lost = true }
        }
        if queue.dispatch_pending(&mut bar).is_err() { lost = true }
        if lost { break }

        // Any descriptor added to a wait set needs an end-of-file check. A
        // descriptor whose writer has exited reports ready on EVERY call, the
        // timeout stops applying, and the surface spins at 100% of a core --
        // the most expensive defect class in an event-driven surface, with no
        // symptom other than heat (§7.2).
        if fds.len() > 1 && fds[1].revents & (libc::POLLHUP | libc::POLLERR) != 0 {
            ipc_ev = None;
        } else if fds.len() > 1 && fds[1].revents & libc::POLLIN != 0 {
            if let Some(s) = ipc_ev.as_mut() {
                if nulllinux::ipc::drain_event(s).is_none() { ipc_ev = None }
                else { bar.refresh_compositor_state(); dirty = true }
            }
        }
        if bar.exit { break }
    }
}

fn g_char(g: &TextGrid, x: usize, y: usize) -> char {
    // --print is a debugging view of the same grid the surface draws.
    g.char_at(x, y)
}

fn draw_into(g: &mut TextGrid, pal: &Palette, ramp: &[char], cpu: &mut CpuSampler,
             trail: &mut Vec<f32>, workspaces: &str, title: &str) {
    g.clear();
    let cols = g.cols;

    // Sections, in DROP ORDER: when the surface is too narrow for everything,
    // whole readouts are dropped rather than clipped (§10.4). A half-drawn
    // section reads as a surface that failed, not as one that adapted. WINDOW
    // is elastic and absorbs whatever is left over.
    //
    // The order is a judgement and it is written down rather than implied:
    // which workspace you are on and what time it is survive longest, then the
    // battery, because those are the readings you look for when the machine is
    // behaving oddly.
    const FIXED: &[(&str, usize)] = &[
        ("WORKSPACES", 14), ("CLOCK", 24), ("BATTERY", 12),
        ("CPU", 16), ("MEM", 16), ("TEMP", 12), ("NET", 10),
    ];
    const DISPLAY_ORDER: &[&str] = &[
        "WORKSPACES", "WINDOW", "CLOCK", "CPU", "MEM", "TEMP", "NET", "BATTERY",
    ];
    const MIN_WINDOW: usize = 12;

    let mut keep: Vec<&str> = FIXED.iter().map(|(n, _)| *n).collect();
    let width_of = |n: &str| FIXED.iter().find(|(f, _)| *f == n).map(|(_, w)| *w).unwrap_or(0);
    // Drop from the END of FIXED, which is the least-important first.
    while !keep.is_empty()
        && keep.iter().map(|n| width_of(n)).sum::<usize>() + MIN_WINDOW > cols {
        keep.pop();
    }

    let mut widths: Vec<(&str, usize)> = Vec::new();
    for name in DISPLAY_ORDER {
        if *name == "WINDOW" {
            let used: usize = keep.iter().map(|n| width_of(n)).sum();
            widths.push(("WINDOW", cols.saturating_sub(used).max(MIN_WINDOW)));
        } else if keep.contains(name) {
            widths.push((name, width_of(name)));
        }
    }

    let mut starts: Vec<(usize, &str, usize)> = Vec::new();
    let mut x = 0usize;
    for (name, w) in widths.iter() {
        if x >= cols { break }
        let w = (*w).min(cols - x);
        starts.push((x, *name, w));
        x += w;
    }

    let sections: Vec<(usize, &str)> = starts.iter().map(|(x, n, _)| (*x, *n)).collect();
    panel::rule_with_labels(g, 0, cols, &sections, pal);

    let neutral = pal.get(Role::Neutral);
    let dim = pal.get(Role::Dim);

    for (x0, name, w) in starts {
        let inner = w.saturating_sub(2);
        let x1 = x0 + 1;
        match name {
            "WORKSPACES" => { g.text(x1, 1, workspaces, pal.get(Role::Accent)); }
            "WINDOW" => {
                let t = if title.is_empty() { UNMEASURED } else { title };
                let t: String = t.chars().take(inner).collect();
                g.text(x1, 1, &t, neutral);
            }
            "CLOCK" => {
                // LOCAL time, via libc::localtime_r, so the clock honours the
                // system timezone and DST. The old code took the civil date and
                // h:m:s straight from the epoch -- i.e. UTC -- so on a machine an
                // hour off UTC (BST) the bar read an hour behind, which looks
                // exactly like a stale clock.
                let now = SystemTime::now().duration_since(UNIX_EPOCH)
                    .unwrap_or_default().as_secs() as libc::time_t;
                let mut tm: libc::tm = unsafe { std::mem::zeroed() };
                let txt = if unsafe { !libc::localtime_r(&now, &mut tm).is_null() } {
                    format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
                            tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                            tm.tm_hour, tm.tm_min, tm.tm_sec)
                } else {
                    String::from("--:--:--")
                };
                g.text(x1, 1, &txt, neutral);
            }
            "CPU" => {
                let v = cpu.sample();
                if let Some(v) = v {
                    trail.push(v);
                    if trail.len() > 8 { trail.remove(0); }
                }
                match v {
                    Some(v) => {
                        panel::meter(g, x1, 1, inner.saturating_sub(5), v, ramp, pal);
                        g.text(x0 + w - 5, 1, &format!("{:>3.0}%", v * 100.0), pal.by_level(v));
                    }
                    None => { g.text(x1, 1, UNMEASURED, dim); }
                }
            }
            "MEM" => match sysinfo::memory() {
                Some((used, total)) => {
                    let f = used as f32 / total as f32;
                    panel::meter(g, x1, 1, inner.saturating_sub(8), f, ramp, pal);
                    g.text(x0 + w - 8, 1, &format!("{:>8}", sysinfo::si(used)), pal.by_level(f));
                }
                None => { g.text(x1, 1, UNMEASURED, dim); }
            },
            "TEMP" => match sysinfo::temperature() {
                Some(c) => {
                    let f = ((c - 30.0) / 60.0).clamp(0.0, 1.0);
                    g.text(x1, 1, &format!("{c:.0}°C"), pal.by_level(f));
                }
                None => { g.text(x1, 1, UNMEASURED, dim); }
            },
            "NET" => match sysinfo::wireless_quality_cached() {
                Some(q) => {
                    panel::meter(g, x1, 1, inner.saturating_sub(5), q, ramp, pal);
                    g.text(x0 + w - 5, 1, &format!("{:>3.0}%", q * 100.0), pal.by_level(q));
                }
                // Absent hardware is not drawn as zero (§8.4).
                None => { g.text(x1, 1, UNMEASURED, dim); }
            },
            "BATTERY" => match sysinfo::battery() {
                Some(b) => {
                    let f = b.percent as f32 / 100.0;
                    // A charging battery gets its own role rather than
                    // "whatever level it happens to be at" (§4.6).
                    let fg = if b.charging { pal.get(Role::Accent) } else { pal.by_level(f) };
                    panel::meter(g, x1, 1, inner.saturating_sub(5), f, ramp, pal);
                    g.text(x0 + w - 5, 1, &format!("{:>3}%", b.percent), fg);
                }
                None => { g.text(x1, 1, UNMEASURED, dim); }
            },
            _ => {}
        }
    }
}

impl Bar {
    fn refresh_compositor_state(&mut self) {
        if let Some((ws, title)) = nulllinux::ipc::workspaces_and_title() {
            self.workspaces = ws;
            self.window_title = title;
        }
    }

    fn redraw(&mut self, qh: &QueueHandle<Bar>) {
        if !self.configured { return }
        let (pal, ramp) = (&self.pal, self.ramp.clone());
        let ws = self.workspaces.clone();
        let title = self.window_title.clone();
        draw_into(&mut self.grid, pal, &ramp, &mut self.cpu, &mut self.cpu_trail, &ws, &title);

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

        let target_gen = self.slots[i].gen;
        let stride_px = self.px_w as usize;
        let cur_gen = self.grid.generation;
        let canvas = self.slots[i].buffer.canvas(&mut self.pool).unwrap();
        let copied = self.grid.blit(&self.atlas, canvas, stride_px, target_gen, None);
        self.slots[i].gen = cur_gen;

        let surface = self.layer.wl_surface().clone();
        surface.damage_buffer(0, 0, self.px_w as i32, self.px_h as i32);
        let _ = self.slots[i].buffer.attach_to(&surface);
        self.layer.commit();
        self.draws += 1;
        self.rows_copied += copied as u64;
        if std::env::var_os("BAR_STATS").is_some() && self.draws % 10 == 0 {
            eprintln!("draws={} rows_copied={} (of {} per draw)",
                      self.draws, self.rows_copied, ROWS);
        }
        let _ = qh;
    }
}

impl CompositorHandler for Bar {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {}
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl LayerShellHandler for Bar {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) { self.exit = true }
    fn configure(&mut self, _: &Connection, _qh: &QueueHandle<Self>, _: &LayerSurface,
                 cfg: LayerSurfaceConfigure, _: u32) {
        let was = (self.px_w, self.px_h);
        if cfg.new_size.0 != 0 { self.px_w = cfg.new_size.0 }
        if cfg.new_size.1 != 0 { self.px_h = cfg.new_size.1 }
        // REBUILD THE GRID WHEN THE WIDTH CHANGES, not only at startup. The
        // width arriving is the whole point of asking for 0, and a monitor
        // that is swapped or re-moded sends another configure.
        if (self.px_w, self.px_h) != was && self.px_w != 0 {
            let cols = (self.px_w as usize / self.atlas.cell_w).max(1);
            self.grid = TextGrid::new(cols, ROWS, self.pal.get(Role::Background));
            self.slots.clear();
            self.next_slot = 0;
        }
        if !self.configured {
            self.configured = true;
            self.refresh_compositor_state();
        }
    }
}

impl OutputHandler for Bar {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl ShmHandler for Bar { fn shm_state(&mut self) -> &mut Shm { &mut self.shm } }
impl ProvidesRegistryState for Bar {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState];
}
delegate_compositor!(Bar);
delegate_output!(Bar);
delegate_shm!(Bar);
delegate_layer!(Bar);
delegate_registry!(Bar);
