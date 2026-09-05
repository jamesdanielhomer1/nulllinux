#!/usr/bin/env python3
"""Generate the boot splash and login greeter (NULL.md §9.6.1, §9.7).

THE SPLASH DRAWS NO TEXT, and that is the whole design.

A splash theme's text primitive renders with the theme's general font setting,
not its monospace one. A theme naming only the monospace font leaves the
general one empty, the initramfs hook resolves the empty name through font
matching, and it installs whatever the system's default PROPORTIONAL font is --
so several hundred columns of ASCII art come out as ragged noise, every row a
different width.

Naming the bitmap font explicitly is a gamble rather than a fix: the exact cell
grid would then depend on a size negotiation happening correctly inside an
initramfs. And a text primitive takes one colour for a whole string, so the
hero would be flat where every other surface draws it on the temperature ramp.

So the frames are RASTERISED, through the same renderer that draws the
wallpaper -- which is what stops the splash disagreeing with the rest of the
system about what the hero looks like.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

RENDER = "render/target/release/render"


def rasterise(cells, atlas, frame, out_png):
    ppm = f"/tmp/null-boot-{frame}.ppm"
    subprocess.run([RENDER, "--file", cells, "--atlas", atlas,
                    "raster", "--frame", str(frame), "--out", ppm],
                   check=True, capture_output=True)
    Image.open(ppm).save(out_png, optimize=True)
    Path(ppm).unlink(missing_ok=True)
    return Path(out_png).stat().st_size


def make_plymouth(outdir, cells, atlas, count, total_frames, palette):
    """Emit a `two-step` theme.

    NOT `script`: script.so is not installed on this system, and
    plymouth-populate-initrd refuses a theme whose module .so is missing -- so a
    script theme would have failed at initramfs-build time, or worse, produced
    an image that falls back to `text` at boot. two-step is present, is what the
    stock themes use, and animates a numbered frame sequence natively.

    `Font=` is named EXPLICITLY. Absent it, plymouth-populate-initrd resolves
    `fc-match` with an EMPTY PATTERN and installs whatever comes back as
    Plymouth.ttf -- so a font reaches the initramfs either way, but an unnamed
    one is chosen by whatever fontconfig happens to answer that day. Naming it
    makes the image reproducible. It is used for MESSAGES ONLY; the hero is a
    frame sequence, never text (§9.6.1).
    """
    import json
    r = {k: v["hex"] for k, v in json.loads(Path(palette).read_text())["roles"].items()}
    hexc = lambda role: "0x" + r[role].lstrip("#")

    outdir = Path(outdir)
    shutil.rmtree(outdir, ignore_errors=True)
    outdir.mkdir(parents=True)

    # Subsampling a perfect loop still loops perfectly: every Nth frame plays
    # faster, which does not matter for a splash.
    step = max(1, total_frames // count)
    total = 0
    for i in range(count):
        total += rasterise(cells, atlas, i * step, outdir / f"throbber-{i + 1:04d}.png")

    (outdir / "nullLinux.plymouth").write_text(f"""\
[Plymouth Theme]
Name=nullLinux
Description=One baked asset, rendered as text
ModuleName=two-step

[two-step]
Font=Cantarell 12
TitleFont=Cantarell Light 30
ImageDir=/usr/share/plymouth/themes/nullLinux
HorizontalAlignment=.5
VerticalAlignment=.5
DialogHorizontalAlignment=.5
DialogVerticalAlignment=.75
Transition=none
TransitionDuration=0.0
BackgroundStartColor={hexc('background')}
BackgroundEndColor={hexc('background')}
ProgressBarBackgroundColor={hexc('line')}
ProgressBarForegroundColor={hexc('dim')}
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false

[shutdown]
UseEndAnimation=false

[reboot]
UseEndAnimation=false
""")
    return total, count


def make_sddm(outdir, cells, atlas, count, total_frames, palette):
    outdir = Path(outdir)
    shutil.rmtree(outdir, ignore_errors=True)
    outdir.mkdir(parents=True)
    step = max(1, total_frames // count)
    total = 0
    for i in range(count):
        total += rasterise(cells, atlas, i * step, outdir / f"f{i:02d}.png")

    import json
    r = {k: v["hex"] for k, v in json.loads(Path(palette).read_text())["roles"].items()}

    (outdir / "theme.conf").write_text("[General]\nbackground=f00.png\n")
    (outdir / "metadata.desktop").write_text(
        "[SddmGreeterTheme]\nName=nullLinux\nDescription=One baked asset\n"
        "Author=nullLinux\nType=sddm-theme\nVersion=1\nQmlFile=Main.qml\n"
        "ConfigFile=theme.conf\n")

    # Frames as DATA and real text (§9.7). The panel is composed from the same
    # elements as every other panel, so unlocking and logging in look like one
    # system.
    # ter-u18n is exactly 10px wide, so the box-drawing rules can be made to
    # span the rows EXACTLY rather than approximately: a 4-char label plus 10px
    # of spacing plus a 260px box is 310px, which is 31 cells.
    label_px, gap_px, box_px, cell_px = 4 * 10, 10, 260, 10
    cols = (label_px + gap_px + box_px) // cell_px
    title = " nox "
    top = "\u250c\u2500" + title + "\u2500" * (cols - 3 - len(title)) + "\u2510"
    bot = "\u2514" + "\u2500" * (cols - 2) + "\u2518"
    assert len(top) == len(bot) == cols, (len(top), len(bot), cols)

    (outdir / "Main.qml").write_text(f"""\
// GENERATED by bake/make_boot_assets.py -- do not edit.
//
// SddmComponents provides TextBox and PasswordBox; there is no TextField.
// On both, `color` is the box's BACKGROUND fill and `textColor` is the text --
// setting `color` to the foreground role paints the fill and leaves the text
// black. The types and their property semantics were read off the installed
// module, not assumed.
import QtQuick 2.0
import SddmComponents 2.0

Rectangle {{
    id: root
    color: "{r['background']}"
    property int frameCount: {count}
    property int idx: 0
    property int sessionIndex: sessionModel.lastIndex

    Image {{
        id: hero
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -90
        source: "f" + (root.idx < 10 ? "0" : "") + root.idx + ".png"
        fillMode: Image.Pad          // never resample the cell grid
        smooth: false
        cache: true
    }}
    Timer {{
        interval: 83; running: true; repeat: true
        onTriggered: root.idx = (root.idx + 1) % root.frameCount
    }}

    Column {{
        id: panel
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 90
        spacing: 4

        Text {{
            text: "{top}"
            color: "{r['line']}"
            font.family: "Terminus"; font.pixelSize: 18
        }}
        Row {{
            spacing: 10
            Text {{
                text: "user"; color: "{r['dim']}"
                anchors.verticalCenter: parent.verticalCenter
                font.family: "Terminus"; font.pixelSize: 18
            }}
            TextBox {{
                id: user
                width: 260; height: 30
                text: userModel.lastUser
                font.family: "Terminus"; font.pixelSize: 18
                color: "{r['surface']}"
                textColor: "{r['neutral']}"
                borderColor: "{r['line']}"
                focusColor: "{r['accent']}"
                KeyNavigation.tab: password
                // Neither box declares an `accepted` signal; Enter is wired
                // through Keys.onPressed. Read off the module, not assumed.
                Keys.onPressed: function (event) {{
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {{
                        password.forceActiveFocus()
                        event.accepted = true
                    }}
                }}
            }}
        }}
        Row {{
            spacing: 10
            Text {{
                text: "pass"; color: "{r['dim']}"
                anchors.verticalCenter: parent.verticalCenter
                font.family: "Terminus"; font.pixelSize: 18
            }}
            PasswordBox {{
                id: password
                width: 260; height: 30
                font.family: "Terminus"; font.pixelSize: 18
                color: "{r['surface']}"
                textColor: "{r['neutral']}"
                borderColor: "{r['line']}"
                focusColor: "{r['accent']}"
                KeyNavigation.backtab: user
                Keys.onPressed: function (event) {{
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {{
                        sddm.login(user.text, password.text, root.sessionIndex)
                        event.accepted = true
                    }}
                }}
            }}
        }}
        Text {{
            text: "{bot}"
            color: "{r['line']}"
            font.family: "Terminus"; font.pixelSize: 18
        }}
        Text {{
            id: msg
            text: ""; color: "{r['error']}"
            font.family: "Terminus"; font.pixelSize: 18
        }}
    }}

    Connections {{
        target: sddm
        function onLoginFailed() {{ msg.text = "denied"; password.text = "" }}
        function onLoginSucceeded() {{ msg.text = "" }}
    }}
    Component.onCompleted: {{
        if (user.text === "") user.forceActiveFocus()
        else password.forceActiveFocus()
    }}
}}
""")
    return total, count


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", type=int, default=16)
    ap.add_argument("--total-frames", type=int, default=240)
    # WHERE THE ASSETS COME FROM AND WHERE THE THEMES GO.
    #
    # These were fixed at the tree's own paths, which meant the themes could
    # only be built on a machine that had already had a hero placed -- so they
    # were built on the build host, into system/, and never shipped or
    # installed anywhere. An installed machine booted and logged in with stock
    # Fedora chrome.
    #
    # Parameterised so bin/null-prebake can build one set from a chosen strike
    # and put it in assets/prebuilt/boot/, which ships and is placed like every
    # other prebuilt surface. A splash is a centred image; it does not have to
    # match the panel, and one rendering looking the same on every machine is
    # the right answer for a brand anyway.
    ap.add_argument("--plymouth-cells", default="assets/target-4.cells")
    ap.add_argument("--sddm-cells", default="assets/target-2.cells")
    ap.add_argument("--atlas", default="assets/atlas-bake.bin")
    ap.add_argument("--palette", default="assets/palette.json")
    ap.add_argument("--out", default="system", help="directory to hold both themes")
    args = ap.parse_args()

    out = Path(args.out)
    n, c = make_plymouth(out / "plymouth-theme", args.plymouth_cells,
                         args.atlas, args.frames, args.total_frames, args.palette)
    print(f"  plymouth: {c} frames, {n/1000:.0f} kB  -> {out}/plymouth-theme")
    n, c = make_sddm(out / "sddm-theme", args.sddm_cells,
                     args.atlas, args.frames, args.total_frames, args.palette)
    print(f"  sddm:     {c} frames, {n/1000:.0f} kB  -> {out}/sddm-theme")


if __name__ == "__main__":
    main()
