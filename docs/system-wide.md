# The desktop belongs to the machine, not to an account

The first attempt at moving off root put the checkout in `/home/james/nullLinux`.
That works for james and for nobody else: a second account would have had to
copy it, and the copy is where things drift. It was the wrong shape, and it was
replaced.

## Where everything lives now

The checkout is `/opt/nulllinux` — root-owned, group `nullLinux`, `2775` so the group can
maintain it without `sudo` for every edit, and world-readable because every
session reads from it.

Each piece is installed where **the system already looks**, by
`bin/null-install`:

| piece | where | why there |
|---|---|---|
| compositor | `/etc/sway/config` | what sway reads when a user has no `~/.config/sway/config` |
| GTK theme | `/usr/share/themes/nulllinux` | a per-user `gtk.css` exists in one home; a theme is everyone's |
| icons | `/usr/share/icons/nulllinux` | not `~/.local/share/icons` |
| settings keys | `/etc/dconf/db/local.d/00-nulllinux` | this machine's dconf profile already reads `system-db:local`, so they are **defaults**, not writes into one person's database |
| terminal, notifier, monitor | `/etc/xdg/{foot,mako,dunst,btop}` | `XDG_CONFIG_DIRS` defaults to `/etc/xdg`, which every user reads |
| file manager | `/etc/xdg/xfce4/xfconf/…/thunar.xml` | xfconf's own system defaults |

Every one of these is a **default a user can still override** by writing their
own. That is deliberate: a fallback that can be diverged from is an escape
hatch, and one that is forced into every home directory is not.

## Verified on an account that had never existed

A user was created with an empty home, checked, and deleted:

```
~/.config          (nothing)
sway config    ->  include /opt/nulllinux/config/sway/config
gtk theme      ->  'nullLinux'
icon theme     ->  'nullLinux'
foot config    ->  /etc/xdg/foot/foot.ini
```

Its sway configuration validated, the binding audit passed on it — 74
bindings, none doubled — and every file the session needs was readable.

**This session then proved it the other way.** Root's own per-user links were
deleted and sway reloaded, so the running desktop is now driven by
`/etc/sway/config` like any other account. All four surfaces came back from
`/opt/nulllinux`.

## What is still per-user, and why

**The browser chrome, and only that.** Firefox reads `userChrome.css` from
inside a profile, and a profile belongs to a person; there is no system-wide
equivalent. `bin/null-firstrun` does that one thing and is optional — skip it
and the browser is simply left alone.

`bin/null-link` remains for a user who wants their own copy of the
configuration to diverge from. It is no longer part of setting the machine up.

## Audio

This is why any of it happened. PipeWire refuses to run as root, so a root
session reads `--` for every audio value. Any ordinary account gets a working
audio daemon; verified by `wpctl` answering as a non-root user.
