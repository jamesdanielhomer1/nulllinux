"""Isolated lifecycle tests: fake assets, fake locker, and only test-owned children."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeWrappers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="null-runtime-wrappers-")
        self.root = Path(self.temp.name)
        for p in ["assets/prebuilt", "render/target/release", "lib", "tools", "runtime"]:
            (self.root / p).mkdir(parents=True)
        self.env = dict(os.environ, NULL_ROOT=str(self.root),
                        XDG_RUNTIME_DIR=str(self.root / "runtime"), WAYLAND_DISPLAY="test-display",
                        PATH=str(self.root / "tools") + os.pathsep + os.environ["PATH"])

    def tearDown(self):
        self.temp.cleanup()

    def script(self, path, text):
        p = self.root / path
        p.write_text("#!/usr/bin/env bash\n" + text + "\n")
        p.chmod(0o755)
        return p

    def run_wrapper(self, name, *args):
        return subprocess.run(["bash", str(ROOT / "bin" / name), *args], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def start_owned(self, script, display):
        p = subprocess.Popen(["bash", str(script)], env=dict(self.env, WAYLAND_DISPLAY=display),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        def stop():
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait(timeout=2)
        self.addCleanup(stop)
        return p

    def wait_for(self, test):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if test():
                return
            time.sleep(0.02)
        self.fail("fixture did not become ready")

    def test_supervisors_keep_two_wayland_sessions_independent(self):
        self.script("tools/swaymsg", "exit 1")
        tag = "supervisor-" + self.root.name
        script = self.script(tag, f'. "{ROOT}/lib/supervise.sh"\nTAG={tag}\n'
                             'reconcile() { touch "$NULL_ROOT/ready-$WAYLAND_DISPLAY"; }\nsupervise')
        first = self.start_owned(script, "display-a")
        self.wait_for(lambda: (self.root / "ready-display-a").exists())
        second = self.start_owned(script, "display-b")
        self.wait_for(lambda: (self.root / "ready-display-b").exists())
        saved = [(p, p.read_text().strip()) for p in (self.root / "runtime").glob("*.pid")]
        self.assertEqual({v for _,v in saved}, {str(first.pid), str(second.pid)})
        replacement = self.start_owned(script, "display-a")
        self.wait_for(lambda: any(p.read_text().strip() == str(replacement.pid)
                                 for p in (self.root / "runtime").glob("*.pid")))
        self.assertIsNone(second.poll(), "restart displaced a different Wayland session")

    def test_once_only_replaces_matching_processes_in_its_wayland_session(self):
        marker = "victim-" + self.root.name
        script = self.script(marker, 'touch "$NULL_ROOT/ready-$WAYLAND_DISPLAY"; exec sleep 30')
        # Keep the unique marker in argv after exec so no host process can match.
        script.write_text('#!/usr/bin/env bash\ntouch "$NULL_ROOT/ready-$WAYLAND_DISPLAY"\n'
                          f'exec -a {marker} sleep 30\n')
        first = self.start_owned(script, "display-a")
        second = self.start_owned(script, "display-b")
        self.wait_for(lambda: all((self.root / ("ready-" + d)).exists() for d in ["display-a","display-b"]))
        result = subprocess.run(["bash", "-c", f'. "{ROOT}/lib/once.sh"; null_only_one "$1"',
                                 "fixture", marker], env=dict(self.env, WAYLAND_DISPLAY="display-a"), timeout=5)
        self.assertEqual(result.returncode, 0)
        self.wait_for(lambda: first.poll() is not None)
        self.assertIsNone(second.poll(), "once killed a different Wayland session")

    def test_cache_key_changes_for_each_derivation_input(self):
        inputs = ["assets/prebuilt/master.hero", "assets/ramp.json", "assets/palette.json",
                  "assets/palette.bin", "render/target/release/render"]
        for path in inputs:
            (self.root / path).write_bytes(b"first")
        ramp = str(self.root / "assets/ramp.json")
        previous = self.run_wrapper("null-hero", "path", "80", "24", ramp)
        self.assertEqual(previous.returncode, 0, previous.stderr)
        for path in inputs:
            (self.root / path).write_bytes(b"changed")
            current = self.run_wrapper("null-hero", "path", "80", "24", ramp)
            self.assertEqual(current.returncode, 0, current.stderr)
            self.assertNotEqual(previous.stdout, current.stdout, path)
            previous = current

    def test_wallpaper_does_not_kill_an_unowned_render_process(self):
        renderer = self.root / "render/target/release/render"
        shutil.copyfile(shutil.which("sleep"), renderer)
        renderer.chmod(0o755)
        child = subprocess.Popen([str(renderer), "30"])
        try:
            self.script("tools/pgrep", f"echo {child.pid}")
            (self.root / "lib/supervise.sh").write_text("supervise() { :; }\n")
            result = self.run_wrapper("null-wallpaper")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll(), "wallpaper killed an independent use of render")
        finally:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)

    def test_an_unrelated_lock_process_does_not_skip_session_lock(self):
        self.script("tools/pgrep", "echo 12345; exit 0")
        self.script("render/target/release/lock", 'printf attempted > "$NULL_ROOT/attempted"; echo LOCKED')
        result = self.run_wrapper("null-lock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "attempted").exists(), "a process name was mistaken for a locked session")

    def test_lock_readiness_is_scoped_to_the_wayland_session(self):
        self.script("render/target/release/lock",
                    'echo attempt >> "$NULL_ROOT/attempted"; echo LOCKED; exec sleep 30')
        children = []
        try:
            for display in ["test-display", "test-display", "other-display"]:
                env = dict(self.env, WAYLAND_DISPLAY=display)
                result = subprocess.run(["bash", str(ROOT / "bin/null-lock")], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                self.assertEqual(result.returncode, 0)
                children = [int(p.read_text().split()[0]) for p in (self.root / "runtime").glob("*.ready")]
            self.assertEqual((self.root / "attempted").read_text().count("attempt"), 2)
            self.assertEqual(len(children), 2)
        finally:
            for pid in children:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
