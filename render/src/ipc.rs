//! Sway IPC: the compositor's event stream (NULL.md §6.4).
//!
//! Occlusion is decided by COUNTING WINDOWS, not by watching for fullscreen.
//! On a tiling compositor a single tiled window fills the output without ever
//! entering fullscreen mode -- which is the common case, so a fullscreen-only
//! check suspends almost never.

use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use std::sync::Arc;

const MAGIC: &[u8; 6] = b"i3-ipc";
const GET_WORKSPACES: u32 = 1;
const GET_TREE: u32 = 4;
const GET_OUTPUTS: u32 = 3;
const SUBSCRIBE: u32 = 2;

fn send(sock: &mut UnixStream, kind: u32, payload: &[u8]) -> std::io::Result<()> {
    let mut msg = Vec::with_capacity(14 + payload.len());
    msg.extend_from_slice(MAGIC);
    msg.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
    msg.extend_from_slice(&kind.to_ne_bytes());
    msg.extend_from_slice(payload);
    sock.write_all(&msg)
}

fn recv(sock: &mut UnixStream) -> std::io::Result<(u32, Vec<u8>)> {
    let mut hdr = [0u8; 14];
    sock.read_exact(&mut hdr)?;
    if &hdr[0..6] != MAGIC {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "bad ipc magic"));
    }
    let len = u32::from_ne_bytes(hdr[6..10].try_into().unwrap()) as usize;
    let kind = u32::from_ne_bytes(hdr[10..14].try_into().unwrap());
    let mut body = vec![0u8; len];
    sock.read_exact(&mut body)?;
    Ok((kind, body))
}

/// Count real windows that are actually VISIBLE.
///
/// Two distinctions, and getting either wrong breaks occlusion in a way that
/// looks like the check being broken rather than the count being wrong:
///
/// * Sway uses the `con` node type for split containers as well as for
///   windows, so counting node types over-counts -- a workspace holding one
///   terminal reports two. A real window is one the compositor has a process
///   for, so this counts nodes carrying a `pid`.
///
/// * Only windows on a VISIBLE workspace occlude anything. Counting the whole
///   tree counts windows on every other workspace too, and the surface then
///   suspends permanently on a bare desktop. Scratchpad and other special
///   workspaces are included when they are visible, and excluded when they are
///   not, which is the same rule rather than a special case.
///
/// Parsed rather than substring-matched. A substring net over someone else's
/// JSON catches whatever they happened to name that way (§8.10).
fn count_windows(json: &str, visible: &[String]) -> usize {
    fn count_under(v: &serde_json::Value, n: &mut usize) {
        if v.get("pid").and_then(|p| p.as_u64()).is_some() { *n += 1 }
        for key in ["nodes", "floating_nodes"] {
            if let Some(a) = v.get(key).and_then(|a| a.as_array()) {
                for c in a { count_under(c, n) }
            }
        }
    }
    fn walk(v: &serde_json::Value, visible: &[String], n: &mut usize) {
        if v.get("type").and_then(|t| t.as_str()) == Some("workspace") {
            // get_tree carries NO visibility field on workspace nodes -- only
            // get_workspaces does. Scoping on a field that is simply absent
            // would silently count nothing and the surface would never suspend.
            let name = v.get("name").and_then(|s| s.as_str()).unwrap_or("");
            if visible.iter().any(|w| w == name) { count_under(v, n) }
            return;
        }
        for key in ["nodes", "floating_nodes"] {
            if let Some(a) = v.get(key).and_then(|a| a.as_array()) {
                for c in a { walk(c, visible, n) }
            }
        }
    }
    let Ok(v) = serde_json::from_str::<serde_json::Value>(json) else { return 0 };
    let mut n = 0;
    walk(&v, visible, &mut n);
    n
}

/// Names of the workspaces currently on screen.
fn visible_workspaces(ws_json: &str, output: Option<&str>) -> Vec<String> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(ws_json) else { return Vec::new() };
    v.as_array().map(|a| a.iter()
        .filter(|w| w.get("visible").and_then(|b| b.as_bool()).unwrap_or(false))
        .filter(|w| output.map_or(true, |name| w.get("output").and_then(|o| o.as_str()) == Some(name)))
        .filter_map(|w| w.get("name").and_then(|s| s.as_str()).map(String::from))
        .collect()).unwrap_or_default()
}

/// True when every output has its display powered down.
///
/// MEASURED, not assumed. §6.4 originally said frame callbacks stop when the
/// output powers off, so a renderer suspends "for free". On this compositor
/// that is NOT reliable: with the display off the surface still received
/// callbacks and kept drawing -- burning CPU behind a dark screen, which is
/// the exact cost the rule exists to avoid. So the state is asked for.
fn all_outputs_off(outputs_json: &str, output: Option<&str>) -> bool {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(outputs_json) else { return false };
    let Some(arr) = v.as_array() else { return false };
    let real: Vec<_> = arr.iter()
        .filter(|o| o.get("active").and_then(|b| b.as_bool()).unwrap_or(false))
        .filter(|o| output.map_or(true, |name| o.get("name").and_then(|n| n.as_str()) == Some(name)))
        .collect();
    if real.is_empty() { return false }
    real.iter().all(|o| {
        let dpms = o.get("dpms").and_then(|b| b.as_bool()).unwrap_or(true);
        let power = o.get("power").and_then(|b| b.as_bool()).unwrap_or(true);
        !dpms || !power
    })
}

/// One sample: should the surface suspend right now?
///
/// Two independent reasons, and both must be asked: a window is covering the
/// output, or the output is powered down.
fn sample(path: &str, output: Option<&str>) -> Option<bool> {
    let mut s = UnixStream::connect(path).ok()?;
    send(&mut s, GET_WORKSPACES, b"").ok()?;
    let (_, ws) = recv(&mut s).ok()?;
    let visible = visible_workspaces(&String::from_utf8_lossy(&ws), output);

    let mut s2 = UnixStream::connect(path).ok()?;
    send(&mut s2, GET_OUTPUTS, b"").ok()?;
    let (_, outs) = recv(&mut s2).ok()?;
    if all_outputs_off(&String::from_utf8_lossy(&outs), output) { return Some(true) }

    let mut s3 = UnixStream::connect(path).ok()?;
    send(&mut s3, GET_TREE, b"").ok()?;
    let (_, tree) = recv(&mut s3).ok()?;
    Some(count_windows(&String::from_utf8_lossy(&tree), &visible) > 0)
}

fn socket_path() -> Option<String> {
    std::env::var("SWAYSOCK").ok().or_else(|| {
        let d = std::env::var("XDG_RUNTIME_DIR").ok()?;
        std::fs::read_dir(d).ok()?.filter_map(|e| e.ok())
            .map(|e| e.path())
            .find(|p| p.file_name().map_or(false, |n| n.to_string_lossy().starts_with("sway-ipc.")))
            .map(|p| p.to_string_lossy().into_owned())
    })
}

/// Watch the compositor and keep `occluded` current.
///
/// Returns false if no compositor socket could be found, so the caller can
/// decide rather than silently animating for ever.
pub fn spawn_occlusion_watch(occluded: Arc<AtomicBool>) -> bool {
    spawn_occlusion_watch_for_output(occluded, None)
}

pub fn spawn_occlusion_watch_for_output(occluded: Arc<AtomicBool>, output: Option<String>) -> bool {
    let Some(path) = socket_path() else { return false };

    // Prime it once, so the first frame is already correct.
    if let Some(o) = sample(&path, output.as_deref()) { occluded.store(o, Ordering::Relaxed) }

    std::thread::spawn(move || {
        // The thread must NEVER return. If it does, whatever value was last
        // stored stays there for ever and nothing corrects it -- and the
        // primed value is taken at startup, which for a surface launched by
        // the compositor at reload is exactly when a window IS visible. The
        // surface then stays suspended permanently, on a machine where the
        // same binary works perfectly when started by hand.
        //
        // So the subscription is treated as an OPTIMISATION and the timer as
        // the guarantee: events make it responsive, the timer makes it
        // correct. A failed or dropped subscription is retried, never fatal.
        let settle = Duration::from_millis(150);
        let backstop = Duration::from_secs(2);
        let mut ev: Option<UnixStream> = None;

        loop {
            if ev.is_none() {
                ev = UnixStream::connect(&path).ok().and_then(|mut s| {
                    send(&mut s, SUBSCRIBE, br#"["window","workspace","output"]"#).ok()?;
                    recv(&mut s).ok()?;
                    Some(s)
                });
            }

            let woke = match ev.as_ref() {
                Some(s) => {
                    let mut fds = [libc::pollfd {
                        fd: s.as_raw_fd(), events: libc::POLLIN, revents: 0,
                    }];
                    let n = unsafe {
                        libc::poll(fds.as_mut_ptr(), 1, backstop.as_millis() as libc::c_int)
                    };
                    // A descriptor whose writer has exited reports ready on
                    // every call, so without this check the loop spins (§7.2).
                    if n > 0 && fds[0].revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                        ev = None;
                        false
                    } else if n > 0 {
                        if ev.as_mut().map_or(true, |s| recv(s).is_err()) { ev = None; false }
                        else { true }
                    } else { false }
                }
                None => { std::thread::sleep(backstop); false }
            };

            // Settle before sampling: an event fires while the tree still
            // contains the window that is going away, and a sample taken then
            // records the state that is about to stop being true.
            if woke { std::thread::sleep(settle) }
            if let Some(o) = sample(&path, output.as_deref()) { occluded.store(o, Ordering::Relaxed) }
        }
    });
    true
}

#[cfg(test)]
mod output_scope_tests {
    use super::*;
    #[test]
    fn a_window_on_another_output_does_not_hide_a_bare_desktop() {
        let ws = r#"[{"name":"1","output":"A","visible":true},{"name":"2","output":"B","visible":true}]"#;
        let tree = r#"{"nodes":[{"type":"workspace","name":"1","nodes":[{"pid":42}]},{"type":"workspace","name":"2","nodes":[]}]}"#;
        assert_eq!(count_windows(tree, &visible_workspaces(ws, Some("A"))), 1);
        assert_eq!(count_windows(tree, &visible_workspaces(ws, Some("B"))), 0);
    }
    #[test]
    fn power_is_scoped_to_the_surface_output() {
        let outs = r#"[{"name":"A","active":true,"power":false},{"name":"B","active":true,"power":true}]"#;
        assert!(all_outputs_off(outs, Some("A")));
        assert!(!all_outputs_off(outs, Some("B")));
        assert!(!all_outputs_off(outs, None));
    }
}

/// True when running on battery. Absent hardware reads as mains (§8.4): a
/// machine with no battery must not behave as though it were always on one.
pub fn on_battery() -> bool {
    // A verification affordance, not a configuration knob. The battery path
    // cannot be exercised on a machine that is plugged in, and a path that is
    // never run is a path that does not work. Named so it cannot be mistaken
    // for a setting.
    if let Some(v) = std::env::var_os("RENDER_ASSUME_BATTERY") {
        return v == "1";
    }
    for e in std::fs::read_dir("/sys/class/power_supply").into_iter().flatten().flatten() {
        let p = e.path();
        let name = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
        if name.starts_with("AC") || name.starts_with("ADP") {
            if let Ok(s) = std::fs::read_to_string(p.join("online")) {
                return s.trim() == "0";
            }
        }
    }
    false
}

// --- helpers for surfaces that follow compositor state ------------------

/// Subscribe to the compositor's event stream and hand back the descriptor.
///
/// Returned as a socket the caller waits on in its OWN poll, rather than a
/// thread: §7.2 wants one sleep serving every source, and a thread per source
/// is the shape that rule exists to avoid.
pub fn subscribe_stream() -> Option<UnixStream> {
    let path = socket_path()?;
    let mut s = UnixStream::connect(&path).ok()?;
    send(&mut s, SUBSCRIBE, br#"["window","workspace","output"]"#).ok()?;
    let _ = recv(&mut s).ok()?;      // the subscribe reply
    Some(s)
}

/// A connected command socket, for callers that issue commands and queries.
pub fn command_socket() -> Option<UnixStream> {
    UnixStream::connect(socket_path()?).ok()
}

/// Run a compositor command. True if the compositor reported success.
pub fn run_command(sock: &mut UnixStream, cmd: &str) -> bool {
    if send(sock, 0, cmd.as_bytes()).is_err() { return false }
    let Ok((_, body)) = recv(sock) else { return false };
    // The reply is an array of per-command results; a command can be accepted
    // and still fail, so the success flag is read rather than assumed.
    serde_json::from_slice::<serde_json::Value>(&body).ok()
        .and_then(|v| v.as_array().map(|a| a.iter().all(|r|
            r.get("success").and_then(|b| b.as_bool()).unwrap_or(false))))
        .unwrap_or(false)
}

/// The full container tree.
pub fn tree(sock: &mut UnixStream) -> Option<serde_json::Value> {
    send(sock, GET_TREE, b"").ok()?;
    let (_, body) = recv(sock).ok()?;
    serde_json::from_slice(&body).ok()
}

/// Consume one event. None means the stream ended and the caller must drop it.
pub fn drain_event(s: &mut UnixStream) -> Option<()> {
    recv(s).ok().map(|_| ())
}

/// (workspace strip, focused window title).
///
/// One query for both, because they change together and two queries would be
/// two round trips for one fact.
pub fn workspaces_and_title() -> Option<(String, String)> {
    let path = socket_path()?;

    let mut s = UnixStream::connect(&path).ok()?;
    send(&mut s, GET_WORKSPACES, b"").ok()?;
    let (_, ws) = recv(&mut s).ok()?;
    let v: serde_json::Value = serde_json::from_slice(&ws).ok()?;
    let mut strip = String::new();
    for w in v.as_array()?.iter() {
        let name = w.get("name").and_then(|n| n.as_str()).unwrap_or("?");
        let focused = w.get("focused").and_then(|b| b.as_bool()).unwrap_or(false);
        // The live one takes ink and gets a mark; the rest are dim. A control
        // is a mark and a rule, not a box (§7.1).
        if focused { strip.push_str(&format!("[{name}]")) } else { strip.push_str(&format!(" {name} ")) }
    }

    let mut s2 = UnixStream::connect(&path).ok()?;
    send(&mut s2, GET_TREE, b"").ok()?;
    let (_, tree) = recv(&mut s2).ok()?;
    let t: serde_json::Value = serde_json::from_slice(&tree).ok()?;
    fn focused_title(v: &serde_json::Value) -> Option<String> {
        if v.get("focused").and_then(|b| b.as_bool()).unwrap_or(false)
            && v.get("pid").is_some() {
            return v.get("name").and_then(|n| n.as_str()).map(String::from);
        }
        for k in ["nodes", "floating_nodes"] {
            if let Some(a) = v.get(k).and_then(|a| a.as_array()) {
                for c in a { if let Some(t) = focused_title(c) { return Some(t) } }
            }
        }
        None
    }
    Some((strip, focused_title(&t).unwrap_or_default()))
}
