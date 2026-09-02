//! Dwindle: every new window splits the focused one along its LONGER axis.
//!
//! This is the binary-space-partitioning layout Hyprland calls `dwindle`, and
//! it is the only layout this desktop uses. The compositor has no such layout
//! built in -- it has `default_orientation auto`, which decides the direction
//! ONCE for a fresh container and then leaves it, so the second split down any
//! branch inherits a direction chosen for a differently shaped space and the
//! tiling drifts into thin slivers.
//!
//! Dwindle is that decision made CONTINUOUSLY. Before a window opens, the
//! container that is about to be split is told which way to split, based on
//! the shape it has at that moment. Wider than tall splits side by side;
//! taller than wide splits one above the other. That single rule is the whole
//! layout, and it is why dwindle never produces a sliver: the longer axis is
//! always the one that gets divided.
//!
//! Deliberately NOT touched:
//!
//!   * floating windows -- they are not in the tiling at all (§8.2);
//!   * fullscreen -- there is no meaningful shape to split;
//!   * tabbed and stacked containers -- those are an explicit choice made with
//!     a key, and silently converting them back to a split would make that key
//!     look broken.

/// Depth-first search for the one focused node, carrying the parent's layout
/// down so an explicit tabbed/stacked choice can be respected.
fn focused<'a>(v: &'a serde_json::Value, parent_layout: &str)
    -> Option<(&'a serde_json::Value, String)>
{
    if v.get("focused").and_then(|b| b.as_bool()).unwrap_or(false) {
        return Some((v, parent_layout.to_string()));
    }
    let layout = v.get("layout").and_then(|l| l.as_str()).unwrap_or("none");
    for key in ["nodes", "floating_nodes"] {
        if let Some(a) = v.get(key).and_then(|a| a.as_array()) {
            for c in a {
                if let Some(hit) = focused(c, layout) { return Some(hit) }
            }
        }
    }
    None
}

fn main() {
    let Some(mut cmd) = nulllinux::ipc::command_socket() else {
        eprintln!("dwindle: no compositor socket; refusing to run blind");
        std::process::exit(1);
    };
    let Some(mut events) = nulllinux::ipc::subscribe_stream() else {
        eprintln!("dwindle: could not subscribe to the compositor");
        std::process::exit(1);
    };

    // Only send a command when the ANSWER CHANGES. Re-issuing the same split
    // on every focus change is a command per keystroke-driven focus move, and
    // this system has been bitten three times by components that act on every
    // wakeup instead of on every change (§7.2).
    let mut last: Option<(i64, &'static str)> = None;

    let decide = |cmd: &mut std::os::unix::net::UnixStream,
                  last: &mut Option<(i64, &'static str)>| {
        let Some(t) = nulllinux::ipc::tree(cmd) else { return };
        let Some((node, parent_layout)) = focused(&t, "none") else { return };

        if node.get("type").and_then(|s| s.as_str()) == Some("floating_con") { return }
        if node.get("fullscreen_mode").and_then(|n| n.as_u64()).unwrap_or(0) != 0 { return }
        if parent_layout == "tabbed" || parent_layout == "stacked" { return }

        let Some(rect) = node.get("rect") else { return };
        let w = rect.get("width").and_then(|n| n.as_i64()).unwrap_or(0);
        let h = rect.get("height").and_then(|n| n.as_i64()).unwrap_or(0);
        if w <= 0 || h <= 0 { return }

        // The longer axis is the one that gets divided. Ties go to a vertical
        // split so an exactly square container behaves predictably rather than
        // depending on rounding.
        let want = if w > h { "splith" } else { "splitv" };
        let id = node.get("id").and_then(|n| n.as_i64()).unwrap_or(-1);
        if *last == Some((id, want)) { return }
        if nulllinux::ipc::run_command(cmd, want) { *last = Some((id, want)) }
    };

    // Prime it, so the first window opened after start already splits correctly
    // rather than waiting for a focus change that may never come.
    decide(&mut cmd, &mut last);

    loop {
        if nulllinux::ipc::drain_event(&mut events).is_none() {
            // The compositor went away. Exiting is right: it restarts us.
            std::process::exit(0);
        }
        decide(&mut cmd, &mut last);
    }
}
