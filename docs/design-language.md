# The design language

How a nullLinux surface looks and reads, written so a new menu or panel can be
built without rediscovering it. This is the practical distillation; NULL.md is
the authority, and the section marks (§) point back to it.

## The one idea

Every visible surface is text in one palette, over one baked hero. There is no
second visual system — no theme engine, no icon set, no widget toolkit of our
own. A new surface is not *styled to match*; it is built from the same few parts
as everything else, so it matches because there was never anything else to be.

If a surface needs something this document does not give it, that is a question
for NULL.md, not a licence to invent.

## Colour

Seven roles, and nothing addresses colour any other way. They are **derived**
from a blackbody locus and written to every config from one source (§4.5, §4.8)
— **no hex is ever typed by hand**, in code or in a menu.

| role | is | today |
|---|---|---|
| `background` | the one ground, near-black, everywhere | `#05060a` |
| `neutral` | text | `#ffefe6` |
| `accent` | the current thing: selection, marks, headings | `#b9ccff` |
| `dim` | labels, the context line, anything secondary | `#ff7800` |
| `line` | a rule under a live control | `#232c40` |
| `error` | a failure, and only a failure | `#ff8000` |
| `warning` | underline emphasis | `#ffb161` |

**One background** (§7.1). The lifted `surface` tone is for genuinely raised
elements only — not for striping a list or boxing a control.

**Glyph carries structure, colour carries the remainder** (§4.3). The character
says the coarse thing; colour says the rest. Never encode the same fact twice.

## Type

**One typeface, two strikes** (§2.2): Terminus, at an interface strike and a
bake strike chosen for the panel. That is the whole type system for chrome.

**Chrome is Terminus and ASCII-only; content is a separate tier** (§8.10, §7.6).
A menu, a prompt, a label — chrome — is drawn in Terminus, so it may use only
glyphs Terminus has. A document, an email, a web page — content — is somebody
else's text and gets the document fonts. Never let content's freedom leak into
chrome: a clipboard picker shows arbitrary content, so it is measured against a
controlled store, not whatever was last copied (see Verification).

## Controls

- **A control is a mark and a rule, not a box** (§7.1). The live control takes
  ink and gets a rule under it. No filled or outlined rectangles — a toolbar of
  boxes is the failure this rule exists to prevent.
- **Words, not pictograms** (§7.1). Use the readable word. Punctuation pressed
  into service as icons (`>` for "repeat", a pair of brackets for anything) is a
  second icon set less legible than the first. If two controls both land on `x`,
  the vocabulary has admitted it ran out.
- **Where a pictogram is unavoidable, it is a glyph the font actually has** —
  never a private-use codepoint, which Terminus cannot draw and will show as
  nothing.
- **Rows mean pick one; a rule means write one.** The filter-picker is the
  control for choosing. For writing a line (a search term, an address) use
  `null_ask` in `lib/menu.sh`: the prompt, and one rule to write on beneath it,
  with filtering disabled so the rule stays put. The drawing is the affordance
  — no header ever says "type". A default sits already in the field, where
  Enter keeps it; nothing names it in prose.
- **The prompt is the verb.** An action picker's prompt names what Enter does
  — `install > `, `remove > `, `copy > `, `map > ` — so the picked row
  completes the sentence and no header explains the consequence. If a header
  is explaining what a control does, the control is wearing the wrong prompt.

## Menus

Every menu is **one filter-picker hosted in the column** (§7.4). The picker is
`choose` in `bin/null-menu` (and `pick_value` in `bin/null-settings`); both wrap
fzf through `lib/menu.sh`, which sets the vocabulary once:

```
pointer '>'      marker '*'      gutter ' '      info hidden
colours: fg=neutral bg=background  selected=accent  prompt/header=dim  rule=line
border: off inside the column (it already draws a frame); on where nothing else does
```

Do not restyle the picker per topic. Call `choose`/`pick_value` and inherit it.

### A row is a name, then dot leaders, then a value

The **name carries the row**. It is the first word, and it is what the case arm
matches on (`awk '{print $1}'`) — so the name is load-bearing and must not
change to retitle a row. After the name, a value or a short cue, aligned; the
column of names reads as a list at a glance.

A cue is **earned, not default**. Add one only where the name is this system's
own vocabulary (`learn`, `netconfig`, `trigger`, `setup`, `system`) or where a
value belongs there (a volume, a state). `apps`, `files`, `clipboard`, `player`,
`update` say themselves — leave them bare. A cue never describes implementation
("the PipeWire mixer — per-stream volume and routing" is three words of noise
around one word, `mixer`).

### The context line is the ONE thing, or nothing

§7.4 allows a dim line under the prompt "stating the one thing that topic can say
for itself." Read *one*. It is for the single fact a person could not guess and
would be caught out by:

```
update    reporting only -- apply with: null-update --apply
record    a recording stops with the same key that started it
hardware  absent devices are not listed
```

When the rows already say everything — which is most topics — the line is empty.
A header that restates the menu, explains the implementation, or cites a spec
section (§8.4, §9.1 — those live in the code, never on screen) is worse than
silence. Prose is the failure mode this whole document is a correction to.

### Report-first, and absent is stated

- **Report-first** (§8.4). A menu SHOWS state; it does not apply it. The flags
  that change something live on the command line, where typing them is a
  deliberate act rather than a highlighted row and a return key. `update` is the
  pattern: it lists, and says how to apply, and applies nothing.
- **Absent is stated, never an empty list** (§8.4). A topic with nothing to offer
  says so — `say "..."` draws a note, not a blank picker. A device that is not
  present is not listed at all (build the rows in a bash **array**, appending the
  present ones; never unquoted `$( ... && echo "a b c" )`, which word-splits a
  description into separate junk rows).

## Building a new menu topic — the checklist

1. Add a case arm to `bin/null-menu`; the name is the first word of each row.
2. Rows built with `choose` (or an array + `choose` if any are conditional).
3. A cue only where the name is not self-evident; a context line only for the
   one non-obvious fact, else `''`.
4. Show state; put any apply behind a command-line flag (report-first).
5. Absent → `say`, not an empty list. Conditional rows → array, never
   word-split substitution.
6. ASCII only. If you reach for a symbol, use the word instead.
7. No hex, no per-topic colours, no border toggling — inherit `lib/menu.sh`.

## Verification — run it, never read it

A surface is judged by running it and reading the codepoints it draws, never by
reading its config (§7.6). The instruments:

- `verify/check-menu-coverage.sh` — draws every topic in a pty and fails on any
  glyph Terminus lacks. It measures **chrome**, so content-bearing topics (the
  clipboard) run against an isolated, seeded store; a topic's verdict must not
  depend on the machine it runs on.
- `verify/check-commands.py` — every command a menu dispatches to must exist.
- `verify/check-a-person-can.sh` — a topic that offers a thing must have the
  thing behind it.

And it is verified **in null**, via `verify/in-guest.sh`, not on the machine
null is built on — a check that reads live state gives the wrong answer on the
wrong machine.
