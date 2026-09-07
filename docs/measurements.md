# Measurements

> **`nox` means two different machines in this file.** Every figure below was
> measured when it was recorded, and none has been rewritten. The machine was
> an i5-9300H with a GTX 1660 Ti and a 1920x1080 panel until the disk was moved
> into a ThinkPad T480 — 1366x768, Intel graphics, no discrete GPU — which is
> what `nox` is now. Where a measurement names the old hardware it is right
> about the hardware it was taken on, and says nothing about the machine
> nullLinux is going onto. The GPU figures in particular have no successor:
> the T480 cannot run the bake, which is why the hero ships prebuilt.

**Every number in this project is conditional on inputs that can change without
anyone noticing** (NULL.md §10.7). This file is the register: what was measured,
what it was measured *against*, when, and how to take it again.

A figure quoted anywhere else in `docs/` without inputs beside it is a bug in
that document, not a fact.

## The bench

| | |
|---|---|
| machine | `nox` — Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz |
| threads | 8 |
| kernel | 7.1.10-200.fc44.x86_64 |
| session | sway on Wayland, running as **root** (see deviations) |
| taken | 2026-08-30 |

## Scene — the inputs every image figure depends on

Read live from `bake/scene.py`, which is the one owner (§10.3):

```
  spin        0.6
  inclination 85.0
  half-width  32.0
  r_in (ISCO) 3.829069
  r_out       20.0
  T_inner     5000.0
  bands       7 (derived, all outside the ISCO)
  frames      240 at 24 fps — a 10.000 s loop
```

## Pipeline — taken 2026-08-30

Inputs: the scene above; master `/root/nulllinux-hdr-master-v4`, 240 frames at
640×180 cells, 4× supersampling; exposure black P1.0 / white P99.0 / γ0.6;
hysteresis 0.40; ramp `assets/ramp-bake.json` (16 levels, bake strike).

| target | grid | ink | ramp entropy | glyph churn | colour churn | wrap vs interior max |
|---|---|---|---|---|---|---|
| tty | 80×24 | 17.0% | 0.318 | 0.35 %/frame | 1.74 %/frame | 0.52% vs 0.83% (0.62) |
| logo | 40×16 | 16.2% | 0.305 | 0.28 %/frame | 1.31 %/frame | 0.47% vs 0.94% (0.50) |

Footprint of the wallpaper frame: **66% of frame width, 59% of height** (was
66% × 90% at 70°/28 M).

Loop closure is **exact** on every target: frame 0 reproduces byte-identically
from the final hysteresis state.

**Ink is now slightly BELOW the ≈20% target, and that is also a framing result**
(§4.2.1). The lit ceiling at this framing is **15.4%** — down from 33.4% at
70°/28 M — because inclination controls how much of the frame the subject
occupies as much as it controls the viewpoint. Coverage is held at 98.9%, so
essentially the whole subject is drawn; the frame is simply emptier by choice.

Lit ceiling against inclination, at a fixed 28 M half-width:

| inclination | lit cells |
|---|---|
| 70° | 33.4% |
| 82° | 22.7% |
| 85° | 19.7% |
| 88° | 16.8% |

Trace cost: **240 frames in 93.2 s**, downsample 31.0 s (0.525 s/frame), on the
GTX 1660 Ti Mobile. Inputs: 2560×720 rays/frame = 1,843,200; 3000 max steps.

## Cross-validation — taken 2026-08-30

Inputs: 80×24 grid, 2000 max steps, the scene above passed **explicitly to both
sides** (§10.3 — passing it to neither is how this check once blamed the shader
for a difference it did not cause).

| level | result |
|---|---|
| hit geometry | 100.00% agreement, 0 of 1920 cells differ |
| luminance | median 1.303%, p95 1.72% |
| temperature | median 0.000%, p95 0.00% |
| quantised glyphs | 99.48% identical; 10 differ by ONE ramp level; **0 by more** |

## Physics — taken 2026-08-30

All 11 analytic checks pass at `a = 0.6`, including both shadow edges at
**0.000%** against closed form. Inputs: `bake/validate.py`, FP64 numpy.

## Runtime cost — NOT RE-TAKEN

**Deliberately absent rather than copied forward.** The layer-shell surfaces
cannot be measured while the session is locked: a surface under a lock surface
receives no frame callbacks, draws nothing, and reports 0.00% — a number that
looks like success and means *not measured*. Both harnesses now refuse to run
in that state rather than print it.

To take them, on an unlocked session:

```
./verify/measure-render.sh                       # placeholder asset
CELLS=assets/target-2.cells ./verify/measure-render.sh   # what the wallpaper uses
./verify/measure-bar.sh
```

Both force the state being measured (`--force-animate`,
`RENDER_ASSUME_OCCLUDED=1`, `RENDER_ASSUME_BATTERY=1`), report the median of
5 runs with the range, state the scheduler-tick floor for the window, and
refuse to report a process that died — or a surface that never drew — as a
flawless zero.

## The column's idle panel and equaliser — taken 2026-08-31

Inputs: panel visible (desktop bare, nothing hosted), 30x60 cells, stats
sampled once a second; cava at 8 fps with 12 levels; 10–12 second windows, one
scheduler tick is a 0.08% floor.

| state | column | note |
|---|---|---|
| panel covered by windows | 0.17% | unmapped: it reads nothing at all |
| panel visible, no audio daemon | 0.80% | the spectrum says why, statically |
| panel visible, **equaliser live with constant sound** | **2.67%** | plus cava's own ~1.7–6% |
| bar, for comparison | 0.33% | |

**§10.7 warned about exactly this dependency** — "adding a single
audio-spectrum dependency can multiply a status surface's cost several-fold" —
and it was right. The first attempt polled cava's pipe as a wake source and the
column span at **99.75% of one core with no audio playing at all**: that pipe
reports itself ready whether or not a frame is in it. A descriptor that is
always ready is not a wake source, it is a busy loop with extra steps. It is
drained on the column's own 125 ms timer now, which is a rate this program
chooses.

The second reduction was asking cava for 12 levels instead of 16: six rows
cannot draw sixteen, so the extra resolution was frames differing in ways
nobody could see, each one a full redraw.

## The column's idle panel — superseded, kept for the comparison

Inputs: the panel visible (desktop bare, nothing hosted), sampling once a
second, 30x60 cells; 12-second window, one scheduler tick is a 0.08% floor.

| | |
|---|---|
| column, panel live | **0.75%** of one core |
| bar, for comparison | 0.33% of one core |

The column used to measure 0.00% because it redrew only on a change and
nothing changed. A live panel changes every second by construction, so this is
the cost of the feature rather than a regression to fix: it redraws 1800 cells
to the bar's 384, and the ratio is about right.

It still does not sample or draw when it is not visible -- hosting covers it,
and an unmapped surface returns before reading anything.

The only other runtime figures taken this session are coarse 2-second idle samples of
the *already-running* surfaces, which the lock does not invalidate because idle
is the state being claimed: render 0.50%, bar 0.00%, column 0.00% of one core.
A 2 s window has a 5% floor from one scheduler tick, so "0.00%" here means
"below the floor", not "zero".

## The network graph, and what sampling off screen costs

Inputs: `nox`, panel 30x60 cells, sampled once a second, 30-second windows read
from `/proc/<pid>/stat`. A 30 s window has a floor of about 0.03%.

The NET section became a five-row line graph with a scale that follows its own
window. That only means anything if the window is a real span of time, so the
history now advances whether or not the panel is on screen. The question was
what that costs.

| | |
|---|---|
| covered, before -- sampled nothing | 0.17% |
| covered, sampling EVERYTHING at 1 Hz | ~~1.17%~~ **0.45%** -- see below |
| covered, sampling only the three history series | **0.20%** |
| visible, drawing | 1.13% |

**The 1.17% figure was wrong and is withdrawn.** It is suspiciously equal to
the *visible* cost in the same table, and that is what it was: the panel was
mapped and drawing when it was taken, not covered. Re-measured twice at 0.47%
and 0.43%, with the covered state proved rather than assumed -- the focused
workspace was checked for windows before each run, because "covered" is a
property of the compositor's state and not of which command was typed last.

The conclusion it was used to support survives, but the honest version of it is
the per-call table below, which did not exist when this was written.

The middle row is the interesting one. A full sample is not four `/proc` reads:
it walks `/sys/class/hwmon` for a temperature, `/sys/class/net` for an
interface and `/sys/class/power_supply` for a battery. Those are text fields --
TEMP, LINK, BATT, DISK, UP -- and off screen nobody can read them, so off
screen they are not taken. What is taken is `/proc/stat`, `/proc/meminfo`,
`/proc/net/dev` and `/proc/diskstats`, which is what a sparkline always cost.

**The graph's history therefore costs 0.03% of a core.** That is the whole
price of the window meaning what its label says.

Reading those same text fields at 1 Hz rather than 3 Hz while VISIBLE was also
removed, on the same reasoning. It did not measurably help: 1.13% against
1.17%, which is inside the noise of this measurement, because the visible cost
is dominated by drawing and by the three-second process scan. The change is
kept because doing the work three times to display the same number is wrong
whether or not a profiler can see it -- but it is not claimed as a saving.

Sampling on the timer also fixed the arithmetic rather than only the coverage:
`elapsed` is now always about a second, where before the first sample after the
panel reappeared divided a burst by however long the panel had been hidden.

## Four graphs cost what one did

Inputs: `nox`, panel 30x60 cells, 30-second windows from `/proc/<pid>/stat`,
floor about 0.03%. Measured after CPU and MEM became line graphs and a disk I/O
graph was added -- graph rows went from 7 to 14, and the panel went from one
graph to four.

| | |
|---|---|
| visible, one graph (previous section) | 1.13% |
| visible, **four graphs** | **1.13%** |
| covered | 0.17% |

Unchanged, which is the useful finding: the visible cost is the three-second
process scan and the per-second redraw of the rows that changed, and doubling
the number of drawn rows did not move it. The extra history ring
(`/proc/diskstats`, already read on the cheap path) does not show above the
floor either.

So the constraint on how much of this panel is graph is legibility and space,
not cost. That is worth knowing before the next thing is added to it.

## What each reading costs, one at a time

Inputs: `render/examples/sysinfo-cost.rs`, 200 calls each, warm. Reports CPU
time and wall clock per call. Both are given because they say different things
here: these are `/proc` and `/sys` reads, and where wall clock greatly exceeds
CPU the call is BLOCKING on a device rather than working.

| reading | CPU | wall | at 1 Hz |
|---|---|---|---|
| cpu (`/proc/stat`) | 101 us | 103 us | 0.010% |
| memory | 58 us | 59 us | 0.006% |
| net_bytes | 101 us | 103 us | 0.010% |
| disk_io | 57 us | 58 us | 0.006% |
| load_average | 22 us | 22 us | 0.002% |
| uptime | 22 us | 22 us | 0.002% |
| disk_usage | 4 us | 4 us | 0.000% |
| battery | 93 us | 94 us | 0.009% |
| wireless_interface | 66 us | 67 us | 0.007% |
| wireless_quality | 0.2 us | 0.2 us | 0.000% |
| **temperature** | **1289 us** | **5710 us** | **0.129%** |
| top_processes | 5747 us | 5805 us | 0.575% |

The four history readings total 0.032% at 1 Hz, which independently confirms
the 0.03% measured for the rings from the outside.

`temperature` was the outlier, and its wall clock was four times its CPU, which
is the tell. Timing the nine sensors individually:

| sensor | per read |
|---|---|
| **nvme** | **4644 us** |
| **iwlwifi** | **1818 us** |
| acpitz | 352 us |
| coretemp (x5) | ~150 us each |
| pch_cannonlake | 101 us |

Two sensors were 85% of the cost, and neither is a file read in any meaningful
sense: one is an admin command to the SSD and one is a query to the wifi
firmware. The microseconds are not even the main objection. Asking an SSD its
temperature once a second stops it settling into a low power state, on a
laptop, to draw a line on a panel.

So the sweep is built around what a sensor costs, measured once at startup:
anything reading in under a millisecond is read every sample, and anything
slower is read once a minute and folded into the maximum. A millisecond is far
above any cached read and far below any device round trip, so it separates the
two without being tuned to either -- and no sensor is NAMED, which would have
made this machine's hardware into a rule (§0.2).

| | CPU | wall |
|---|---|---|
| temperature, before | 1289 us | 5710 us |
| temperature, after | **564 us** | **752 us** |

Seven and a half times faster on the figure that was blocking the panel's
125 ms timer, with the slow sensors still counted.

## Five filled graphs

| | |
|---|---|
| visible, four traced graphs | 1.13% |
| visible, **five filled graphs** | **1.10%** |
| covered, four series | 0.17% |
| covered, **five series** (temperature added) | **0.27%** |

Filling every cell of a graph rather than tracing a line through it costs
nothing measurable, and neither did the fifth graph. The 0.10% on the covered
row is the temperature series joining the always-sampled set, and it agrees
with the 0.056% per-call figure above once the extra ring is included.

Temperature has to sample at 1 Hz with everything else, not on the slower
visible-only cadence, because every graph on the panel is the same width: two
graphs at different sample rates drawn one above the other span different
amounts of time and nothing on either says so.

## BUSIEST, checked against ps

Not a timing. The list aggregates by program now, and an aggregate is easy to
get wrong in a way that still looks plausible, so it is checked against a tool
that is not this one:

```
ps -eo comm,rss --no-headers | awk '{r[$1]+=$2; n[$1]++} END {...}'
```

| | panel | ps |
|---|---|---|
| claude | x6, 1.90 GB | x6, 1.78 GB |
| sway | 128 MB | 123.04 MiB |
| render | 33.0 MB | 32.32 MiB |

The counts match exactly. The sizes agree once the two conventions are lined
up: the panel prints decimal (`si`, 10^6), `ps` prints KiB, and 123.04 MiB is
129.0 MB. The claude figure was still climbing between the two samples -- it
read 1.76, 1.81 and 1.90 GB over the same minute.

The first version of this aggregation was WRONG in a way that looked fine: the
CPU threshold was applied per process before summing, so a program's memory was
the sum over whichever of its processes happened to be busy in the last three
seconds. It reported "claude x3 1.31 GB" for a program that was six processes
and 1.76 GB. Comparing against ps is what found it.

## DISK, checked against df

Also not a timing. The panel drew "502 GB free" and now draws used against
total, which meant the definition of "used" started to matter.

| | panel | df |
|---|---|---|
| before | 7.14 GB used | 5.54 GB |
| after | **5.54 GB / 509 GB** | 5.6G / 510G (`df -H`) |

`statvfs` offers two frees and they are not the same number. `f_bavail` is what
an unprivileged process may use; `f_bfree` includes the filesystem's root
reserve, 1.61 GB here. The old code took total minus *available*, which counts
the reserve as used and is why it read a gigabyte and a half above df.

Taking total minus *free* matches df, and the reserve then appears in neither
figure -- which is how df presents it too. The old choice was right while the
panel drew "free", because available really is what you can use; it stopped
being right the moment the same call was used to draw "used".

## Per-core bars, swap and the SSID

| | |
|---|---|
| visible, five filled graphs | 1.10% |
| visible, **six graphs + per-core bars** | **1.20%** |
| covered, five series | 0.27% |
| covered, **unchanged** | 0.30% |

The 0.10% on the visible row is the second `/proc/stat` read the core sampler
makes, at 1 Hz. The covered row did not move, and should not have: the core
bars are an instantaneous spread rather than a series, so there is no history
to accumulate and nothing to sample while nobody is looking.

The SSID and swap cost nothing measurable. Both were already being paid for:
swap is in the `/proc/meminfo` the memory reading parses, and the SSID is in
the `iw` output the signal reading parses and threw away. The SSID is taken
ONLY on the path where `iw` already runs -- where the kernel publishes signal
in /proc/net/wireless there is no subprocess, and spawning one for a nicer
label would be paying exactly the cost §7.2 says not to pay.

## The per-core reading, checked by pinning

Not a timing. A distribution is easy to get plausibly wrong -- off-by-one in
core order, or the aggregate `cpu` line counted as a core -- and it would still
look like a reasonable picture. So the load was put where the answer is known:

```
taskset -c 2 timeout 30 bash -c 'while :; do :; done' &
taskset -c 5 timeout 30 bash -c 'while :; do :; done' &
```

An independent reading of /proc/stat over the same second gave
`0:6% 1:2% 2:100% 3:2% 4:1% 5:100% 6:3% 7:8%`, and the panel drew exactly two
full bars, at index 2 and index 5, with "peak 100%".

## The graphs, removed

James's verdict on the five filled history graphs was that they looked mid, and
they are gone. The reason is worth keeping: at twenty-six columns a history is
twenty-six samples, which is not enough of a series to show a trend and is more
than enough texture to make the panel look busy. The readings themselves are
what the panel is for, and they were the smallest thing on it.

| | before | after |
|---|---|---|
| visible | 1.20% | **1.03%** |
| covered | 0.30% | **0.20%** |

The covered figure is back where it was before the graphs, because the history
rings went with them and temperature went back behind the visible-only gate --
it was on the 1 Hz path only so its history would accrue unseen, and with no
history that was 0.06% of a core spent on a number nobody could look at.

The sensor work that the temperature graph paid for is kept: the sweep still
costs 0.75 ms of wall clock rather than 5.7 ms, and still does not wake the
SSD once a second. That was worth doing on its own terms.

## Hosted programs, and what the font can draw

Inputs: `verify/coverage.py`, 100x30, 3 seconds, this machine's interface
strike. The tool decides what the column may host, by measurement.

| program | printable cells | codepoints the font lacks |
|---|---|---|
| nmtui | 976 | **none** |
| wiremix (`--char-set` default / compat / extracompat) | 15 | none *-- see below* |

nmtui is clean and is hosted. The wiremix figure is NOT a result and is not
treated as one: fifteen cells is a blank screen, because wiremix cannot reach
PipeWire in a root session and never draws its interface. The tool's own
warning says a zero from an empty screen is not a measurement. So wiremix is
installed, wrapped and reachable, and its glyph coverage is UNVERIFIED until
this runs in a session with audio.

`--char-set compat` is passed anyway, on the same reasoning as btop's
`graph_symbol = "tty"`: it is the knob that program offers for exactly this,
and choosing it costs nothing if it turns out to have been unnecessary.

## Deviations

- ~~The idle ladder is not running.~~ **Withdrawn.** The sway config starts it
  with `exec_always`, so it runs by design and returns on every reload. It read
  `off` only because processes had been killed by hand while testing, and the
  note recorded that transient as a property of the system. It is on.
- **wiremix's glyph coverage is unverified.** It cannot start without a
  PipeWire session, so `coverage.py` measured a blank screen. Re-run
  `python3 verify/coverage.py --cols 100 --rows 30 --seconds 3 --json --
  wiremix --char-set compat` once audio works.
- **This machine has no keyboard backlight.** `machine probe kbd-backlight`
  finds no LED, so the settings panel does not draw the row. The control is
  written and will appear on a machine that has one; it is untested against
  real hardware here.
- **The session runs as root.** PipeWire refuses to connect, so every audio
  reading is `--` and the audio component cannot be exercised. A real user
  `james` (uid 1000) exists and is unused. Not in the spec, so not treated as
  a plan item — but it is the largest gap between this and a daily desktop.
- **One ordinary kernel is installed**, so the rescue entry is the only
  fallback (§9.6 assumes several).
- **Phase 10's gate is unmet**: it requires confirmation on real boots, which
  cannot be done from inside a running session.
- **Phase 9's off-machine backup is outstanding**: the USB SSD is not attached.

## The hero bake, measured

Inputs: nox, i5-9300H, GTX 1660 Ti via NVK (the open-source Vulkan driver, not
NVIDIA's). 240 frames, 640x180 cells, 4x supersampling -- 2560x720 = 1,843,200
rays per frame, 442,368,000 in total, each integrated by RK4 for up to 3000
steps.

| stage | wall clock |
|---|---|
| build the GPU tracer (`kerr-gpu`, once) | 58.9 s |
| **bake** -- trace 94.3 s + downsample 31.1 s | **127.0 s** |
| tone sweep (`tune`) | 24.6 s |
| quantise | 13.8 s |
| derive every target | 42.9 s |
| **hero pipeline, total** | **208 s -- three and a half minutes** |
| the same, cold, including the tracer build | 267 s |

Peak resident memory during the bake: 120 MB. CPU utilisation 37%, which is
the tell that it is GPU-bound and that the CPU is mostly waiting.

Intermediate output: `assets/master.hdrcells` is 423 MB across 240 frames.
That is the artefact worth keeping (§5.1) -- tone, colour and quantisation all
re-run from it in about 80 seconds, so the curve is re-tunable without ever
re-tracing.

**THIS SETTLES A DESIGN QUESTION.** §5.7 assumes the bake is too
expensive to run at install time and that shipping prebuilt assets in the
package was therefore mandatory. At three and a half minutes it is not
mandatory; it is a convenience. A machine with a working Vulkan GPU can bake
its own hero during installation, and prebuilt assets are for machines that
cannot -- headless installs, virtual machines, and anything without a driver.

What is NOT measured, and matters: this is a discrete GPU. The cost on Intel
integrated graphics alone, and on a machine with no Vulkan device at all, is
unknown. The second case may not be a slow bake but no bake, in which case
`--skip-hero` and shipped assets are the only paths.

## The tone curve is swept, not remembered

Appendix A lists the black point, white point and gamma as "re-tuned per
emission model" rather than as settled constants, so `null-build` sweeps them
and feeds the result to the two stages after it, rather than carrying last
run's numbers. This bake chose `--black-pct 0 --white-pct 99.0 --gamma 1.0`:
15.4% ink at 100% coverage.

## The bake without a GPU

The guest has no graphics hardware at all -- no render node, only `card0` --
and Mesa's software Vulkan, llvmpipe, on 4 vCPUs. That is the case §5.7 says
prebuilt assets exist for, and it had never been measured.

| | nox (GTX 1660 Ti, NVK) | guest (llvmpipe, 4 vCPU) | ratio |
|---|---|---|---|
| build `kerr-gpu` | 58.9 s | 78 s | 1.3x |
| trace, per frame | 0.39 s | 28.27 s | **72x** |
| trace, 240 frames | 94.3 s | ~113 min (extrapolated from 4) | |
| cross-validation (80x24) | -- | 93 s | |

**So the answer is two hours, not two minutes.** A machine with a working GPU
can bake its own hero during installation; a machine without one cannot be
asked to. Prebuilt assets in the package are therefore NOT optional for the
ISO -- they are what makes installation possible on hardware with no Vulkan
device beyond llvmpipe, which includes most virtual machines and any headless
install.

## The shader agrees with the reference on a driver it has never seen

`check-kerr` passes in the guest, and this is a stronger result than it was on
nox. The FP32 WGSL compute shader was developed against NVK; here it ran on
llvmpipe, a completely different implementation, and was compared against the
FP64 numpy reference:

| | |
|---|---|
| hit geometry | 100.00% agreement, 0 of 1920 cells differ |
| luminance | median 1.303%, p95 1.71% |
| temperature | median 0.000%, p95 0.00% |
| quantised glyphs | 99.74% identical; 5 of 1920 differ by ONE adjacent ramp level, 0 by more |

Agreement across two unrelated Vulkan drivers is evidence the shader is
correct rather than evidence that one driver is self-consistent, which is all
a single-driver test could ever show.

## The master is deterministic, demonstrated

§5.6 requires the bake to be run twice and compared, and says that with
regular-grid supersampling -- which is what `--ss 4` is -- the correct standard
is BIT-IDENTITY rather than agreement to three significant figures. That was a
Phase 9 gate and it had never been closed.

Two full 240-frame bakes on nox:

| | |
|---|---|
| frames | 240 vs 240 |
| `diff -rq` | no differences |
| sha256 over the whole master | `ea75ec286c941f1c...` both runs |

So the hero is the same artefact on every machine that ever builds it, and the
raytrace is a thing that happens once in the life of the project rather than
once per installation.

## What ships, and what it costs to install

| | |
|---|---|
| source tarball | 364 kB |
| prebuilt tarball | 8.6 MB |
| **the RPM** | **9.1 MB** |
| `dnf install` on a clean Fedora | 117 s (mostly dependencies) |
| **first boot** | **1 second** |

The prebuilt set is 13 MB on disk: the quantised hero for all NINE bake
strikes, every strike's atlas and ramp, the palette, and the palette-derived
surfaces -- the compositor's colours, both GTK themes, foot's configuration,
the shell's, and the icon theme.

Nine rather than four. Four covers the strikes twelve common panel sizes
select, and shipping four would have saved four megabytes while keeping a
fallback path for the rest. Since the master is provably identical everywhere,
there is no reason for any machine to bake, and nine leaves no path to get
wrong.

The HDR master is NOT shipped: 423 MB, an intermediate (§5.1), and everything
downstream of it is in the package already.

**Verified on a machine that has none of what the bake needs:** no cargo, no
rustc, no numpy, no pillow, no render node in /dev/dri. The desktop starts --
column, bar and wallpaper renderer all running, no errors -- and draws the
hero. Its atlas is 34,618 bytes, the 8x16 one its 1280x800 panel selected;
nox's is 48,034, the 10x18. Same package, different strike, nothing configured
by hand.

## The software-Vulkan bake is not just slow, it is unreliable

The full 240-frame bake on llvmpipe failed: `kerr-gpu` died with SIGSEGV after
48 frames, 1970 s in, with 1 GB of 3.9 GB memory used -- so not exhaustion.
Re-running the same batch at a smaller size succeeded twice, so it is flaky
rather than deterministic at that frame.

This is a Mesa problem rather than a nullLinux one, and shipping the hero makes
it moot. It is recorded because it turns "a machine without a GPU would take
two hours" into "a machine without a GPU may not finish at all", which is a
stronger reason for the package to carry the hero than the timing was.
