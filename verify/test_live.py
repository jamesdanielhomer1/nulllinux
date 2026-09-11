"""Try/install launcher tests; no real installer or session is started."""
import os
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LiveLauncher(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="null-live-test-'$(); ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ['bin', 'lib', 'commands']:
            (self.root / name).mkdir()
        shutil.copyfile(ROOT / 'bin/null-live', self.root / 'bin/null-live')
        shutil.copyfile(ROOT / 'lib/menu.sh', self.root / 'lib/menu.sh')
        self.environment = os.environ.copy()
        self.environment.update(NULL_ROOT=str(self.root),
                                SWAYSOCK=str(self.root / 'sway.sock'),
                                PATH=str(self.root / 'commands') + ':' + os.environ['PATH'])
        self.command('liveinst', 'printf called > installer-called\n')
        self.command('foot', 'printf "%s\\n" "$@" > foot-args\n')
        self.command('fzf', 'printf "%s\\n" "${TEST_PICK:-Try nullLinux}"\n')
        self.command('swaymsg', '''python3 - "$@" <<'PY'
import json, pathlib, sys
pathlib.Path('sway-args').write_text(json.dumps(sys.argv[1:]))
PY
''')
        self.live(True)

    def live(self, active):
        (self.root / 'lib/live.sh').write_text('null_is_live() { return ' + ('0' if active else '1') + '; }\n')

    def command(self, name, content):
        path = self.root / 'commands' / name
        path.write_text('#!/bin/bash\n' + content)
        path.chmod(0o755)

    def run_live(self, verb, **environment):
        return subprocess.run(['bash', str(self.root / 'bin/null-live'), verb],
                              cwd=self.root, env=self.environment | environment,
                              capture_output=True, text=True, timeout=5)

    def test_try_never_launches_installer(self):
        result = self.run_live('choose')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'installer-called').exists())

    def test_install_choice_hands_installer_to_compositor(self):
        result = self.run_live('choose', TEST_PICK='Install nullLinux')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'installer-called').exists(), 'installer stayed attached to welcome PTY')
        args = json.loads((self.root / 'sway-args').read_text())
        self.assertEqual(args[:2], ['-q', 'exec'])
        self.assertEqual(shlex.split(args[2]), ['env', 'NULL_ROOT=' + str(self.root),
                                              str(self.root / 'bin/null-live'), 'install'])

    def test_direct_install_uses_supported_liveinst(self):
        result = self.run_live('install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'installer-called').exists())

    def test_failed_compositor_handoff_is_reported(self):
        self.command('swaymsg', 'exit 19\n')
        self.command('notify-send', 'printf called > notification\n')
        result = self.run_live('choose', TEST_PICK='Install nullLinux')
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertFalse((self.root / 'installer-called').exists())
        self.assertTrue((self.root / 'notification').exists())

    def test_installed_system_refuses_installer_and_has_no_welcome(self):
        self.live(False)
        self.assertNotEqual(self.run_live('install').returncode, 0)
        self.assertEqual(self.run_live('welcome').returncode, 0)
        self.assertFalse((self.root / 'installer-called').exists())
        self.assertFalse((self.root / 'foot-args').exists())

    def test_welcome_opens_readable_try_install_window(self):
        result = self.run_live('welcome')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'foot-args').read_text().splitlines()
        self.assertIn('--app-id=null-welcome', args)
        self.assertEqual(args[-1], 'choose')
        self.assertFalse((self.root / 'installer-called').exists())

    def test_failed_installer_status_is_preserved(self):
        self.command('liveinst', 'exit 17\n')
        self.command('notify-send', 'exit 0\n')
        self.assertEqual(self.run_live('install').returncode, 17)

    def test_cancel_never_launches_installer(self):
        self.command('fzf', 'exit 130\n')
        self.assertEqual(self.run_live('choose').returncode, 0)
        self.assertFalse((self.root / 'installer-called').exists())


if __name__ == '__main__':
    unittest.main()
