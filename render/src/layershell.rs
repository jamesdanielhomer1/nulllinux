//! The compositor surface backend (NULL.md §6.3, §6.4).
//!
//! Owns its buffer at native resolution. Blits only changed cells. Suspends
//! when occluded, stops when the output powers off, and halves its rate on
//! battery.

use crate::atlas::Atlas;
use crate::cells::Cells;
use crate::ipc;
use crate::raster;
use nulllinux::outputs::find_output;

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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_shm, wl_surface},
    Connection, QueueHandle,
};

/// One shm slot, and the planes its pixels currently show.
///
/// Two slots are cycled by hand. A pool holding exactly one buffer must grow
/// it on every frame while the compositor still holds the previous one (§6.3).
struct Slot {
    buffer: Buffer,
    shows: Option<(Vec<u8>, Vec<u8>)>,
}

pub struct Wallpaper {
    registry_state: RegistryState,
    output_state: OutputState,
    shm: Shm,
    pool: SlotPool,
    layer: LayerSurface,

    cells: Cells,
    atlas: Atlas,

    width: u32,
    height: u32,
    configured: bool,
    exit: bool,

    slots: Vec<Slot>,
    next_slot: usize,

    occluded: Arc<AtomicBool>,
    force_animate: bool,
    start: Instant,
    last_frame_index: Option<usize>,

    pub drawn: u64,
    pub cells_blitted: u64,
    pub skipped_occluded: u64,
}

pub fn run(cells: Cells, atlas: Atlas, layer_name: &str, overlay: bool,
           force_animate: bool, output_name: Option<&str>) -> Result<(), String> {
    let conn = Connection::connect_to_env().map_err(|e| format!("no Wayland display: {e}"))?;
    let (globals, mut queue) = registry_queue_init(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();

    let compositor = CompositorState::bind(&globals, &qh).map_err(|e| format!("wl_compositor: {e}"))?;
    let layer_shell = LayerShell::bind(&globals, &qh).map_err(|e| format!("wlr-layer-shell: {e}"))?;
    let shm = Shm::bind(&globals, &qh).map_err(|e| format!("wl_shm: {e}"))?;

    let w = cells.cols as u32 * atlas.cell_w as u32;
    let h = cells.rows as u32 * atlas.cell_h as u32;

    let surface = compositor.create_surface(&qh);
    let lyr = if overlay { Layer::Overlay } else { Layer::Background };
    // Pinned to ONE named output when asked. One process per screen is what
    // makes several screens work at once, and what lets each of them be given
    // the assets that fit it.
    let wl_out = match output_name {
        Some(n) => Some(find_output(&conn, n)?),
        None => None,
    };
    let layer = layer_shell.create_layer_surface(&qh, surface, lyr, Some(layer_name), wl_out.as_ref());
    layer.set_anchor(Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT);
    layer.set_exclusive_zone(-1);
    layer.set_keyboard_interactivity(KeyboardInteractivity::None);
    layer.set_size(w, h);
    layer.commit();

    // Room for two full buffers, by design (§6.3).
    let pool = SlotPool::new((w * h * 4 * 2) as usize, &shm).map_err(|e| e.to_string())?;

    let occluded = Arc::new(AtomicBool::new(false));
    // An overlay sits ABOVE every window, so what covers the background says
    // nothing about what covers it. Reusing the wallpaper's occlusion logic on
    // an overlay freezes it on every workspace that has a window open, which is
    // nearly all of them -- so the overlay layer IMPLIES forced animation,
    // decided here rather than left to whoever writes the command line (§8.6).
    let force_animate = force_animate || overlay;
    if !force_animate && !ipc::spawn_occlusion_watch(occluded.clone()) {
        eprintln!("render: no compositor socket -- cannot detect occlusion, animating always");
    }

    let mut wp = Wallpaper {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        shm, pool, layer,
        cells, atlas,
        width: w, height: h,
        configured: false, exit: false,
        slots: Vec::new(), next_slot: 0,
        occluded, force_animate,
        start: Instant::now(),
        last_frame_index: None,
        drawn: 0, cells_blitted: 0, skipped_occluded: 0,
    };

    loop {
        queue.blocking_dispatch(&mut wp).map_err(|e| e.to_string())?;
        if wp.exit { break }
    }
    Ok(())
}

impl Wallpaper {
    fn target_fps(&self) -> u32 {
        // Drop the rate on battery. 12 divides 240, so the loop still closes.
        if ipc::on_battery() { (self.cells.fps as u32 / 2).max(1) } else { self.cells.fps as u32 }
    }

    fn ensure_slots(&mut self) {
        if !self.slots.is_empty() { return }
        let stride = self.width as i32 * 4;
        for _ in 0..2 {
            if let Ok((buffer, _)) = self.pool.create_buffer(
                self.width as i32, self.height as i32, stride, wl_shm::Format::Argb8888) {
                self.slots.push(Slot { buffer, shows: None });
            }
        }
    }

    fn draw(&mut self, qh: &QueueHandle<Self>) {
        self.ensure_slots();
        if self.slots.is_empty() { return }

        let surface = self.layer.wl_surface().clone();

        // Occluded: request another callback but do NOT draw -- throttled
        // rather than spun on (§6.4).
        // A verification affordance, not a setting. §10.7 requires the state
        // being measured to be FORCED: a measurement that depends on what the
        // desktop happened to be doing is not a measurement, and a workspace
        // emptying mid-sample silently changes what was measured.
        let assume_occluded = std::env::var_os("RENDER_ASSUME_OCCLUDED").is_some();
        // The FIRST frame is drawn unconditionally, even when occluded.
        //
        // A layer surface that has never had a buffer attached is NOT MAPPED,
        // and an unmapped surface receives no frame callbacks -- so a surface
        // that suspends before its first draw asks for a callback that can
        // never arrive, and never runs again. Started while a window happened
        // to be visible it drew nothing, for ever, while the same binary
        // started on a bare workspace worked: the difference was only WHEN it
        // started, which is the worst kind of difference to debug.
        //
        // Mapping first costs one frame and is what makes the suspend path
        // reachable at all.
        if self.drawn > 0
            && (assume_occluded || (!self.force_animate && self.occluded.load(Ordering::Relaxed))) {
            self.skipped_occluded += 1;
            if std::env::var_os("RENDER_STATS").is_some() && self.skipped_occluded % 10 == 1 {
                eprintln!("occluded: suspended, skipped={} drawn={}",
                          self.skipped_occluded, self.drawn);
            }
            std::thread::sleep(Duration::from_millis(100));
            surface.frame(qh, surface.clone());
            self.layer.commit();
            return;
        }

        let fps = self.target_fps();
        let period = self.cells.frames as f64 / self.cells.fps as f64;
        let t = self.start.elapsed().as_secs_f64() % period;
        let idx = ((t * fps as f64) as usize * (self.cells.fps as usize / fps as usize))
            .min(self.cells.frames as usize - 1);

        if self.last_frame_index == Some(idx) {
            surface.frame(qh, surface.clone());
            self.layer.commit();
            std::thread::sleep(Duration::from_millis(1000 / (fps as u64 * 2).max(1)));
            return;
        }

        // Find a slot the compositor is not holding. `canvas` refusing a held
        // slot is exactly what makes the two-slot cycle safe.
        let n = self.slots.len();
        let mut chosen = None;
        for k in 0..n {
            let i = (self.next_slot + k) % n;
            if self.slots[i].buffer.canvas(&mut self.pool).is_some() { chosen = Some(i); break }
        }
        let Some(i) = chosen else {
            surface.frame(qh, surface.clone());
            self.layer.commit();
            return;
        };
        self.next_slot = (i + 1) % n;

        let g = self.cells.glyphs(idx).to_vec();
        let c = self.cells.colours(idx).to_vec();
        let prev = self.slots[i].shows.clone();
        let stride_px = self.width as usize;

        let canvas = self.slots[i].buffer.canvas(&mut self.pool).unwrap();
        let touched = raster::blit_frame(
            &self.cells, &self.atlas, idx, canvas, stride_px,
            prev.as_ref().map(|(pg, pc)| (pg.as_slice(), pc.as_slice())),
        );
        self.slots[i].shows = Some((g, c));

        surface.damage_buffer(0, 0, self.width as i32, self.height as i32);
        surface.frame(qh, surface.clone());
        // attach_to, never surface.attach(buffer.wl_buffer()): only attach_to
        // marks the Buffer active, and an inactive Buffer destroys its
        // wl_buffer when it drops -- at the end of the very function that
        // committed it, before the compositor reads a pixel (§6.3).
        let _ = self.slots[i].buffer.attach_to(&surface);
        self.layer.commit();

        self.drawn += 1;
        self.cells_blitted += touched as u64;
        self.last_frame_index = Some(idx);
        if std::env::var_os("RENDER_STATS").is_some() && self.drawn % 24 == 0 {
            eprintln!("draws={} cells_blitted={} skipped_occluded={} size={}x{}",
                      self.drawn, self.cells_blitted, self.skipped_occluded,
                      self.width, self.height);
        }
    }
}

impl CompositorHandler for Wallpaper {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, qh: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {
        self.draw(qh);
    }
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl LayerShellHandler for Wallpaper {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) { self.exit = true }
    fn configure(&mut self, _: &Connection, qh: &QueueHandle<Self>, _: &LayerSurface,
                 cfg: LayerSurfaceConfigure, _: u32) {
        if cfg.new_size.0 != 0 && cfg.new_size.1 != 0 {
            self.width = cfg.new_size.0;
            self.height = cfg.new_size.1;
        }
        // A re-shown surface needs a fresh configure before a buffer may be
        // attached; drawing straight after a remap is a protocol error that
        // kills the client (§6.3). This is that first draw.
        if !self.configured {
            self.configured = true;
            self.draw(qh);
        }
    }
}

impl OutputHandler for Wallpaper {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl ShmHandler for Wallpaper {
    fn shm_state(&mut self) -> &mut Shm { &mut self.shm }
}

impl ProvidesRegistryState for Wallpaper {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState];
}

delegate_compositor!(Wallpaper);
delegate_output!(Wallpaper);
delegate_shm!(Wallpaper);
delegate_layer!(Wallpaper);
delegate_registry!(Wallpaper);
