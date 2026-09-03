//! Which screens exist, and how to pin a surface to one (NULL.md §0.2, §6.3).
//!
//! Not wallpaper-specific: the bar, the column and the wallpaper all need to
//! know what outputs the compositor has, and all three used to answer it the
//! same wrong way -- by not asking.

use smithay_client_toolkit::{
    delegate_output, delegate_registry,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::wl_output,
    Connection, QueueHandle,
};

// --- finding a named output -------------------------------------------------
//
// EVERY SURFACE USED TO PASS `None` HERE, and `None` means "compositor,
// you choose". With one monitor that is always right and the bug is invisible.
// With two it is not: all three surfaces land on whichever output the
// compositor picked, and the second screen shows a bare background for ever.
//
// Outputs are not known until the registry has been round-tripped, and the
// surface has to be created before the main loop starts -- so the probe runs
// on a SECOND event queue over the SAME connection. wayland-client allows
// that, and an object bound on one queue stays valid on another; only its
// events dispatch elsewhere, and after this we no longer care about them.
struct Probe {
    registry_state: RegistryState,
    output_state: OutputState,
}
impl OutputHandler for Probe {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}
impl ProvidesRegistryState for Probe {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState];
}
delegate_output!(Probe);
delegate_registry!(Probe);

/// Every output the compositor currently has, as (name, width, height, scale).
pub fn list_outputs(conn: &Connection) -> Result<Vec<(String, i32, i32, i32)>, String> {
    let (globals, mut q) = registry_queue_init::<Probe>(conn).map_err(|e| e.to_string())?;
    let qh = q.handle();
    let mut p = Probe {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
    };
    // TWO round-trips. The first learns that the outputs exist; their name and
    // mode arrive in the events the first one provoked.
    q.roundtrip(&mut p).map_err(|e| e.to_string())?;
    q.roundtrip(&mut p).map_err(|e| e.to_string())?;
    let mut v = Vec::new();
    for o in p.output_state.outputs() {
        if let Some(i) = p.output_state.info(&o) {
            let (w, h) = i.logical_size
                .or_else(|| i.modes.iter().find(|m| m.current).map(|m| m.dimensions))
                .unwrap_or((0, 0));
            v.push((i.name.clone().unwrap_or_default(), w, h, i.scale_factor));
        }
    }
    v.sort();
    Ok(v)
}

/// The wl_output with this name, for pinning a layer surface to one screen.
pub fn find_output(conn: &Connection, want: &str) -> Result<wl_output::WlOutput, String> {
    let (globals, mut q) = registry_queue_init::<Probe>(conn).map_err(|e| e.to_string())?;
    let qh = q.handle();
    let mut p = Probe {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
    };
    q.roundtrip(&mut p).map_err(|e| e.to_string())?;
    q.roundtrip(&mut p).map_err(|e| e.to_string())?;
    let mut seen = Vec::new();
    for o in p.output_state.outputs() {
        match p.output_state.info(&o).and_then(|i| i.name) {
            Some(n) if n == want => return Ok(o),
            Some(n) => seen.push(n),
            None => {}
        }
    }
    // NAMED, NOT SILENTLY IGNORED. A surface asked for a screen that is not
    // there has nowhere correct to go, and falling back to "any output" is how
    // two surfaces end up stacked on one monitor.
    Err(format!("no output named {want:?}; this compositor has: {}",
                if seen.is_empty() { "none".into() } else { seen.join(", ") }))
}

