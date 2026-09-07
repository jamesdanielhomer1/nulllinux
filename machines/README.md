# machines/

A machine profile lives here, named after the machine's hostname:
`machines/<hostname>.conf`.

**None is committed, and none ships.** A profile is *generated* from the
hardware by `machine generate` — the output, its geometry, and the two font
strikes derived from it — so committing one would put a measurement of one
particular panel into the history of a distribution meant for any panel (§5.7).
`bin/machine` selects a profile **by hostname**, so a profile that travelled in
the package would be found by any installed machine sharing the build host's
name, and used instead of one derived from that machine's own screen.

It is derived on the first boot that has a display, and
`nulllinux-machine-sync` re-derives it on any boot where the recorded hardware
and the real hardware disagree.

```
machine generate        write machines/$(hostname).conf from the detected output
machine show            everything in it, plus what is probed at runtime
machine check-profile   does the recorded profile still match the hardware?
machine check-grid      does the grid fit this panel, and what is unreached?
```

---

This file exists because the directory has to. Git does not track empty
directories, so removing the last profile from here removed `machines/` from
`git archive` — and the RPM's `%install` copies it by name:

```
cp: cannot stat 'machines': No such file or directory
```

The package build was the only thing that noticed. Every check passed.
