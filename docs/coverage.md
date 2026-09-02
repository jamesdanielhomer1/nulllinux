# What the column may host — the measurement

NULL.md §7.3: *what the column will and will not host is decided by
measurement, not taste.* §10.5 specifies the measurement and requires this
record. Taken 2026-08-29 with `verify/coverage.py`, on a pseudo-terminal of
exactly the size the column would give each program.

## As shipped, before any configuration

| program | size | bytes/2s | distinct escapes | scroll ops | unrenderable |
|---|---|---|---|---|---|
| fzf | 55x56 | 8 040 | 9 | 0 | **2 distinct, 6 cells** |
| btop | 84x56 | 62 937 | 8 | 0 | **22 distinct, 645 cells** |

**fzf's two are exactly the ones §7.4 predicts.** `U+258C ▌` is the **gutter** —
the empty column beside every line that is *not* current, so it draws on every
visible row at once, which is why a comment naming the pointer, marker and
scrollbar is precisely the comment that omits it. `U+283C ⠼` is one frame of
the **braille loading spinner**, the one §7.4 says hides longest.

**btop's 645 cells are its shipped defaults**: 528 of them are `U+28C0 ⣀`
alone, from braille graphs, plus rounded corners `U+256D..U+2570` which this
console font does not carry.

## After configuration

| program | unrenderable | what remains |
|---|---|---|
| fzf | **2 cells, 1 distinct** | `U+2807 ⠇` — one frame of the spinner during a slow list |
| btop | **3 cells, 2 distinct** | `U+2074 ⁴`, `U+21B5 ↵` — neither is in Terminus at any size |

That is 3 unrenderable cells out of **20 998** drawn, or 0.014%.

`config/fzf/flags` and `config/btop/btop.conf` carry the fixes, each with the
measurement that motivated it. The remaining fzf glyph has an upstream fix
(§7.4): build slow lists into a variable so the picker never enters its loading
state at all.

## Decision

**Both are hosted.** Neither needs glyphs the font cannot supply in any
quantity that matters.

## Column widths, each justified by measurement (§7.3)

| cells | px | why |
|---|---|---|
| 30 | 300 | the instrument column |
| 65 | 650 | the longest live keys row is 63 characters, plus two walls |
| 82 | 820 | **btop refuses below 80 columns**, plus two walls |

btop's floor was found by bisection, not assumed. With the shipped box set
(`cpu mem net proc`) it draws 123 cells at 76 columns — its "terminal too
small" message — and 16 527 at 80.

## The verifier had a bug that would have invalidated its own results

The child environment was built and then **discarded**: `execvp` ignores it,
where `execvpe` does not. So `TERM` was inherited rather than set, and
`XDG_CONFIG_HOME` never reached the program — meaning btop read its *real*
configuration while the tool reported it had been given a scratch one.

It surfaced as btop appearing to ignore a configuration that was plainly on
disk with the right contents, which is the shape §10.1 is entirely about. The
fix changed btop's count from 645 cells to 3.

## A zero is not always a result

The first configured fzf run reported **0 unrenderable from 21 printable
cells**, because shell quoting had mangled the flags and fzf never drew. The
tool says so rather than reporting the zero as a pass — a count taken from a
screen with nothing on it is not evidence (§10.5).
