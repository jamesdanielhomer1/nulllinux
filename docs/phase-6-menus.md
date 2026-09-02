# Phase 6 — Menus and components

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 6): *every menu topic audits at zero unrenderable
codepoints, or is explicitly not hosted with its count recorded as the reason.
The idle ladder's stage ordering is enforced by the tool that edits it.*

Built 2026-08-29, settings / find / idle ladder first as §11 directs.

## Gate evidence

| topic | unrenderable | printable |
|---|---|---|
| main | **0** | 7 263 |
| settings | **0** | 6 985 |
| keys | **0** | 6 979 |
| power | **0** | 7 011 |
| audio | **0** | 6 992 |
| network | **0** | 6 962 |
| find | **0** | 7 115 |

None of these zeros is the "nothing drew" case — every topic drew ~7 000
cells, and `verify/check-menu-coverage.sh` fails a topic that draws under 200
rather than reporting its zero as a pass.

**The idle ladder enforces its own ordering.** Setting the lock past the
screen-off drags the later stages up *and says that it did*:

```
$ null-idle set lock 400
set lock to 400s
dragged the later stages to keep the ladder in order:
  screenoff -> 430s
```

## Every unrenderable glyph was the same thing

The first audit found braille on four of seven topics — and every single
codepoint was in `U+2800`–`U+28FF`. It is fzf's **loading spinner**, exactly
the one §7.4 says hides longest.

`network` had the most, ten frames against one elsewhere, and the reason is
diagnostic: it was piping `nmcli device wifi list` — which forces a *scan* —
straight into the picker, so fzf sat in its loading state longest of all.

Two fixes, both the ones §7.4 prescribes:

- **Build slow lists into a variable** so the picker never enters its loading
  state. Applied to keys, audio, network, settings and find.
- **The spinner's own fix is upstream**, and in this version of fzf it exists:
  `--info=hidden` removes the line the spinner draws on. §7.4 says it
  "sometimes has no option to change it" — here it does. The cost is the match
  count, which is a fair trade for never drawing a banned glyph.

`network` additionally reads the scan the daemon already has (`--rescan no`)
rather than forcing one on every open, and offers an explicit rescan instead.

## The binding verifier earned itself again

Adding the menu keys bound `super+space` a second time — it was already `focus
mode_toggle`. The audit caught it **before the reload**:

```
KEY BOUND 2 TIMES: super+space in mode 'default'
  config:142  focus mode_toggle
  config:229  exec ... --send open main
  (the compositor keeps the LAST one, silently)
```

Worth noting that **`sway --validate` passed** on the same file. The compositor
does not consider a duplicate binding an error; it silently keeps the last. Only
this audit sees it.

## Shell findings

**A function returns the status of its last command.** `stage_default` ended
with a failed comparison, so it returned 1 — and under `set -e` a command
substitution assigning from it took the whole script down. The idle tool
printed *nothing at all* and looked as though it had passed. Both helpers now
end with an explicit `return 0`.

This is the same family as the broken-pipe finding in §10.1: a shell construct
that turns a success into a failure status, where the symptom is silence.

**A space-valued flag cannot survive word-splitting.** `--gutter=' '` passed
through a `$(...)` split into fragments, and fzf rejected it with "gutter
display width should be 1" — which reads as fzf being fussy rather than as the
quoting being wrong. The flags are an array now.

## Machine findings

**PipeWire will not run as root.** `ConditionUser=!root was not met`. This
session is uid 0, so the audio daemon cannot start and every audio reading is
honestly `--`. The audio hardware is present; the daemon is refusing by design.
Recorded rather than worked around — running the desktop as root is the cause,
and that is a decision to revisit, not a bug to patch.

**dunst already owns the notification bus**, so mako could not take the name
("Failed to acquire service name: File exists"). §7.5 asks for *the*
notification daemon, not a particular one, so dunst is configured instead and
mako was removed. `null-osd` sends both daemons' stack-tag spellings, because
each ignores the other's and sending both is one line where detecting which is
running would be a second thing to keep true.

## Phase 4's deviation is closed

Hardware keys now show a readout. `null-volume` and `null-brightness` change
the value through whatever owns it, then **re-read from that owner** and report
what it says — not what they just tried to set. The meter is drawn on the same
ramp everything else uses, and the daemon's progress-bar hint is never passed,
because that draws a filled rectangle (I1).

`null-brightness` exits silently on a machine with no backlight rather than
reporting a value for hardware that is not there.

## What was built

| path | what |
|---|---|
| `lib/menu.sh` | shared picker chrome, as an array |
| `bin/null-menu` | the topics |
| `bin/null-settings` | owns nothing; loops and re-reads; absent rows not drawn |
| `bin/null-find` | matcher off, finder re-run per keystroke, paths relative |
| `bin/null-open` | best available tool per role; reveal is a different verb from open |
| `bin/null-idle` | the ladder, ordering enforced |
| `bin/null-osd` | the readout, meter on the ramp |
| `bin/null-volume`, `bin/null-brightness` | hardware keys with readouts |
| `bin/null-screensaver` | pidfile, identity confirmed before signalling |
| `config/dunst/dunstrc` | notification chrome, progress bar off |

## Gate

**MET.**
