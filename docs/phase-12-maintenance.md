# Phase 12 — Maintenance

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 12): *the report-first promise is enforced
structurally. Every measured claim in the delivered documentation states its
inputs.*

Run 2026-08-30. **Gate met.**

## The update component

`bin/null-update` covers the five channels §8.4 requires — packages, orphaned
packages, package cache, firmware, font caches. With no argument it changes
nothing.

Two of its rules earned their place immediately:

**Check a catalogue's freshness before reporting its verdict.** `lvfs` is
enabled on this machine and `/var/lib/fwupd/metadata` **has never been
created**, so `fwupdmgr get-updates` answers *"No updatable devices"* — which
reads as good news and actually means *I have nothing to compare against*. The
component reports `NO METADATA -- verdict meaningless` instead. This is exactly
the case the spec describes, live, on the first machine it ran on.

**A tool with no dry run cannot be asked.** `fc-cache` rebuilds whatever it
finds stale, so running it to find out answers the question by doing the thing.
Modification times are compared instead.

The first version of that comparison hard-coded `/var/cache/fontconfig`, which
does not exist on Fedora — the cache is `/usr/lib/fontconfig/cache` — so it
found no cache at all and reported the font tree as **56 years stale**. It now
reads the `<cachedir>` elements out of fontconfig's own configuration, which is
config parsing rather than a dry run, so it stays read-only. Guessing a path
and asking the tool are both wrong; reading its configuration is neither.

## Report-first, made structural

`verify/check-report-first.py` reads the **text** of every `report_*` function
and fails if a mutating command appears in one. A promise kept by remembering
is a habit, and habits are what a refactor at midnight quietly breaks.

It caught a real ambiguity on its first run: `dnf5 --refresh check-upgrade`.
Refreshing metadata *is* a write, but §8.4 explicitly sanctions "refreshing
metadata and reporting" — indeed it *requires* checking a catalogue's freshness,
which cannot be done without fetching. So dnf is judged by its **subcommand**,
not its name.

`verify/selftest-report-first.sh` plants violations and requires each to be
caught. **Its first version was vacuous**: `local label=$1 f="$(… $label …)"`
expands `$label` before the assignment takes effect, so every planted file
landed on the temp *directory*, `awk` failed, and the checker "failed" on a
missing file rather than on the violation. Eleven tests passed having tested
nothing — the precise failure the checker's own docstring warns about. It now
asserts the plant landed before trusting the result, and tests two structural
failure modes as well: an unreadable file, and a function whose end cannot be
found.

Current: 11 violations caught, 5 read-only forms correctly not flagged.

## The scene had drifted into three copies

The full suite surfaced a failure that had been hiding since the hero was
recomposed: **"3 of 3 levels FAILED — the shader does not match the reference"**,
with a 79% median luminance error.

The shader was correct. The *cross-validation* was comparing two different
black holes:

| | spin | inclination | T_inner |
|---|---|---|---|
| `bake.py` | 0.6 | 70 | 5000 |
| `render_kerr.py` | 0.6 | **80** | **20000** |
| shader's compiled defaults | **0.9** | **80** | **20000** |

The checker passed **no scene flags at all**, so the reference ran at `a = 0.6`
and the shader at `a = 0.9`. It had passed in Phase 8 only because the defaults
happened to match the settled values then.

Two fixes, the second with teeth:

- `bake/scene.py` owns the settled scene; every consumer takes it from there.
- **Scene parameters in the shader have no defaults.** A missing one is now a
  panic naming the file that owns it. A default is a second source of truth
  wearing a convenience disguise, and it fails silently by construction — the
  run succeeds, the numbers look reasonable, and they describe something else.

That change immediately caught a second bug: `repr()` of a numpy scalar is
`np.float64(3.83…)`, which the shader cannot parse. Failing loudly beats
defaulting.

Cross-validation restored: hit geometry **100.00%**, temperature median
**0.000%**, quantised glyphs **99.48%** identical with **0** cells differing by
more than one ramp level.

§10.3 now carries the rule.

## Six verifiers had drifted out of the suite

`verify/run.sh` opens by warning that a verifier not wired in here stops being
run the week after it was written. By Phase 12 six had done exactly that —
column zone, dwindle, keyboard, font substitution, and both report-first checks.
All are wired; the suite is 22 checks.

`verify/measure-*.sh` are deliberately **not** in it, and run.sh now says why:
they produce numbers, not verdicts, and a number has no pass/fail without a
threshold this system has not agreed.

## Measurement discipline

`docs/measurements.md` is the register: every figure with what it was taken
against, when, and how to re-take it. Every phase document now carries a banner
saying its figures are a record of that run rather than a claim about the system
now.

**One measurement was refused rather than reported.** The layer-shell harnesses
were asked for runtime cost while the session was locked, and returned
`animating: 0.00%` — because a surface under a lock surface receives no frame
callbacks, never draws, and burns nothing. `--force-animate` sets our flag; it
cannot make the compositor deliver callbacks.

That is §10.7's *"refuse to report a process that died as a flawless zero"* in
a new costume, and the rule generalises: **a surface that never drew must not be
reported as a flawless zero either.** Both harnesses now refuse to run under a
lock, and refuse an all-zero sample where a non-zero one was expected.

So the runtime figures are **absent from the register rather than stale in it**,
with the commands to take them recorded.
