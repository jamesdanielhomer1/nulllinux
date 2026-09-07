#!/usr/bin/env bash
# CAN A PERSON ACTUALLY DO THE THING?
#
# Three times in one evening the same shape: an application declared, themed,
# reachable from the menu, and unable to do what it is for, because the thing it
# needs was not declared.
#
#   xarchiver    declared, themed, in the file manager's context menu. No `tar`,
#                so "Extract here" on a .tar.gz did nothing at all.
#   LibreOffice  declared. No `libreoffice-gtk3`, so it would draw its own
#                widgets in its own colours and look like nothing else here.
#   LibreOffice  declared, with the plugin. No document fonts, so a .docx in
#                Times New Roman reflows and changes its page count, and an
#                email in Cyrillic is a row of boxes.
#
# Every existing check asks a question about a PART: is this package declared,
# does this config reach that app, does this name resolve. None of them asks
# whether a person sitting in front of the machine can open the thing they were
# sent. This does.
#
# A CAPABILITY IS A LIST OF PIECES AND A REASON. The reason matters more than
# the list: it says what breaks, so that somebody removing a package can tell
# whether they are trimming or amputating.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -x bin/pkg ] || { note "bin/pkg is gone"; exit 1; }
DECLARED=$(./bin/pkg list-packages base 2>/dev/null | tr ' ' '\n' | sort -u)
CORE=$(./bin/pkg list-group core 2>/dev/null)

have() {  # a package is declared, or is part of the base system
  printf '%s\n' "$DECLARED" | grep -qix "$1" && return 0
  [ -n "$CORE" ] && printf '%s\n' "$CORE" | grep -qix "$1"
}

# can <what a person does> <what breaks without them> <package...>
can() {
  local what=$1 breaks=$2; shift 2
  local missing=""
  for p in "$@"; do have "$p" || missing="$missing $p"; done
  if [ -z "$missing" ]; then
    note "ok    $what"
  else
    note "$what -- missing:$missing"
    note "      without them: $breaks"
    fail=1
  fi
}

can "open an archive somebody sent" \
    "'Extract here' does nothing at all, silently" \
    xarchiver tar unzip gzip xz bzip2

can "make an archive to send" \
    "the system can open a zip and not produce one" \
    zip tar gzip

can "read a document somebody sent" \
    "a .docx in Times New Roman reflows and changes its page count" \
    libreoffice-writer liberation-serif-fonts liberation-sans-fonts liberation-mono-fonts

can "have that document look like this system" \
    "LibreOffice draws its own widgets and looks like nothing else on the machine" \
    libreoffice-gtk3

can "read mail in a script that is not Latin" \
    "the message is a row of boxes" \
    google-noto-sans-fonts

can "read and send mail at all" \
    "there is no mail client; webmail in a browser tab is not an inbox" \
    thunderbird

can "join a wireless network" \
    "the card comes up and finds no firmware, on the machine this is going onto" \
    iwlwifi-mvm-firmware NetworkManager-tui iw

can "print" \
    "there is no print spooler and no way to add a printer" \
    cups cups-filters system-config-printer

can "hear anything" \
    "PipeWire runs and routes nothing, which reads as broken audio" \
    pipewire pipewire-pulseaudio wireplumber

can "plug in a USB stick and use it" \
    "it is a block device nothing mounts" \
    udisks2 gvfs thunar-volman exfatprogs dosfstools ntfs-3g

can "edit a text file" \
    "null-open falls through to whatever @core left behind" \
    nano

can "be asked for a password by something that needs root" \
    "every privileged action fails with no prompt at all" \
    polkit

# Bluetooth audio needs a SPA plugin, not just BlueZ: libspa-bluez5.so provides
# the A2DP path and lives in pipewire-libs, which `pipewire` pulls in. Checked
# with `pkg owner-name` rather than assumed -- the same question that found tar
# behind xarchiver, asked of a headset.
can "pair bluetooth headphones and hear them" \
    "the device pairs and then has no audio profile at all" \
    bluez pipewire wireplumber

can "watch a video with sound" \
    "there is no player, or one that cannot reach the audio daemon" \
    mpv pipewire-pulseaudio

can "read a PDF" \
    "a PDF opens in nothing, or in a browser tab" \
    zathura zathura-pdf-mupdf

can "look at a photograph" \
    "an image file has no viewer" \
    imv

can "browse the web" \
    "there is no browser" \
    firefox

can "find a file by name" \
    "search falls back to whatever the shell can do" \
    fd-find

can "see what is using the machine" \
    "no system monitor, and the column's figures have nothing to compare against" \
    btop

can "install and update software" \
    "the machine cannot be changed after it is installed" \
    flatpak

can "take a screenshot" \
    "the key binding runs a program that is not there" \
    grim slurp wl-clipboard

can "use the menu, the launcher and every picker" \
    "fifteen programs in bin/ are pickers over fzf, and all of them fail at once" \
    fzf

# AND THE ONES THAT ARE NOT A PACKAGE LIST.
#
# A machine that never locks is not missing a package; it is missing a line
# that starts the thing that locks it. That was true of every installed
# nullLinux until it was found by suspending one.
if grep -q 'null-idle start' config/sway/config 2>/dev/null \
   && grep -qE '^before-sleep .*null-lock' config/sway/idle.conf 2>/dev/null; then
  note "ok    walk away from the machine and come back to a lock screen"
else
  note "walk away from the machine and come back to a lock screen -- NOT wired"
  note "      the compositor must start null-idle, and idle.conf must lock before sleep"
  fail=1
fi

# FIND OUT HOW TO USE THE MACHINE AT ALL.
#
# 80 bindings, no menu bar, and a compositor whose keys are nobody's default.
# A person logging in for the first time cannot open a terminal without being
# told how. The answer is $mod+k, and it reaches the key list through four
# links -- binding, column topic, null-menu, null-keys -- any one of which can
# break in silence. The column's own comment records that exactly this dispatch
# "silently did nothing ... for months".
if grep -qE '^bindsym \$mod\+k exec .*column --send open keys' config/sway/bindings.conf 2>/dev/null \
   && grep -q 'keys)' bin/null-menu 2>/dev/null \
   && grep -q 'null-keys' bin/null-menu 2>/dev/null \
   && [ -x bin/null-keys ]; then
  note "ok    find out how to use the machine, having been told nothing"
else
  note "find out how to use the machine, having been told nothing -- the chain is broken"
  note "      \$mod+k -> column topic 'keys' -> null-menu keys -> null-keys"
  fail=1
fi

[ $fail = 0 ] && echo "PASS: every ordinary thing a person does has all of its pieces"
exit $fail
