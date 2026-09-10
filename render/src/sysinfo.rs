//! Machine readings (NULL.md §7.2, §8.4).
//!
//! Read from the kernel's own files. Nothing here spawns a process: a status
//! surface that spawns one per second costs more than the surface it feeds
//! (§7.2), and a value the kernel already publishes is free to read.
//!
//! Hardware that is absent reports None, never zero. A row whose hardware is
//! absent is not drawn (§8.4) -- a backlight row on a machine with no
//! backlight is a permanent complaint about a missing feature.

use std::fs;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// One size, written one way, everywhere (§7.1).
///
/// Tools report in a mix of binary and decimal multiples and differing
/// precision. Converting at the boundary and rendering through a single
/// formatter is what stops the same quantity appearing in two notations.
pub fn si(bytes: u64) -> String {
    const U: [&str; 6] = ["B", "kB", "MB", "GB", "TB", "PB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1000.0 && i < U.len() - 1 { v /= 1000.0; i += 1 }
    if i == 0 { format!("{} {}", bytes, U[0]) }
    else if v >= 100.0 { format!("{:.0} {}", v, U[i]) }
    else if v >= 10.0 { format!("{:.1} {}", v, U[i]) }
    else { format!("{:.2} {}", v, U[i]) }
}

pub struct CpuSampler { prev_idle: u64, prev_total: u64 }

impl CpuSampler {
    pub fn new() -> Self { CpuSampler { prev_idle: 0, prev_total: 0 } }

    /// Fraction busy since the previous call. The first call has no previous
    /// sample and returns None rather than a misleading number.
    pub fn sample(&mut self) -> Option<f32> {
        let s = fs::read_to_string("/proc/stat").ok()?;
        let line = s.lines().next()?;
        let v: Vec<u64> = line.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
        if v.len() < 4 { return None }
        let idle = v[3] + v.get(4).copied().unwrap_or(0);
        let total: u64 = v.iter().sum();
        let (di, dt) = (idle.saturating_sub(self.prev_idle), total.saturating_sub(self.prev_total));
        self.prev_idle = idle;
        self.prev_total = total;
        if dt == 0 { return None }
        Some(1.0 - di as f32 / dt as f32)
    }
}

/// Per-core busy fractions, in core order.
///
/// The aggregate says how much of the machine is working; this says how that
/// work is SPREAD. One thread pinned at 100% and eight threads at 12% are the
/// same aggregate reading and completely different situations -- the first is
/// a single-threaded job that more cores will not help, the second is a
/// machine genuinely at work. Nothing on the panel could tell them apart.
///
/// Same file as the aggregate, one line per core below it.
#[derive(Default)]
pub struct CoreSampler { prev: Vec<(u64, u64)> }

impl CoreSampler {
    /// Empty until the second call: a core's share is a delta, and the first
    /// reading of a counter is not one.
    pub fn sample(&mut self) -> Vec<f32> {
        let Ok(s) = fs::read_to_string("/proc/stat") else { return Vec::new() };
        let mut now: Vec<(u64, u64)> = Vec::new();
        for line in s.lines() {
            // "cpu0", "cpu1", ... and NOT "cpu", which is the aggregate.
            if !line.starts_with("cpu") { continue }
            let Some(rest) = line.split_whitespace().next() else { continue };
            if rest == "cpu" || !rest[3..].chars().all(|c| c.is_ascii_digit()) { continue }
            let v: Vec<u64> = line.split_whitespace().skip(1)
                .filter_map(|x| x.parse().ok()).collect();
            if v.len() < 4 { continue }
            now.push((v[3] + v.get(4).copied().unwrap_or(0), v.iter().sum()));
        }
        let out = if self.prev.len() == now.len() {
            now.iter().zip(&self.prev).map(|((i, t), (pi, pt))| {
                let (di, dt) = (i.saturating_sub(*pi), t.saturating_sub(*pt));
                if dt == 0 { 0.0 } else { (1.0 - di as f32 / dt as f32).clamp(0.0, 1.0) }
            }).collect()
        } else { Vec::new() };
        self.prev = now;
        out
    }
}

/// (used bytes, total bytes)
pub fn memory() -> Option<(u64, u64)> {
    let s = fs::read_to_string("/proc/meminfo").ok()?;
    let mut total = 0u64;
    let mut avail = 0u64;
    for l in s.lines() {
        let mut it = l.split_whitespace();
        match it.next() {
            Some("MemTotal:") => total = it.next()?.parse::<u64>().ok()? * 1024,
            Some("MemAvailable:") => avail = it.next()?.parse::<u64>().ok()? * 1024,
            _ => {}
        }
    }
    if total == 0 { None } else { Some((total.saturating_sub(avail), total)) }
}

/// Hottest hwmon reading, in degrees C.
/// The sensor files, found once.
///
/// Which sensors exist is a property of the hardware and does not change while
/// the machine is running, so discovering them is done once and the reading
/// itself is just the file reads.
///
/// This is not a micro-optimisation. Walking /sys/class/hwmon and every
/// directory inside it, on every call, measured 1289 us of CPU and 5710 us of
/// WALL CLOCK per reading -- fifty times the cost of reading /proc/stat, and
/// by far the most expensive thing the idle panel did outside the process
/// scan. The wall figure is the one that matters: it is four times the CPU
/// figure because these reads go to drivers rather than to the page cache, so
/// the call BLOCKS, and it blocked the panel's 125 ms timer for 5.7 ms of it.
///
/// The paths are cached, not the reading. Which sensor is hottest changes from
/// second to second and is the whole point of taking it.
struct Sensors { fast: Vec<std::path::PathBuf>, slow: Vec<std::path::PathBuf> }

fn sensor_paths() -> &'static Sensors {
    static PATHS: std::sync::OnceLock<Sensors> = std::sync::OnceLock::new();
    PATHS.get_or_init(|| {
        let mut found = Vec::new();
        let Ok(hwmons) = fs::read_dir("/sys/class/hwmon")
            else { return Sensors { fast: Vec::new(), slow: Vec::new() } };
        for e in hwmons.flatten() {
            let Ok(entries) = fs::read_dir(e.path()) else { continue };
            for f in entries.flatten() {
                let name = f.file_name().to_string_lossy().into_owned();
                if name.starts_with("temp") && name.ends_with("_input") { found.push(f.path()) }
            }
        }
        // Then each one is TIMED, once, and the slow ones are dropped.
        //
        // Not every sensor is a file. On this machine the nine of them cost
        // 7.7 ms to sweep, and two accounted for 6.5 ms of that: the NVMe
        // drive at 4.6 ms and the wifi at 1.8 ms. Those are not reads, they
        // are round trips to a device -- an admin command to the SSD and a
        // query to the wifi firmware. The CPU package sensors cost 150 us.
        //
        // The cost that matters there is not the microseconds. Asking the SSD
        // its temperature once a second keeps it from settling into a low
        // power state, on a laptop, to draw a line on a panel. No graph is
        // worth that.
        //
        // Which sensors those are is DISCOVERED rather than named (§0.2): a
        // list of "nvme, iwlwifi" would be this machine's list, and the rule
        // is really "anything that has to wake something up". A millisecond is
        // far above any cached read and far below any device round trip, so it
        // separates the two without being tuned to either.
        const BUDGET: std::time::Duration = std::time::Duration::from_millis(1);
        let (mut fast, mut slow) = (Vec::new(), Vec::new());
        for path in found {
            let _ = fs::read_to_string(&path);          // warm, so the first
            let t = std::time::Instant::now();          // read is not charged
            let ok = fs::read_to_string(&path).is_ok(); // to the sensor
            if !ok { continue }
            if t.elapsed() < BUDGET { fast.push(path) } else { slow.push(path) }
        }
        Sensors { fast, slow }
    })
}

/// The hottest sensor on the machine, in degrees Celsius.
///
/// The maximum over every sensor, not a named one: which chip runs hottest is
/// a property of the machine, and naming one here would be a guess that
/// happened to be right on the machine it was written on (§0.2).
pub fn temperature() -> Option<f32> {
    fn read_max(paths: &[std::path::PathBuf]) -> Option<f32> {
        let mut best: Option<f32> = None;
        for path in paths {
            if let Ok(v) = fs::read_to_string(path) {
                if let Ok(m) = v.trim().parse::<f32>() {
                    let c = m / 1000.0;
                    if c > 0.0 && c < 150.0 && best.map_or(true, |b| c > b) { best = Some(c) }
                }
            }
        }
        best
    }
    let s = sensor_paths();
    let fast = read_max(&s.fast);

    // The slow sensors are read RARELY rather than never.
    //
    // Dropping them outright would have been the cheap answer, and wrong: a
    // drive cooking at 70 C is exactly the thing a temperature reading is for,
    // and on this machine the NVMe is a sensor that only it can report. But it
    // moves slowly -- it is a lump of metal -- so a minute-old reading of it is
    // still a true one, and once a minute does not keep the drive awake.
    static SLOW: std::sync::OnceLock<std::sync::Mutex<Option<(std::time::Instant, f32)>>> =
        std::sync::OnceLock::new();
    let cell = SLOW.get_or_init(|| std::sync::Mutex::new(None));
    let cached = {
        let mut g = match cell.lock() { Ok(g) => g, Err(e) => e.into_inner() };
        let stale = g.map_or(true, |(t, _)| t.elapsed() >= std::time::Duration::from_secs(60));
        if stale && !s.slow.is_empty() {
            if let Some(v) = read_max(&s.slow) { *g = Some((std::time::Instant::now(), v)) }
        }
        g.map(|(_, v)| v)
    };
    match (fast, cached) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    }
}

pub struct Battery {
    pub percent: u8,
    pub charging: bool,
    /// Seconds until empty, or until full when charging. `None` when the
    /// battery is not moving -- full on the mains, or the kernel reporting a
    /// rate of zero -- because an estimate with no rate behind it would be an
    /// invention.
    pub secs_left: Option<u64>,
}

/// Seconds until the battery reaches the end it is heading for.
///
/// Split out from the file reading so it can be tested: this is arithmetic on
/// a battery that is nowhere near empty on the machine it was written on, and
/// it would otherwise be checked only by unplugging the laptop and waiting.
///
/// `now`, `full` and `rate` are in whatever units the kernel gave, as long as
/// they are the SAME units -- charge in uAh against current in uA, or energy
/// in uWh against power in uW. Both are ratios of a quantity to a rate, so the
/// hours fall out either way.
pub fn battery_eta(now: f64, full: f64, rate: f64, charging: bool) -> Option<u64> {
    if !(rate > 0.0) || !now.is_finite() || !full.is_finite() { return None }
    let remaining = if charging { (full - now).max(0.0) } else { now.max(0.0) };
    let hours = remaining / rate;
    // A week is not a battery estimate, it is a rate that was rounded to
    // almost nothing. Better to say nothing than to say "6d 04:11".
    if !hours.is_finite() || hours > 48.0 { return None }
    Some((hours * 3600.0) as u64)
}

/// None when the machine has no battery -- discovered, not declared (§0.2).
pub fn battery() -> Option<Battery> { battery_at(std::path::Path::new("/sys/class/power_supply")) }

/// The reading itself, against a given root.
///
/// Parameterised on the directory purely so it can be TESTED. The arithmetic
/// in `battery_eta` is easy to check; the part that actually broke on a real
/// machine would be this -- picking the wrong field names, or finding none and
/// silently reporting no estimate forever. On the machine this was written on
/// the battery is full on the mains, so the discharging path never runs, and
/// "it compiles and shows 100%" is not evidence that it works.
pub fn battery_at(root: &std::path::Path) -> Option<Battery> {
    // EVERY BATTERY, NOT THE FIRST ONE FOUND.
    //
    // This returned on the first BAT* directory readdir happened to yield, and
    // directory order is arbitrary. On a ThinkPad with a power bridge -- an
    // internal cell and a removable one -- that is a coin toss between two
    // numbers, neither of which is the answer: this machine reported 5% or 83%
    // depending on the order, while actually holding 63% of its capacity.
    //
    // Percentages cannot be added, so the aggregate is computed from ENERGY:
    // the sum of what is in the cells over the sum of what they hold. With one
    // battery that is identical to reading its capacity, so nothing changes on
    // a machine that has one.
    let mut sum_now = 0f64;
    let mut sum_full = 0f64;
    let mut sum_rate = 0f64;
    let mut have_energy = false;
    let mut energy_units: Option<bool> = None;
    let mut mixed_units = false;
    let mut individual_percent = Vec::new();
    let mut caps: Vec<f64> = Vec::new();
    let mut charging = false;
    let mut found = false;

    for e in fs::read_dir(root).ok()?.flatten() {
        let p = e.path();
        let Some(name) = p.file_name() else { continue };
        if !name.to_string_lossy().starts_with("BAT") { continue }
        found = true;

        let status = fs::read_to_string(p.join("status")).unwrap_or_default();
        // Any cell taking charge means the machine is charging. "Not charging"
        // is what a full cell says while another is still filling, and reading
        // it as "on battery" would count down a machine that is plugged in.
        if status.trim() == "Charging" { charging = true }

        if let Ok(c) = fs::read_to_string(p.join("capacity")) {
            if let Ok(v) = c.trim().parse::<f64>() { caps.push(v) }
        }

        // Two kernels, two vocabularies. Some batteries report CHARGE in uAh
        // with a current in uA; others report ENERGY in uWh with a power in
        // uW. Which one a machine uses is a property of the machine, so both
        // are tried rather than one being assumed (§0.2).
        let num = |f: &str| -> Option<f64> {
            fs::read_to_string(p.join(f)).ok()?.trim().parse::<f64>().ok()
        };
        // Prefer energy and pair its rate with power. Convert charge using
        // voltage when available; never add microamp-hours to microwatt-hours.
        let volts = num("voltage_min_design").or_else(|| num("voltage_now"))
            .filter(|v| v.is_finite() && *v > 0.0).map(|v| v / 1_000_000.0);
        let pair = num("energy_now").zip(num("energy_full"))
            .map(|(now, full)| (now, full, num("power_now"), true))
            .or_else(|| num("charge_now").zip(num("charge_full")).map(|(now, full)| {
                let factor = volts.unwrap_or(1.0);
                (now * factor, full * factor, num("current_now").map(|r| r * factor), volts.is_some())
            }));
        if let Some((now, full, rate, energy)) = pair {
            if full > 0.0 {
                individual_percent.push(100.0 * now / full);
                if let Some(previous) = energy_units { mixed_units |= previous != energy; }
                energy_units = Some(energy);
                sum_now += now;
                sum_full += full;
                have_energy = true;
                // A rate is optional: a full cell on the mains reports none,
                // and its absence must not discard the others.
                if let Some(r) = rate {
                    sum_rate += r;
                }
            }
        }
    }
    if !found { return None }

    let percent = if mixed_units {
        // No voltage to reconcile unlike units: preserve a useful percentage
        // without inventing an aggregate energy or a remaining-time estimate.
        (individual_percent.iter().sum::<f64>() / individual_percent.len() as f64)
            .round().clamp(0.0, 100.0) as u8
    } else if have_energy {
        (100.0 * sum_now / sum_full).round().clamp(0.0, 100.0) as u8
    } else if !caps.is_empty() {
        // No energy figures anywhere. Averaging percentages is not right, but
        // it is the only thing left, and with one battery it is exact.
        (caps.iter().sum::<f64>() / caps.len() as f64).round().clamp(0.0, 100.0) as u8
    } else {
        return None;
    };

    let secs_left = if have_energy && !mixed_units {
        battery_eta(sum_now, sum_full, sum_rate, charging)
    } else {
        None
    };
    Some(Battery { percent, charging, secs_left })
}

/// Wireless link quality as a fraction.
///
/// §7.2 says to prefer a file the system already writes over a subprocess. On
/// this machine there is no such file -- /proc/net/wireless is absent and the
/// interface's sysfs wireless directory is empty -- so the free path is tried
/// first and a subprocess is the fallback, called at a LOW RATE by the caller
/// rather than once a second. Spawning a process per second costs more than
/// the surface it feeds.
///
/// Returns None when there is no wireless hardware at all, so the row is not
/// drawn rather than drawn as a zero (§8.4).
/// Cached wireless quality.
///
/// §7.2: spawning a process to read a value costs more than the surface it
/// feeds. Measured on this machine, caching it moved the bar from 0.75% to
/// 0.62% of a core (medians of 3 runs, 8 s window, load ~0.8) -- a real saving
/// but a smaller one than expected, so the subprocess was not the whole cost.
/// The number is recorded as taken rather than as predicted.
///
/// A 30-second interval is not a compromise here: it is faster than a link's
/// signal meaningfully moves.
static WIRELESS_CACHE: Mutex<Option<(Instant, Option<f32>)>> = Mutex::new(None);

pub fn wireless_quality_cached() -> Option<f32> {
    let mut c = WIRELESS_CACHE.lock().ok()?;
    if let Some((at, v)) = *c {
        if at.elapsed() < Duration::from_secs(30) { return v }
    }
    let v = wireless_quality();
    *c = Some((Instant::now(), v));
    v
}

/// The cached signal AND name, on the same 30-second interval and the same
/// single call. Two caches would mean two `iw` invocations.
pub fn wireless_link_cached() -> Option<(f32, Option<String>)> {
    use std::time::{Duration, Instant};
    static CACHE: std::sync::OnceLock<
        std::sync::Mutex<Option<(Instant, Option<(f32, Option<String>)>)>>> =
        std::sync::OnceLock::new();
    let cell = CACHE.get_or_init(|| std::sync::Mutex::new(None));
    let mut c = match cell.lock() { Ok(g) => g, Err(e) => e.into_inner() };
    if let Some((t, v)) = c.as_ref() {
        if t.elapsed() < Duration::from_secs(30) { return v.clone() }
    }
    let v = wireless_link();
    *c = Some((Instant::now(), v.clone()));
    v
}

pub fn wireless_quality() -> Option<f32> { wireless_link().map(|(q, _)| q) }

/// Signal quality, and the network's name where getting it is free.
///
/// The name comes back only from the `iw` path, and DELIBERATELY so. Where the
/// kernel publishes quality in /proc/net/wireless there is no subprocess and
/// the SSID is not in that file, so asking for it would mean spawning `iw` on
/// a machine that had no need to -- paying for a nicer label with the exact
/// cost §7.2 says not to pay. Where `iw` already runs, the SSID is sitting in
/// output that was being parsed for the signal and thrown away.
///
/// So this is more information on this machine and no more cost on any.
pub fn wireless_link() -> Option<(f32, Option<String>)> {
    // Free path, where the kernel publishes it.
    if let Ok(s) = fs::read_to_string("/proc/net/wireless") {
        for l in s.lines().skip(2) {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() > 2 {
                if let Ok(q) = f[2].trim_end_matches('.').parse::<f32>() {
                    return Some(((q / 70.0).clamp(0.0, 1.0), None));
                }
            }
        }
    }
    let iface = wireless_interface()?;
    let out = std::process::Command::new("iw")
        .args(["dev", &iface, "link"]).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let (mut quality, mut ssid) = (None, None);
    for l in text.lines() {
        let l = l.trim();
        if let Some(rest) = l.strip_prefix("signal:") {
            if let Some(dbm) = rest.split_whitespace().next().and_then(|v| v.parse::<f32>().ok()) {
                // -30 dBm is excellent, -90 unusable. A linear map over that
                // span is a convention, and it is labelled as one rather than
                // presented as a measurement of anything physical.
                quality = Some(((dbm + 90.0) / 60.0).clamp(0.0, 1.0));
            }
        } else if let Some(rest) = l.strip_prefix("SSID:") {
            let name = rest.trim();
            if !name.is_empty() { ssid = Some(name.to_string()) }
        }
    }
    Some((quality.unwrap_or(0.0), ssid))
}

/// Swap used and total, in bytes.
///
/// Not shown before, and it should have been: a machine that is swapping is a
/// machine that feels broken, and nothing else on the panel would say so. This
/// one has 8 GB of it and MEM alone can never reveal a byte of that.
pub fn swap() -> Option<(u64, u64)> {
    let text = fs::read_to_string("/proc/meminfo").ok()?;
    let (mut total, mut free) = (None, None);
    for l in text.lines() {
        let mut f = l.split_whitespace();
        let key = f.next()?;
        let kb: Option<u64> = f.next().and_then(|v| v.parse().ok());
        match key {
            "SwapTotal:" => total = kb,
            "SwapFree:" => free = kb,
            _ => {}
        }
    }
    let (t, f) = (total? * 1024, free? * 1024);
    Some((t.saturating_sub(f), t))
}

/// The first interface with a wireless directory, or None if there is none.
pub fn wireless_interface() -> Option<String> {
    for e in fs::read_dir("/sys/class/net").ok()?.flatten() {
        if e.path().join("wireless").is_dir() {
            return Some(e.file_name().to_string_lossy().into_owned());
        }
    }
    None
}

/// Cumulative bytes read and written, summed over real block devices.
///
/// Partitions are skipped and their parent counted once: `nvme0n1` and
/// `nvme0n1p3` both report the same writes, so summing everything double
/// counts every byte. Loop and ram devices are not disks.
pub fn disk_io() -> Option<(u64, u64)> {
    const SECTOR: u64 = 512;
    let text = fs::read_to_string("/proc/diskstats").ok()?;
    let (mut r, mut w) = (0u64, 0u64);
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 10 { continue }
        let name = f[2];
        if name.starts_with("loop") || name.starts_with("ram") || name.starts_with("zram") {
            continue;
        }
        // A partition is its parent's name plus digits (sda1) or pN (nvme0n1p3).
        let is_partition = if name.starts_with("nvme") || name.starts_with("mmcblk") {
            name.rsplit_once('p').map(|(_, t)| t.chars().all(|c| c.is_ascii_digit())
                                                && !t.is_empty()).unwrap_or(false)
        } else {
            name.chars().last().map(|c| c.is_ascii_digit()).unwrap_or(false)
        };
        if is_partition { continue }
        r += f[5].parse::<u64>().unwrap_or(0) * SECTOR;
        w += f[9].parse::<u64>().unwrap_or(0) * SECTOR;
    }
    Some((r, w))
}

/// The busiest processes: name, share of one core, resident bytes.
///
/// CPU is a DELTA, so it needs the previous reading -- a process's total time
/// since boot says what it has done, not what it is doing, and a long-lived
/// idle process would otherwise sit permanently at the top.
///
/// The comm field is used rather than the full command line: it is one small
/// read instead of one per process, and a column this narrow could not show a
/// command line anyway.
/// Aggregated by PROGRAM, with how many processes each is.
///
/// A browser or an agent runs as a dozen processes with one name, and the list
/// used to show several rows of "claude" that no reader could tell apart --
/// while the thing they actually want to know, what that program is costing
/// the machine, was split across rows and never added up.
///
/// The CPU delta is still per PID, because that is the only place it means
/// anything; only the totals are shared. The resident figure is a SUM, and it
/// over-counts: processes of one program share pages, and RSS charges those
/// pages to each of them. It is an upper bound on what the program costs, and
/// the count is shown beside it so a large number has a visible reason.
pub fn top_processes(prev: &mut std::collections::HashMap<u32, u64>,
                     elapsed: f32, want: usize) -> Vec<(String, f32, u64, usize)> {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f32;
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as u64;
    let mut agg: std::collections::HashMap<String, (f32, u64, usize)> =
        std::collections::HashMap::new();
    let mut seen = std::collections::HashMap::new();
    let Ok(dir) = fs::read_dir("/proc") else { return Vec::new() };

    for e in dir.flatten() {
        let name = e.file_name();
        let Some(pid) = name.to_str().and_then(|n| n.parse::<u32>().ok()) else { continue };
        let Ok(stat) = fs::read_to_string(e.path().join("stat")) else { continue };
        // The comm field is parenthesised and may itself contain spaces and
        // brackets, so the fields after it are found from the LAST ')'.
        let Some(close) = stat.rfind(')') else { continue };
        let comm = stat.get(stat.find('(').map(|i| i + 1).unwrap_or(0)..close)
                       .unwrap_or("?").to_string();
        let rest: Vec<&str> = stat[close + 1..].split_whitespace().collect();
        if rest.len() < 22 { continue }
        let utime: u64 = rest[11].parse().unwrap_or(0);
        let stime: u64 = rest[12].parse().unwrap_or(0);
        let total = utime + stime;
        let rss: u64 = rest[21].parse::<u64>().unwrap_or(0) * page;
        seen.insert(pid, total);
        // EVERY process of the program is counted, busy or not.
        //
        // The threshold below is a CPU threshold, and it used to be applied to
        // each process before aggregating -- so a program's memory figure was
        // the sum over whichever of its processes happened to be busy in the
        // last three seconds, which is not a quantity anybody wants. It read
        // "claude x3 1.31 GB" for a program that was six processes and 1.76 GB.
        //
        // The filter belongs on the aggregate: count and memory cover the
        // whole program, and the program appears in the list if the PROGRAM is
        // busy.
        let e = agg.entry(comm).or_insert((0.0, 0, 0));
        e.1 += rss;
        e.2 += 1;
        if let Some(&before) = prev.get(&pid) {
            let delta = total.saturating_sub(before) as f32 / hz;
            if elapsed > 0.0 { e.0 += delta / elapsed }
        }
    }
    *prev = seen;
    let mut out: Vec<(String, f32, u64, usize)> = agg.into_iter()
        .filter(|(_, (share, _, _))| *share > 0.005)
        .map(|(n, (s, r, c))| (n, s, r, c)).collect();
    out.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    out.truncate(want);
    out
}

/// Cumulative received and transmitted bytes, summed over real interfaces.
///
/// Loopback is excluded: it is this machine talking to itself, and counting it
/// makes a busy local build look like network traffic.
pub fn net_bytes() -> Option<(u64, u64)> {
    let text = fs::read_to_string("/proc/net/dev").ok()?;
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in text.lines().skip(2) {
        let (name, rest) = line.split_once(':')?;
        let name = name.trim();
        if name == "lo" || name.starts_with("veth") || name.starts_with("docker") {
            continue;
        }
        let f: Vec<&str> = rest.split_whitespace().collect();
        if f.len() >= 9 {
            rx += f[0].parse::<u64>().unwrap_or(0);
            tx += f[8].parse::<u64>().unwrap_or(0);
        }
    }
    Some((rx, tx))
}

/// Used and total bytes of the filesystem holding `path`.
///
/// Reported against the space a user can actually have: `f_bavail`, not
/// `f_bfree`. The difference is the reserve only root may use, and counting it
/// as free tells an ordinary user they have room they do not have.
pub fn disk_usage(path: &str) -> Option<(u64, u64)> {
    let c = std::ffi::CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let unit = st.f_frsize as u64;
    let total = st.f_blocks as u64 * unit;
    // USED as df defines it: total minus the free blocks, NOT total minus the
    // blocks available to an unprivileged process.
    //
    // The two differ by the filesystem's root reserve, which is 1.61 GB here
    // -- so the panel read 7.14 GB used where df read 5.54 GB, and a panel
    // that disagrees with df by a gigabyte and a half, silently, is a bug
    // report rather than a reading.
    //
    // The reserve then appears in neither figure, which is exactly how df
    // presents it too. That was defensible when this returned "free" and the
    // caller drew "502 GB free", because f_bavail really is what you can use;
    // it stopped being defensible when the caller started drawing used.
    let free = st.f_bfree as u64 * unit;
    Some((total.saturating_sub(free), total))
}

pub fn uptime() -> Option<std::time::Duration> {
    let s = fs::read_to_string("/proc/uptime").ok()?;
    let secs: f64 = s.split_whitespace().next()?.parse().ok()?;
    Some(std::time::Duration::from_secs_f64(secs))
}

pub fn load_average() -> Option<(f32, f32, f32)> {
    let s = fs::read_to_string("/proc/loadavg").ok()?;
    let f: Vec<f32> = s.split_whitespace().take(3).filter_map(|x| x.parse().ok()).collect();
    if f.len() == 3 { Some((f[0], f[1], f[2])) } else { None }
}

#[cfg(test)]
mod battery_tests {
    use super::battery_eta;

    /// A battery directory with the given files, under a fresh temp dir.
    fn fake_battery(files: &[(&str, &str)]) -> std::path::PathBuf {
        let mut root = std::env::temp_dir();
        // The name has to differ per call, and Instant is not formattable, so
        // the nanoseconds since the epoch stand in for a counter.
        let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos()).unwrap_or(0);
        root.push(format!("null-batt-{n}-{}", files.len()));
        let bat = root.join("BAT0");
        std::fs::create_dir_all(&bat).unwrap();
        for (k, v) in files { std::fs::write(bat.join(k), v).unwrap() }
        root
    }

    #[test]
    fn a_charge_and_current_battery_is_read() {
        // What this laptop reports: uAh and uA.
        let root = fake_battery(&[("capacity", "50\n"), ("status", "Discharging\n"),
                                  ("charge_now", "2000000\n"), ("charge_full", "4000000\n"),
                                  ("current_now", "1000000\n")]);
        let b = super::battery_at(&root).expect("a battery");
        assert_eq!((b.percent, b.charging), (50, false));
        assert_eq!(b.secs_left, Some(7200), "2.0 Ah at 1.0 A is two hours");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_energy_and_power_battery_is_read_too() {
        // What many other machines report: uWh and uW. Assuming one vocabulary
        // would have shown no estimate at all on those, silently and forever.
        let root = fake_battery(&[("capacity", "25\n"), ("status", "Discharging\n"),
                                  ("energy_now", "12000000\n"), ("energy_full", "48000000\n"),
                                  ("power_now", "6000000\n")]);
        let b = super::battery_at(&root).expect("a battery");
        assert_eq!(b.secs_left, Some(7200), "12 Wh at 6 W is two hours");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn charge_and_energy_batteries_are_converted_before_aggregation() {
        let root = fake_battery(&[("charge_now","2000000"), ("charge_full","4000000"),
            ("current_now","1000000"), ("voltage_now","10000000"), ("status","Discharging")]);
        let second = root.join("BAT1");
        std::fs::create_dir_all(&second).unwrap();
        for (k,v) in [("energy_now","90000000"), ("energy_full","100000000"),
                      ("power_now","10000000"), ("status","Discharging")] {
            std::fs::write(second.join(k),v).unwrap();
        }
        let b = super::battery_at(&root).unwrap();
        assert_eq!(b.percent,79, "110 Wh out of 140 Wh");
        assert_eq!(b.secs_left,Some(19800), "110 Wh at 20 W");
        std::fs::remove_file(root.join("BAT0/voltage_now")).unwrap();
        let b = super::battery_at(&root).unwrap();
        assert_eq!(b.percent,70, "without voltage, average the two percentages");
        assert_eq!(b.secs_left,None, "unlike units cannot yield an aggregate duration");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_battery_with_no_rate_files_still_reports_its_percentage() {
        // The estimate is the extra; losing it must not lose the row.
        let root = fake_battery(&[("capacity", "80\n"), ("status", "Charging\n")]);
        let b = super::battery_at(&root).expect("a battery");
        assert_eq!((b.percent, b.charging, b.secs_left), (80, true, None));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn this_machine_agrees_with_its_own_sysfs() {
        // Not a fixture: the real battery, checked against the files directly,
        // so the field names are known to match at least one real kernel.
        //
        // NOT BAT0's capacity. This asserted that, which is only the answer on
        // a machine with one battery -- and on the two-battery ThinkPad it
        // moved to, BAT0 read 5% while the machine held 63%. The test was
        // asserting the same assumption the code made, so it could not catch
        // it; it now recomputes the aggregate the same way a reader would.
        let Some(b) = super::battery() else { return };
        let (mut now, mut full) = (0f64, 0f64);
        let Ok(dir) = std::fs::read_dir("/sys/class/power_supply") else { return };
        for e in dir.flatten() {
            let p = e.path();
            if !p.file_name().map(|n| n.to_string_lossy().starts_with("BAT")).unwrap_or(false) { continue }
            let num = |f: &str| -> Option<f64> {
                std::fs::read_to_string(p.join(f)).ok()?.trim().parse().ok() };
            if let Some((n, f)) = num("charge_now").zip(num("charge_full"))
                .or_else(|| num("energy_now").zip(num("energy_full"))) {
                now += n; full += f;
            }
        }
        if full > 0.0 {
            let want = (100.0 * now / full).round() as u8;
            assert_eq!(b.percent, want, "aggregate over every cell, not the first one found");
        }
    }

    #[test]
    fn two_batteries_are_one_reading() {
        // A ThinkPad power bridge: a nearly empty internal cell and a fuller
        // removable one. Reading either alone is wrong; the machine holds the
        // sum of both over the sum of their capacities.
        let root = std::env::temp_dir().join(format!("null-bat2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for (name, now, full, status) in [("BAT0", "1080000", "23940000", "Not charging\n"),
                                          ("BAT1", "58970000", "71040000", "Charging\n")] {
            let d = root.join(name);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("energy_now"), now).unwrap();
            std::fs::write(d.join("energy_full"), full).unwrap();
            std::fs::write(d.join("status"), status).unwrap();
            // capacity is present and per-cell, exactly as the kernel reports:
            // 5 and 83. Neither is the answer.
            std::fs::write(d.join("capacity"), if name == "BAT0" { "5\n" } else { "83\n" }).unwrap();
        }
        let b = super::battery_at(&root).expect("a battery");
        assert_eq!(b.percent, 63, "60.05 Wh of 94.98 Wh is 63%, not 5% and not 83%");
        assert!(b.charging, "one cell charging means the machine is charging");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn discharging_counts_down_what_is_left() {
        // 2000 units at 1000 per hour is two hours.
        assert_eq!(battery_eta(2000.0, 4000.0, 1000.0, false), Some(7200));
    }

    #[test]
    fn charging_counts_up_to_full_not_down_from_now() {
        // The same battery, charging, is two hours from FULL, not from empty.
        assert_eq!(battery_eta(2000.0, 4000.0, 1000.0, true), Some(7200));
    }

    #[test]
    fn a_battery_that_is_not_moving_has_no_estimate() {
        // A rate of zero is what a full battery on the mains reports, and it
        // is the reading this machine gives -- dividing by it would be an
        // infinity dressed up as a time.
        assert_eq!(battery_eta(2917000.0, 2917000.0, 0.0, false), None);
        assert_eq!(battery_eta(2000.0, 4000.0, -5.0, false), None);
    }

    #[test]
    fn a_full_battery_that_is_charging_is_not_negative_time() {
        assert_eq!(battery_eta(4000.0, 4000.0, 1000.0, true), Some(0));
    }

    #[test]
    fn an_absurd_estimate_is_withheld_rather_than_printed() {
        // A rate rounded down to almost nothing produces "6d 04:11", which
        // looks like a reading and is not one.
        assert_eq!(battery_eta(4000.0, 4000.0, 1.0, false), None);
    }

    #[test]
    fn the_units_only_have_to_agree_with_each_other() {
        // uAh against uA, or uWh against uW -- both are a quantity over a
        // rate, so the same arithmetic serves.
        let by_charge = battery_eta(2_917_000.0, 2_917_000.0, 1_458_500.0, false);
        let by_energy = battery_eta(48_000_000.0, 48_000_000.0, 24_000_000.0, false);
        assert_eq!(by_charge, by_energy);
        assert_eq!(by_charge, Some(7200));
    }
}
