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


def write_prompt_images(outdir, ink=(255, 120, 0), dim=(35, 44, 64),
                       pane=(10, 12, 20), ground=(5, 6, 10)):
    """The password-prompt furniture two-step loads BEFORE it draws anything.

    THIS IS WHY THE SPLASH WAS STOCK FEDORA FOR SO LONG. The two-step plugin
    loads lock.png, box.png and the entry widget unconditionally at
    show_splash_screen -- before it ever reaches the animation -- and one
    missing file aborts the whole splash:

        two-step/plugin.c:1862 show_splash_scree: loading lock image
        ply-boot-splash.c:553  can't show splash: No such file or directory
        main.c:505             Could not start default splash screen,
                               showing text splash screen

    Nothing said "lock.png". The visible result was plymouth's own grey and its
    built-in three-dot spinner, which looks like a theme that loaded and drew
    something plain rather than one that was thrown away. Found with
    plymouth.debug=file:... on the kernel command line; nothing else showed it.

    Fedora's own themes get these from packages a minimal install does not
    pull in -- the spinner theme here ships watermark.png and nothing else --
    so they are drawn here, in the palette, and travel with the theme.
    """
    from PIL import ImageDraw
    outdir = Path(outdir)
    A = lambda c, a=255: tuple(c) + (a,)

    def new(w, h):
        return Image.new("RGBA", (w, h), A(ground, 0))

    # lock.png -- beside the prompt when a passphrase is wanted.
    im = new(24, 32); d = ImageDraw.Draw(im)
    d.rounded_rectangle([2, 13, 21, 30], 3, fill=A(pane, 235), outline=A(ink), width=2)
    d.arc([6, 2, 17, 20], 180, 360, fill=A(ink), width=3)
    d.rectangle([11, 19, 12, 24], fill=A(ink))
    im.save(outdir / "lock.png")

    # box.png -- the panel behind the prompt.
    im = new(64, 64); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 63, 63], fill=A(pane, 235), outline=A(dim), width=1)
    im.save(outdir / "box.png")

    # entry.png -- the field itself.
    im = new(300, 34); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 299, 33], fill=A(pane, 235), outline=A(dim), width=1)
    im.save(outdir / "entry.png")

    # bullet.png -- one typed character. A square, because every other surface
    # in this system draws in cells.
    im = new(10, 10); d = ImageDraw.Draw(im)
    d.rectangle([2, 2, 7, 7], fill=A(ink))
    im.save(outdir / "bullet.png")

    # keyboard.png -- the keymap indicator. Optional: plymouth logs that it
    # failed and carries on, but a missing file it asks for by name is worth
    # providing rather than leaving in the log for someone else to chase.
    im = new(28, 18); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 27, 17], fill=A(pane, 235), outline=A(dim), width=1)
    for x in range(3, 25, 5):
        d.rectangle([x, 4, x + 2, 6], fill=A(ink))
    d.rectangle([6, 10, 21, 12], fill=A(ink))
    im.save(outdir / "keyboard.png")

    return ["lock.png", "box.png", "entry.png", "bullet.png", "keyboard.png"]


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

    write_prompt_images(outdir)
    (outdir / "nullLinux.plymouth").write_text(f"""\
[Plymouth Theme]
Name=nullLinux
Description=One baked asset, rendered as text
ModuleName=two-step

[two-step]
Font=Terminus 12
TitleFont=Terminus 24
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

    # CROP EVERY FRAME to the art's tight bounding box (union across frames),
    # so the greeter can anchor the input panel to the hero's real bottom edge
    # instead of to the empty padding the full cell grid carries. Without this
    # the panel sits a whole grid-margin below the visible hero (§9.7).
    from PIL import ImageChops
    bg = tuple(int(r["background"].lstrip("#")[k:k+2], 16) for k in (0, 2, 4))
    frames = [outdir / f"f{i:02d}.png" for i in range(count)]
    union = None
    for f in frames:
        im = Image.open(f).convert("RGB")
        bb = ImageChops.difference(im, Image.new("RGB", im.size, bg)).getbbox()
        if bb:
            union = bb if union is None else (
                min(union[0], bb[0]), min(union[1], bb[1]),
                max(union[2], bb[2]), max(union[3], bb[3]))
    if union:
        for f in frames:
            Image.open(f).convert("RGB").crop(union).save(f, optimize=True)

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
    # THE MACHINE'S OWN NAME, not the name of the machine this was written on.
    #
    # This was the literal string " nox ", so every greeter everywhere announced
    # a laptop in someone else's house. The theme is built once at prebake and
    # cannot know where it will end up, so it ships a placeholder and
    # bin/null-system substitutes the hostname when it installs it -- and
    # refuses to install a theme with the placeholder still in it.
    #
    # Padded to a fixed width so the box rule above still spans exactly, which
    # is the whole reason this surface is drawn on a 10px cell.
    title = " __NULL_HOSTNAME__ "
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
        anchors.top: hero.bottom
        anchors.topMargin: 24
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
