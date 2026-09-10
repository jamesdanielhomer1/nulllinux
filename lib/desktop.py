"""XDG application lookup and Exec expansion shared by the launcher and defaults.

Exec is an argument vector, not shell code. Only the compositor handoff needs
shell quoting; null-open receives NUL-separated arguments instead.
https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html
"""
import configparser
import os
from pathlib import Path
import re
import shlex
import shutil
import sys


def directories():
    home = Path.home()
    data_home = os.environ.get("XDG_DATA_HOME") or str(home / ".local/share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    paths = [data_home, *data_dirs.split(":")]
    # Flatpak exports may not have been added to the session environment yet.
    paths += [str(home / ".local/share/flatpak/exports/share"),
              "/var/lib/flatpak/exports/share"]
    return [Path(p) / "applications" for p in dict.fromkeys(paths) if Path(p).is_absolute()]


def paths():
    seen = set()
    for directory in directories():
        for path in sorted(directory.rglob("*.desktop")):
            ident = str(path.relative_to(directory)).replace(os.sep, "-")
            if ident in seen:
                continue
            # A user deletion (Hidden=true), even one with no Exec, masks the
            # system copy of the same desktop ID.
            seen.add(ident)
            yield ident, path


def read_entry(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        parser.read(path, encoding="utf-8")
        entry = parser["Desktop Entry"]
    except (OSError, UnicodeError, configparser.Error, KeyError) as error:
        raise ValueError(f"invalid desktop entry: {path}") from error
    if entry.get("Type", "Application") != "Application" or flag(entry, "Hidden"):
        raise ValueError(f"desktop entry is unavailable: {path}")
    return entry


def entries():
    for ident, path in paths():
        try:
            yield ident, path, read_entry(path)
        except ValueError:
            continue


def flag(entry, key):
    return entry.get(key, "false").lower() == "true"


def visible(entry):
    desktops = set(os.environ.get("XDG_CURRENT_DESKTOP", "sway").split(":"))
    only = set(filter(None, entry.get("OnlyShowIn", "").split(";")))
    exclude = set(filter(None, entry.get("NotShowIn", "").split(";")))
    return (not flag(entry, "NoDisplay") and (not only or bool(only & desktops))
            and not exclude & desktops)


def unescape(value):
    escapes = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
    return re.sub(r"\\([sntr\\])", lambda match: escapes[match[1]], value)


def command(entry, path, target=None):
    value = unescape(entry.get("Exec", ""))
    # POSIX tokenization removes double quotes without executing expansions.
    # Within quotes shlex preserves \$ and \`; Desktop Entry requires those
    # two quoting escapes to be undone as well.
    words = shlex.split(value)
    result = []
    used_target = False
    for word in words:
        word = word.replace("\\$", "$").replace("\\`", "`")
        if word in ("%f", "%F", "%u", "%U"):
            used_target = True
            if target is not None:
                result.append(target)
            continue
        if word == "%i":
            if entry.get("Icon"):
                result += ["--icon", unescape(entry["Icon"])]
            continue
        if word in ("%d", "%D", "%n", "%N", "%v", "%m"):
            continue

        def expand(match):
            nonlocal used_target
            code = match[1]
            if code == "%":
                return "%"
            if code == "c":
                return unescape(entry.get("Name", ""))
            if code == "k":
                return str(path)
            if code in ("f", "u"):
                used_target = True
                return target if target is not None else ""
            raise ValueError(f"invalid or misplaced Exec field code %{code}")

        result.append(re.sub(r"%(.)", expand, word))
    if not result or not shutil.which(result[0]):
        raise ValueError("executable is unavailable")
    if entry.get("TryExec") and not shutil.which(unescape(entry["TryExec"])):
        raise ValueError("TryExec is unavailable")
    if target is not None and not used_target:
        result.append(target)
    return result


def lookup(ident):
    # Resolving one default need not parse every installed application's file.
    for found, path in paths():
        if found == ident:
            return path, read_entry(path)
    raise ValueError(f"desktop entry is unavailable: {ident}")


def working_directory(entry):
    cwd = unescape(entry.get("Path", ""))
    if cwd and (not Path(cwd).is_absolute() or not Path(cwd).is_dir()):
        raise ValueError(f"application working directory is unavailable: {cwd}")
    return cwd


def main():
    verb, *args = sys.argv[1:]
    if verb in ("field", "exec", "argv", "launch-argv", "shell"):
        path, entry = lookup(args[0])
        if verb == "field":
            print(unescape(entry.get(args[1], "")))
        else:
            argv = command(entry, path, args[1] if len(args) > 1 else None)
            if verb in ("argv", "launch-argv", "shell"):
                if flag(entry, "Terminal"):
                    argv = ["foot", "-e", *argv]
            if verb in ("argv", "launch-argv"):
                if verb == "launch-argv":
                    argv.insert(0, working_directory(entry))
                sys.stdout.buffer.write(b"".join(a.encode() + b"\0" for a in argv))
            elif verb == "shell":
                cwd = working_directory(entry)
                prefix = f"cd -- {shlex.quote(cwd)} && " if cwd else ""
                print(prefix + "exec " + shlex.join(argv))
            else:
                print(shlex.join(argv))
    elif verb in ("candidates", "list"):
        rows = []
        for ident, path, entry in entries():
            if verb == "list" and not visible(entry):
                continue
            if verb == "candidates" and args[0] not in entry.get("MimeType", "").split(";"):
                continue
            try:
                argv = command(entry, path)
            except ValueError:
                continue
            name = " ".join(unescape(entry.get("Name", path.stem)).split())
            if verb == "candidates":
                rows.append(f"{ident}\t{name}")
            else:
                kind = "term" if flag(entry, "Terminal") else "gui"
                # Each fzf row stays a single line. The selected ID is resolved
                # again for launch, so quoted tabs/newlines never corrupt rows.
                display = " ".join(shlex.join(argv).split())
                rows.append(f"{name[:30]:30s} {display}\t{kind}\t{ident}")
        print("\n".join(sorted(rows)))
    else:
        raise ValueError(f"unknown verb: {verb}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, IndexError) as error:
        print(f"desktop: {error}", file=sys.stderr)
        sys.exit(1)
