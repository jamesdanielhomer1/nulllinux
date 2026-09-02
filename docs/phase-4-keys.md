# Phase 4 — The compositor, the keys, and the binding verifier

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 4): *the verifier passes, is validated against a
planted duplicate, and every binding carries a description. The generated keys
list is read live.*

Built 2026-08-29. **The verifier was written before the keys**, so it was never
retrofitted onto a set that already contained a collision.

## Gate evidence

| requirement | result |
|---|---|
| verifier passes | 63 bindings, no key bound twice, all described |
| validated against a planted duplicate | 6 self-test cases, all behave as required |
| every binding carries a description | enforced; the audit fails without one |
| keys list read live | `bin/null-keys` lists all 63 from the loaded configuration |
| compositor accepts the configuration | `sway --validate` reports no errors |
| nothing spawns floating (§8.2) | 0 floating windows on the live desktop |

## The finding: `get_config` does not expand includes

§8.1 said the compositor's configuration query "reflects includes", making it
strictly better than reading the file from disk. **That was wrong**, and it was
caught by testing the claim rather than trusting it: a binding planted in an
included file did not appear in the query's output.

It matters on this machine specifically. The distribution's configuration ends
with an include, and behind it sit four files of real bindings — brightness,
media, screenshot, volume:

```
visible to get_config    : 63
resolved by following includes : 81
```

An audit built on the query alone would have reported a clean set while
**18 real bindings sat outside it, unaudited and free to collide.**

So the verifier parses the configuration and follows includes itself,
reproducing the compositor's own semantics — including the command-substitution
form the distribution uses to assemble a layered path list. §8.1 and §10.4
corrected.

## Three parsing details that decide whether the check catches anything

- **Normalise the chord before comparing.** `$mod+Shift+h` and `Shift+Mod4+H`
  are the same binding. Variables are resolved, modifiers sorted, everything
  case-folded. Without this the duplicate compares unequal and is missed — and
  the self-test covers exactly this case.
- **Scope by mode.** The same key in two binding modes is not a collision.
  Treating it as one makes the check cry wolf until it is ignored, which is
  worse than not having it.
- **Join line continuations first.** The distribution's binding files wrap
  commands across lines with a backslash; parsed naively, each continuation
  reads as a binding of its own and the audit reports collisions between
  fragments of single commands. Before this fix it reported a false duplicate
  in `60-bindings-volume.conf`.

## `sway --validate` exits 0 while reporting errors

Worth recording because it is exactly §10.1 rule 1. The first generated colour
file was wrong — sway's `set` takes the **rest of the line** as its value, so a
trailing comment became part of the colour and every use expanded to a
paragraph:

```
Invalid client.focused command (expected at most 5 arguments, got 29)
```

Four errors reported, **exit status 0**. `verify/check-sway-config.sh` exists so
that the distinction between output and status is made once rather than
forgotten at each call site. The comment now goes above the `set`, not on it.

## Decisions

**The distribution's binding files are deliberately not included.** The two
systemd session files are, by literal path, because they set up the user
session and the portal. The binding files are not: this system owns its keys,
and importing an undescribed set would guarantee both collisions and bindings
that cannot appear in the keys list.

**Colours are generated from the palette**, not typed. `bake/export_theme.py`
emits `colours.conf` from `assets/palette.json`, labelling each role with
whether it came from the physics or was chosen. Derived, so not committed.

**The focused window is a rule, not a box** (§7.1): `default_border none`, with
the focused window distinguished by its accent-coloured rule.

## Deviation

**Hardware keys have no readout yet.** §8.3 requires that a key changing
something invisible shows one, and §7.5 specifies it as a notification with a
stack tag drawn on the ramp. The notification daemon is Phase 6, so volume,
brightness and mute are bound to the raw action for now. Recorded here rather
than left as a silent gap; it closes in Phase 6.

## Gate

**MET**, with the hardware-key readout recorded as outstanding.
