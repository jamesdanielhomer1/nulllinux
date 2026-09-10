#!/usr/bin/env python3
"""Opt-in, isolated Wayland runtime smoke test; never uses the user's session."""
import ctypes
import ctypes.util
import json
import importlib.util
import os
from pathlib import Path
import pwd
import re
import shutil
import shlex
import signal
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(test, description, seconds=8):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        value = test()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("timeout: " + description)


def fixture_assets(root):
    assets = root / "assets"
    assets.mkdir(parents=True)
    cps = sorted(set(range(32, 127)) | {ord(c) for c in "·•─│┌┐└┘┬°"})
    w, h = 6, 10
    atlas = bytearray(b"RATL" + struct.pack("<HHHH", 1, w, h, len(cps)) + bytes(32))
    atlas += struct.pack("<H", len(cps))
    for i, cp in enumerate(cps):
        atlas += struct.pack("<IH", cp, i)
    for cp in cps:
        atlas += bytes([0 if cp == 32 else 1]) * (w * h)
    (assets / "atlas-interface.bin").write_bytes(atlas)
    (assets / "atlas-interface-bold.bin").write_bytes(atlas)
    roles = ["void", "background", "surface", "line", "dim", "error", "warning", "neutral", "accent", "highlight"]
    palette = {"roles": {r: {"hex": "#101020" if r in roles[:3] else "#b08040"} for r in roles}}
    (assets / "palette.json").write_text(json.dumps(palette))
    (assets / "ramp-interface.json").write_text('{"ramp":" #"}')
    raw = b"".join(bytes([0]) * 1200 + bytes([i]) * 1200 for i in range(4))
    lib = ctypes.CDLL(ctypes.util.find_library("zstd"))
    lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    lib.ZSTD_compressBound.restype = ctypes.c_size_t
    lib.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    lib.ZSTD_compress.restype = ctypes.c_size_t
    out = ctypes.create_string_buffer(lib.ZSTD_compressBound(len(raw)))
    source = ctypes.create_string_buffer(raw)
    n = lib.ZSTD_compress(out, len(out), source, len(raw), 1)
    if n > len(out):
        raise RuntimeError("fixture compression failed")
    cells = b"RCEL" + struct.pack("<HHHHH", 1, 40, 30, 4, 12) + b"\x01#"
    cells += struct.pack("<H", 4) + bytes([200,0,0,0,200,0,0,0,200,200,200,200])
    (assets / "hero.cells").write_bytes(cells + struct.pack("<Q", len(raw)) + out.raw[:n])
    (root / "bin").mkdir()
    machine = root / "bin/machine"
    machine.write_text('#!/usr/bin/env bash\nprintf "%s %s\\n" "$NULL_ROOT/assets/hero.cells" "$NULL_ROOT/assets/atlas-interface.bin"\n')
    machine.chmod(0o755)
    menu = root / "bin/null-menu"
    menu.write_text('''#!/usr/bin/env python3
import json, os, signal, time
from pathlib import Path
def size(*args):
    s=os.get_terminal_size(0)
    p=Path(os.environ["NULL_ROOT"])/"pty-size.json"
    t=p.with_suffix(".tmp")
    t.write_text(json.dumps([s.columns,s.lines])); t.replace(p)
signal.signal(signal.SIGWINCH,size)
size()
print("host ready",flush=True)
while True: time.sleep(1)
''')
    menu.chmod(0o755)


def main():
    if os.environ.get("NULL_RUN_HEADLESS") != "1":
        print("SKIP: set NULL_RUN_HEADLESS=1 to start an isolated test compositor")
        return 77
    binaries = Path(os.environ.get("NULL_HEADLESS_BIN_DIR", str(ROOT / "render/target/release")))
    missing = [name for name in ["sway", "swaymsg", "grim"] if not shutil.which(name)]
    if importlib.util.find_spec("PIL") is None:
        missing.append("python3 Pillow")
    if ctypes.util.find_library("zstd") is None:
        missing.append("libzstd")
    if os.geteuid() == 0 and not shutil.which("runuser"):
        missing.append("runuser")
    missing += [str(binaries / name) for name in ["render", "bar", "column", "lock"] if not (binaries / name).is_file()]
    if missing:
        print("SKIP: missing " + ", ".join(missing))
        return 77
    evidence = Path(os.environ.get("NULL_HEADLESS_EVIDENCE", f"/var/tmp/null-headless-evidence-{os.getpid()}"))
    evidence.mkdir(parents=True, exist_ok=True)
    processes, logs = [], []
    results = {}
    with tempfile.TemporaryDirectory(prefix="null-headless-") as temp:
        root = Path(temp)
        fixture_assets(root)
        runtime = root / "runtime"
        runtime.mkdir(mode=0o700)
        config = root / "sway.conf"
        config.write_text("xwayland disable\noutput * mode 640x480\nseat seat0 hide_cursor 1000\n")
        launcher = []
        user = pwd.getpwuid(os.getuid()).pw_name
        if os.geteuid() == 0:
            account = pwd.getpwnam("nobody")
            user = account.pw_name
            launcher = ["runuser", "-u", user, "--"]
            for p in [root, evidence, *root.rglob("*")]:
                os.chown(p, account.pw_uid, account.pw_gid)
        env = {"XDG_RUNTIME_DIR": str(runtime), "HOME": str(root), "NULL_ROOT": str(root),
               "USER": user, "LOGNAME": user, "WLR_BACKENDS": "headless", "WLR_RENDERER": "pixman",
               "WLR_HEADLESS_OUTPUTS": "2", "WLR_LIBINPUT_NO_DEVICES": "1", "XDG_CONFIG_HOME": str(root / "config")}
        base_env = {k:v for k,v in os.environ.items() if k not in ["SWAYSOCK", "WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"]}

        def command(argv, extra=None):
            overrides = dict(env, **(extra or {}))
            return launcher + ["env", *[k + "=" + v for k,v in overrides.items()], *map(str, argv)]

        def start(name, argv, extra=None):
            out = (evidence / (name + ".out")).open("wb")
            err = (evidence / (name + ".log")).open("wb")
            logs.extend([out, err])
            p = subprocess.Popen(command(argv, extra), env=base_env, stdout=out, stderr=err, start_new_session=True)
            processes.append(p)
            return p

        def run(argv):
            return subprocess.run(command(argv), env=base_env, capture_output=True, text=True, timeout=5)

        def ipc(*args):
            p = run(["swaymsg", "-r", *args])
            if p.returncode:
                raise AssertionError("IPC failed: " + p.stderr)
            return json.loads(p.stdout)

        def alive(p, name):
            if p.poll() is not None:
                raise AssertionError(name + " exited: " + (evidence / (name + ".log")).read_text()[-4000:])

        try:
            sway = start("sway", ["sway", "-c", config])
            socket = wait_for(lambda: next(runtime.glob("sway-ipc.*.sock"), None), "Sway IPC socket")
            wayland = wait_for(lambda: next((p for p in runtime.glob("wayland-*") if not p.name.endswith(".lock")), None), "Wayland socket")
            env.update(SWAYSOCK=str(socket), WAYLAND_DISPLAY=wayland.name)
            outputs = wait_for(lambda: ipc("-t", "get_outputs"), "two outputs")
            assert len(outputs) == 2, outputs
            names = [o["name"] for o in outputs]
            recorder = root / "record-argv.py"
            recorder.write_text("import json,sys\nfrom pathlib import Path\nPath(__file__).with_suffix('.json').write_text(json.dumps(sys.argv[1:]))\n")
            literal = 'literal $(printf EXPANDED); "double" and single\' quote'
            ipc("exec " + shlex.join([shutil.which("python3"), str(recorder), literal]))
            recorded = wait_for(lambda: json.loads(recorder.with_suffix(".json").read_text()) if recorder.with_suffix(".json").exists() else None, "Sway exec argument recorder")
            assert recorded == [literal], recorded
            results["sway_exec_literal_argument"] = recorded
            wallpaper = start("wallpaper", [binaries / "render", "--file", root / "assets/hero.cells", "--atlas", root / "assets/atlas-interface.bin", "layershell", "--output", names[0]], {"RENDER_STATS": "1"})
            bar = start("bar", [binaries / "bar", "--output", names[0]], {"BAR_STATS": "1"})
            column = start("column", [binaries / "column"], {"COLUMN_STATS": "1"})
            wait_for(lambda: any(runtime.glob("null-column-*.sock")), "column control socket")
            time.sleep(1)
            assert run([binaries / "column", "--send", "open", "fixture"]).returncode == 0
            size_path = root / "pty-size.json"
            initial = wait_for(lambda: json.loads(size_path.read_text()) if size_path.exists() else None, "host initial terminal size")
            time.sleep(0.5)
            assert run(["grim", "-o", names[0], evidence / "before.png"]).returncode == 0
            ipc("output " + names[0] + " mode 480x360")
            def resized():
                value = json.loads(size_path.read_text())
                return value if value != initial and value[1] < initial[1] else None
            final = wait_for(resized, "host SIGWINCH after output resize")
            time.sleep(1.2)
            assert run(["grim", "-o", names[0], evidence / "after.png"]).returncode == 0
            from PIL import Image
            before_image = Image.open(evidence / "before.png").convert("RGB")
            after_image = Image.open(evidence / "after.png").convert("RGB")
            assert before_image.size == (640,480), before_image.size
            assert after_image.size == (480,360), after_image.size
            assert after_image.getpixel((479,0)) == (176,128,64), "bar right edge missing after resize"
            for p,name in [(wallpaper,"wallpaper"),(bar,"bar"),(column,"column")]:
                alive(p,name)
            results["resize"] = {"initial_pty":initial,"resized_pty":final,"outputs":ipc("-t","get_outputs")}
            lock = start("lock", [binaries / "lock"], {"WAYLAND_DEBUG":"client"})
            wait_for(lambda: "LOCKED" in (evidence / "lock.out").read_text(), "LOCKED handshake")
            # A test locker is never authenticated; the compositor must retain
            # the lock after its client dies. This is an isolated compositor.
            time.sleep(2)
            alive(lock,"lock")
            client_children = Path(f"/proc/{lock.pid}/task/{lock.pid}/children").read_text().split() if launcher else [str(lock.pid)]
            lock_pid = int(client_children[0])
            rss_before = int(Path(f"/proc/{lock_pid}/statm").read_text().split()[1])
            time.sleep(4)
            rss_after = int(Path(f"/proc/{lock_pid}/statm").read_text().split()[1])
            debug = (evidence / "lock.log").read_text()
            callbacks = len(re.findall(r"-> wl_surface@\d+\.frame", debug))
            assert callbacks == 0, f"lock scheduled {callbacks} frame callbacks despite its timer"
            assert rss_after - rss_before < 2048, (rss_before,rss_after)
            ipc("output * power off")
            time.sleep(1)
            off_before = int(Path(f"/proc/{lock_pid}/statm").read_text().split()[1])
            time.sleep(4)
            off_after = int(Path(f"/proc/{lock_pid}/statm").read_text().split()[1])
            assert off_after - off_before < 2048, (off_before,off_after)
            alive(lock,"lock")
            ipc("output * power on")
            time.sleep(0.3)
            # Removing an output must release its lock surface before a new
            # wl_output is announced on re-enable, otherwise each cycle leaks it.
            def lock_requests(method):
                return len(re.findall(method, (evidence / "lock.log").read_text()))
            destroys = lock_requests(r"-> ext_session_lock_surface_v1@\d+\.destroy")
            for cycle in range(3):
                removes = lock_requests(r"wl_registry@\d+\.global_remove")
                ipc("output " + names[1] + " disable")
                wait_for(lambda: lock_requests(r"wl_registry@\d+\.global_remove") > removes,
                         "removed wl_output global")
                wait_for(lambda: lock_requests(r"-> ext_session_lock_surface_v1@\d+\.destroy") > destroys,
                         "lock surface destroyed after output removal")
                destroys = lock_requests(r"-> ext_session_lock_surface_v1@\d+\.destroy")
                creates = lock_requests(r"-> ext_session_lock_v1@\d+\.get_lock_surface")
                ipc("output " + names[1] + " enable")
                wait_for(lambda: lock_requests(r"-> ext_session_lock_v1@\d+\.get_lock_surface") > creates,
                         "new lock surface after output re-enable")
                alive(lock,"lock")
            results["lock_hotplug"] = {"cycles":3,"surface_destroys":destroys}
            os.killpg(lock.pid, signal.SIGKILL)
            lock.wait(timeout=5)
            captured = run(["grim", "-o", names[0], evidence / "after-lock-client-exit.png"])
            # Sway may deny screencopy or supply its solid fail-closed frame.
            results["lock"] = {"handshake":True,"callback_requests":callbacks,
                               "rss_pages_before":rss_before,"rss_pages_after":rss_after,
                               "dpms_off_rss_pages_before":off_before,"dpms_off_rss_pages_after":off_after,
                               "screencopy_after_client_exit":captured.returncode,"screencopy_stderr":captured.stderr}
            if captured.returncode == 0:
                from PIL import Image
                image = Image.open(evidence / "after-lock-client-exit.png").convert("RGB")
                assert len(image.getcolors(image.width * image.height) or []) <= 2, "desktop exposed after lock client exit"
            alive(sway,"sway")
            os.killpg(sway.pid, signal.SIGTERM)
            wait_for(lambda: all(p.poll() is not None for p in [wallpaper,bar,column]),
                     "surfaces exit after compositor disconnect")
            results["compositor_disconnect"] = "all surfaces exited"
            (evidence / "results.json").write_text(json.dumps(results,indent=2))
            print(json.dumps(results,indent=2))
            print("PASS: isolated resize and fail-closed lock checks; evidence " + str(evidence))
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGTERM)
                    try:
                        p.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(p.pid, signal.SIGKILL)
                        p.wait(timeout=3)
            for log in logs:
                log.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
