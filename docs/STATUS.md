# Status — the plan, phases 0 to 12

Taken 2026-08-30. Figures and their inputs: [measurements.md](measurements.md).

**Every phase gate that can be met from inside a running session is met.** Two
remain, and neither is work — one needs a reboot, one needs a drive.

| phase | | gate |
|---|---|---|
| 0 Machine facts | **met** | profile derived, nothing stored that can be probed |
| 1 The two abstractions | **met** | one package component, one machine profile |
| 2 Font, ramp, palette | **met** | ramps monotonic per strike, font hash guarded |
| 3 The renderer | **met** | delta blits, shm cycling, one sleep |
| 4 Compositor and keys | **met** | no key bound twice; audit follows includes |
| 5 Bar, then column | **met** | 0.00% idle; zone tracks the animation |
| 6 Menus and components | **met** | every topic drawable from the atlas |
| 7 Terminal surfaces | **met** | every surface draws only glyphs the font has |
| 8 The real hero | **met** | 11 analytic checks at 0.000%; shader matches reference |
| 9 The bake | **all but backup** | bakes reproducible, all targets derived — **off-machine copy outstanding** |
| 10 Root-owned surfaces | **all but reboot** | console and greeter live and verified; splash built and verified — **needs real boots** |
| 11 Third-party | **met** | font probe discriminates, deslop default-deny, hero in empty states |
| 12 Maintenance | **met** | report-first structural, every claim states its inputs |

Phase 13 (`sol`) is **cut**: there is one hero, `null`, for the whole
distribution. Per-machine heroes made the system's identity depend on which
box it was installed on, and doubled everything that must be baked and shipped.

## Verification

`./verify/run.sh` — 24 checks, including six that had drifted out of the suite
and are now wired back in. Menu coverage derives its topics from the menu
itself: **28 topics, 27 drawing clean**, the 28th recorded with its reason.

## Since the plan: Omarchy alignment

Requested after Phase 12 and documented in
[omarchy-alignment.md](omarchy-alignment.md): Omarchy's bindings and menu tree,
only two layouts (dwindle and fullscreen), and the file manager in both halves.

That work found two silent defects worth naming here, because neither was
visible to any existing check:

- **The menu bindings had never worked.** The column hosted two topics and
  every other one hit a default arm that returned. The coverage verifier ran
  each topic in its own pty, so it proved they *draw* while saying nothing
  about whether anything could *reach* them.
- **The column's terminal printed part of every charset designation.**
  `ESC ( B` is three bytes and only the `(` was consumed, so hosted output came
  out sprayed with stray capital Bs.

§8.4's component list stands at **13 of 16**. Absent: player, calendar,
clipboard.

## The two open gates

**1. Reboot (Phase 10).** Nothing in this build has ever been verified across a
reboot; everything was checked inside one long-lived session.

```
  reboot into the rescue entry once, confirm it reaches a shell
  bin/null-system plymouth --apply --fallback-verified
  reboot normally: splash -> greeter -> login -> lock
```

The splash deliberately refuses to install until you confirm the first step,
because it is the only component that can leave the machine unbootable and this
machine has **one ordinary kernel**, so the rescue entry is the only fallback.

**2. Off-machine copy (Phase 9).** No removable drive is attached. The master
is manifested and the copy is one command, which verifies the destination
rather than trusting it:

```
  bin/null-backup                 # reports; copies nothing
  bin/null-backup /run/media/...  # copies, then checksums the COPY
```

It refuses a destination on this machine's own disk, because that does not
satisfy the gate.

## Known deviations

- **The session runs as root.** PipeWire will not connect, so audio readings are
  `--` and the audio component cannot be exercised. A user `james` (uid 1000)
  exists and is unused. Not a plan item — the spec says nothing about which
  account the desktop runs as — but it is the largest single gap between this
  and a daily driver, and the recommended next piece of work.
- **One ordinary kernel**, so the rescue entry is the sole fallback (§9.6
  assumes several). Recorded rather than worked around.
- **Runtime CPU figures are absent, not stale.** They cannot be taken under a
  session lock without being false zeros, and the harnesses now refuse instead
  of reporting them.
