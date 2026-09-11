# Licensing

This file records the materials included in nullLinux and the remaining
release checks. It does not determine ownership or provide legal advice.

## Shipped materials

| Material | Declared license | Notices and provenance |
| --- | --- | --- |
| nullLinux project code | MIT | `LICENSE` |
| Terminus font and derived glyph atlases | OFL-1.1 | `licenses/OFL.txt`, copied from `terminus-fonts`; copyright 2020 Dimitar Toshkov Zhekov, Reserved Font Name "Terminus Font" |
| Adwaita icons recolored for the nullLinux theme | LGPL-3.0-only OR CC-BY-SA-3.0 | Exact upstream notices and GNOME Project attribution in `licenses/adwaita/` |
| Rust crates linked into the renderer executables | MIT alternatives selected | Generated `cargo/MANIFEST.json` and per-crate license files in the RPM license directory |
| Bundled native zstd and generated Wayland protocols | BSD-3-Clause; MIT and HPND-sell-variant | Exact native source files and protocol XML retained with the Cargo notices |
| Statically linked Rust standard library | MIT and Unicode-3.0 | Fedora toolchain notices plus the verified vendor notice bundle in `licenses/rust-stdlib/` |
| Other packages included in an ISO | Each package's own license | Installed package notices and the image's package/source inventory |

The atlases contain glyph bitmaps extracted from Terminus by
`bake/bake_atlas.py`; the ramps measure that font's ink coverage. The `.cells`
animations contain glyph indices and colors rather than font bitmaps. Keep the
font notice with the derived atlases and review the OFL Reserved Font Name
requirements if distributing them as a modified font.

Adwaita artwork is attributed to the [GNOME Project](https://www.gnome.org/).
The upstream [Adwaita Icon Theme repository](https://github.com/GNOME/adwaita-icon-theme)
offers the license alternatives above. The 0.1.0-2 stabilization prebake used
Fedora's `adwaita-icon-theme-50.0-1.fc44`; `bake/make_icons.py` recolors its SVG
and PNG artwork, renames the theme, and sets its inherited themes. The exact
source package and modification details are recorded in
`licenses/adwaita/NOTICE`. The derived icons retain the upstream license
alternatives.

## RPM and ISO contents

The RPM declares
`MIT AND BSD-3-Clause AND HPND-sell-variant AND Unicode-3.0 AND OFL-1.1 AND (LGPL-3.0-only OR CC-BY-SA-3.0)`.
The RPM's `%license` entries install the project, font, Adwaita, and collected
dependency notices. This expression records the selections for the reviewed
build; it is not a claim that dependency metadata alone captures every
embedded component.

During `%build`, `packaging/cargo_licenses.py` reads locked, offline Cargo
metadata for `x86_64-unknown-linux-gnu`. The reviewed renderer graph contains
53 external crates, including 39 runtime crates. Every runtime crate offers
an MIT alternative. The collector includes build/proc-macro notices too and
labels that distinction in its manifest. Native zstd is covered by its BSD
alternative; embedded protocol copyright blocks require both MIT and
HPND-sell-variant terms. Exact native source and protocol files preserve the
additional copyright holders that crate-level license files omit.

The collector also verifies the fourteen pinned standard-library vendor
versions against Fedora's installed `cargo-vendor.txt`, and copies the build
host's Rust license, library copyright, and Unicode terms. The output records
the compiler version, lock checksum, crate source/checksums, selected licenses,
and notice-file hashes. Updating the lockfile or toolchain requires reviewing
embedded material and refreshing the relevant notice inventory; a successful
collector run is a completeness check for these reviewed inputs.

The ISO includes additional Fedora packages. Its generated
`/usr/share/nulllinux/SOURCES.txt` and package manifest describe the packages
present in that particular image. `bin/null-sources <iso>` checks the source
information and attempts to fetch a source RPM. Those checks provide evidence
of source availability at the time they run; links to Fedora repositories or
one successful fetch do not by themselves establish that every redistribution
obligation has been met. Do not reuse package counts from an older image.

## Before public distribution

- Confirm authority to distribute project contributions, including any
  employment or contributor ownership constraints.
- Keep the project, Terminus, Adwaita, and dependency notices in the release;
  inspect the rebuilt RPM's actual license file list.
- Recheck the locked dependency, embedded material, and toolchain inventories
  whenever their source versions change.
- Record the actual ISO's package/source inventory and review applicable
  source-delivery obligations for its packages and bundled components.
- Review the current Fedora Remix trademark requirements before using Fedora
  names or marks publicly.
- Obtain appropriate legal review where the distribution circumstances require
  it; this inventory does not substitute for that review.
