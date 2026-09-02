//! What each reading in the idle panel actually costs.
//!
//! The panel samples some things every second whether or not it is on screen,
//! and others only while it is visible. That split was made on the grounds
//! that "walking /sys is expensive", measured as a GROUP -- which is enough to
//! justify not doing it, and not enough to say which call to avoid or whether
//! a new graph can afford its input.
//!
//! Run: cargo run --release --example sysinfo-cost
//!
//! Reports CPU time per call, not wall clock: these are /proc and /sys reads,
//! so wall clock is mostly page cache and says less than the time actually
//! burned. The panel's budget is a share of one core, and this is the quantity
//! that goes into it.

use std::time::Instant;

fn cpu_time() -> f64 {
    let mut u = unsafe { std::mem::zeroed::<libc::rusage>() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
    let s = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    s(u.ru_utime) + s(u.ru_stime)
}

/// `n` calls, reporting microseconds of CPU per call.
fn bench(name: &str, n: u32, mut f: impl FnMut()) {
    // A warm-up pass, so the first run's directory lookups are not charged to
    // the reading rather than to the cache being cold.
    for _ in 0..10 { f() }
    let (c0, w0) = (cpu_time(), Instant::now());
    for _ in 0..n { f() }
    let (cpu, wall) = (cpu_time() - c0, w0.elapsed().as_secs_f64());
    println!("{name:<22} {:>8.1} us cpu {:>8.1} us wall   {:>6.3}% of a core at 1 Hz",
             cpu / n as f64 * 1e6, wall / n as f64 * 1e6, cpu / n as f64 * 100.0);
}

fn main() {
    let n: u32 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(200);
    println!("{n} calls each, on this machine, now.\n");

    println!("-- sampled every second, on screen or not --");
    let mut cpu = nulllinux::sysinfo::CpuSampler::new();
    bench("cpu (/proc/stat)", n, || { cpu.sample(); });
    bench("memory", n, || { nulllinux::sysinfo::memory(); });
    bench("net_bytes", n, || { nulllinux::sysinfo::net_bytes(); });
    bench("disk_io", n, || { nulllinux::sysinfo::disk_io(); });

    println!("\n-- sampled only while visible, every three seconds --");
    bench("load_average", n, || { nulllinux::sysinfo::load_average(); });
    bench("uptime", n, || { nulllinux::sysinfo::uptime(); });
    bench("disk_usage", n, || { nulllinux::sysinfo::disk_usage("/"); });
    bench("temperature", n, || { nulllinux::sysinfo::temperature(); });
    bench("battery", n, || { nulllinux::sysinfo::battery(); });
    bench("wireless_interface", n, || { nulllinux::sysinfo::wireless_interface(); });
    bench("wireless_quality", n, || { nulllinux::sysinfo::wireless_quality_cached(); });

    println!("\n-- the expensive one, for scale --");
    let mut prev = std::collections::HashMap::new();
    bench("top_processes", n.min(60), || { nulllinux::sysinfo::top_processes(&mut prev, 1.0, 4); });
}
