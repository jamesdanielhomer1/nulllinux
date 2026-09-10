"""Real command tests, with XDG state and launched processes confined to a tempdir."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DesktopCommands(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.apps = self.base / "data/applications"
        self.system = self.base / "system/applications"
        self.commands = self.base / "bin"
        for d in (self.apps, self.system, self.commands):
            d.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.base),
                        XDG_DATA_HOME=str(self.apps.parent),
                        XDG_DATA_DIRS=str(self.system.parent),
                        XDG_CONFIG_HOME=str(self.base / "config"),
                        XDG_CURRENT_DESKTOP="sway", NULL_ROOT=str(ROOT),
                        PATH=f"{self.commands}:/usr/bin:/bin",
                        RECORD=str(self.base / "record.json"))
        self.executable("xdg-mime", "#!/bin/sh\nprintf '%s\\n' test.desktop\n")
        self.executable("record", "#!/usr/bin/python3\nimport json,os,sys\n"
                        "open(os.environ['RECORD'],'w').write(json.dumps(sys.argv[1:]))\n")

    def executable(self, name, body):
        path = self.commands / name
        path.write_text(body)
        path.chmod(0o755)
        return path

    def entry(self, command, extra="", directory=None):
        path = (directory or self.apps) / "test.desktop"
        path.write_text("[Desktop Entry]\nType=Application\nName=Test Viewer\n"
                        f"Exec={command}\nMimeType=image/png;\n{extra}")
        return path

    def run_command(self, command, *args):
        return subprocess.run(["bash", str(ROOT / "bin" / command), *args],
                              env=self.env, text=True, capture_output=True)

    def test_open_preserves_argument_boundaries_and_field_position(self):
        self.entry('record "two words" %f --after "literal *"')
        target = str(self.base / "photo with spaces.png")
        result = self.run_command("null-open", "image", target)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(Path(self.env["RECORD"]).read_text()),
                         ["two words", target, "--after", "literal *"])

    def test_user_hidden_entry_masks_system_handler(self):
        self.entry("record %f", directory=self.system)
        self.entry("record %f", "Hidden=true\n")
        result = self.run_command("null-defaults", "candidates", "image")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("test.desktop", result.stdout)

    def test_embedded_single_file_field_preserves_one_argument(self):
        self.entry('record --file=%f --after')
        result = self.run_command("null-open", "image", "/tmp/two words.png")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(Path(self.env["RECORD"]).read_text()),
                         ["--file=/tmp/two words.png", "--after"])

    def test_default_write_failure_is_not_reported_as_success(self):
        Path(self.env["XDG_CONFIG_HOME"]).write_text("not a directory")
        result = self.run_command("null-defaults", "set", "editor", "/bin/echo")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("editor is", result.stdout)

    def test_default_supports_a_quoted_executable_path(self):
        recorder = self.executable("spaced recorder", (self.commands / "record").read_text())
        self.entry(f'"{recorder}" %u')
        result = self.run_command("null-open", "image", "file:///tmp/two%20words.png")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(Path(self.env["RECORD"]).read_text()),
                         ["file:///tmp/two%20words.png"])

    def test_launcher_keeps_shell_metacharacters_literal(self):
        self.entry('record "two words" "$(touch SHOULD_NOT_EXIST)" %% %c %k')
        self.executable("fzf", "#!/bin/sh\nhead -n1\n")
        self.executable("swaymsg", "#!/usr/bin/python3\nimport subprocess,sys\n"
                        "sys.exit(subprocess.run(['sh','-c',sys.argv[-1]]).returncode)\n")
        self.env["SWAYSOCK"] = "test-socket"
        result = self.run_command("null-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(Path(self.env["RECORD"]).read_text()),
                         ["two words", "$(touch SHOULD_NOT_EXIST)", "%",
                          "Test Viewer", str(self.apps / "test.desktop")])

    def test_launcher_respects_desktop_visibility(self):
        self.entry("record", "OnlyShowIn=GNOME;\n")
        self.executable("fzf", "#!/bin/sh\ncat\n")
        result = self.run_command("null-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no desktop entries", result.stderr)

    def test_desktop_working_directory_reaches_both_launch_paths(self):
        directory = self.base / "working directory"
        directory.mkdir()
        self.executable("record-cwd", "#!/usr/bin/python3\nimport os\n"
                        "open(os.environ['RECORD'],'w').write(os.getcwd())\n")
        self.entry("record-cwd %f", f"Path={directory}\n")
        self.executable("fzf", "#!/bin/sh\nhead -n1\n")
        self.executable("swaymsg", "#!/usr/bin/python3\nimport subprocess,sys\n"
                        "sys.exit(subprocess.run(['sh','-c',sys.argv[-1]]).returncode)\n")
        self.env["SWAYSOCK"] = "test-socket"
        for command, args in (("null-open", ("image", "/tmp/test.png")), ("null-run", ())):
            with self.subTest(command=command):
                result = self.run_command(command, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(self.env["RECORD"]).read_text(), str(directory))


class InputCommands(unittest.TestCase):
    def test_directory_at_config_path_refuses_before_system_mutation(self):
        cases = [("null-defaults", ["set", "editor", "/bin/echo"], "defaults"),
                 ("null-input", ["rate", "25"], "input.conf"),
                 ("null-input", ["layout", "us"], "input.conf")]
        for command, args, name in cases:
            with self.subTest(command=command, args=args), tempfile.TemporaryDirectory() as td:
                base = Path(td)
                (base / "bin").mkdir()
                localectl = base / "bin/localectl"
                localectl.write_text('#!/bin/sh\ntouch "$RECORD"\n')
                localectl.chmod(0o755)
                conf = base / "config/nulllinux" / name
                conf.mkdir(parents=True)
                env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
                           PATH=f"{base / 'bin'}:/usr/bin:/bin", NULL_ROOT=str(ROOT),
                           RECORD=str(base / "mutated"))
                result = subprocess.run(["bash", str(ROOT / "bin" / command), *args],
                                        env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(list(conf.iterdir()), [])
                self.assertFalse((base / "mutated").exists())

    def test_invalid_saved_config_prevents_system_layout_mutation(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            (base / "bin").mkdir()
            localectl = base / "bin/localectl"
            localectl.write_text('#!/bin/sh\ntouch "$RECORD"\n')
            localectl.chmod(0o755)
            conf = base / "config/nulllinux/input.conf"
            conf.parent.mkdir(parents=True)
            conf.write_text("# null-input layout gb\n# null-input rate invalid\n")
            env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
                       PATH=f"{base / 'bin'}:/usr/bin:/bin", NULL_ROOT=str(ROOT),
                       RECORD=str(base / "mutated"))
            result = subprocess.run(["bash", str(ROOT / "bin/null-input"), "layout", "us"],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / "mutated").exists())
            self.assertIn("# null-input layout gb", conf.read_text())

    def test_settings_displays_command_failure_and_preserves_status(self):
        prefix = (ROOT / "bin/null-settings").read_text().split(
            "# ------------------------------------------------------------------ reading", 1)[0]
        result = subprocess.run(["bash", "-c", prefix +
            '\nsay() { printf "%s\\n" "$@"; }\n'
            'change bash -c \'echo "permission refused" >&2; exit 9\'\n'],
            env=dict(os.environ, NULL_ROOT=str(ROOT)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 9)
        self.assertIn("could not change this setting", result.stdout)
        self.assertIn("permission refused", result.stdout)

    def test_refused_system_layout_keeps_session_config(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            (base / "bin").mkdir()
            localectl = base / "bin/localectl"
            localectl.write_text("#!/bin/sh\necho 'authorization refused' >&2\nexit 1\n")
            localectl.chmod(0o755)
            conf = base / "config/nulllinux/input.conf"
            conf.parent.mkdir(parents=True)
            conf.write_text("# null-input layout gb\n")
            env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
                       PATH=f"{base / 'bin'}:/usr/bin:/bin", NULL_ROOT=str(ROOT))
            result = subprocess.run(["bash", str(ROOT / "bin/null-input"), "layout", "us"],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("session settings kept", result.stderr)
            self.assertEqual(conf.read_text(), "# null-input layout gb\n")

    def test_invalid_lid_action_is_refused_before_any_write(self):
        result = subprocess.run(["bash", str(ROOT / "bin/null-power"), "set-lid", "bad\nvalue"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_invalid_input_never_changes_config(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            (base / "bin").mkdir()
            sway = base / "bin/swaymsg"
            sway.write_text("#!/bin/sh\nexit 0\n")
            sway.chmod(0o755)
            env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
                       PATH=f"{base / 'bin'}:/usr/bin:/bin", NULL_ROOT=str(ROOT))
            conf = base / "config/nulllinux/input.conf"
            for key, value in (("rate", "25"), ("delay", "600"), ("speed", "0.5")):
                result = subprocess.run(["bash", str(ROOT / "bin/null-input"), key, value],
                                        env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            before = conf.read_bytes()
            for key, value in (("rate", "-1"), ("delay", "tomorrow"),
                               ("speed", "2"), ("speed", "nan"),
                               ("tap", "enabled\n}\nexec bad"), ("natural", "yes")):
                with self.subTest(key=key, value=value):
                    result = subprocess.run(["bash", str(ROOT / "bin/null-input"), key, value],
                                            env=env, capture_output=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(conf.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
