"""Installer-media console regressions; all devices and font tools are doubles."""
import gzip
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def function(path, name):
    match = re.search(r'^' + name + r'\(\).*?^}',
                      (ROOT / path).read_text(), re.M | re.S)
    if not match:
        raise AssertionError(f'{path} has no {name} function')
    return match.group()


class InstallerConsole(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='null-console-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'config/vconsole').mkdir(parents=True)
        (self.root / 'stage').mkdir()
        self.palette = self.root / 'config/vconsole/vtrgb'
        self.palette.write_text((ROOT / 'config/vconsole/vtrgb').read_text())
        self.font = self.root / 'font.psf.gz'
        self.font.write_bytes(gzip.compress(b'fixture-font'))

    def shell(self, source):
        return subprocess.run(['bash', '-c', 'ROOT=' + shlex.quote(str(self.root)) + '\n' + source],
                              cwd=self.root, capture_output=True, timeout=10)

    def stage(self):
        return self.shell(function('bin/null-installer-iso', 'stage_installer_console')
                          + '\nstage_installer_console stage font.psf.gz\n')

    def test_media_carries_exact_font_and_all_palette_slots(self):
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'stage/console.psf').read_bytes(), b'fixture-font')
        rows = [[int(v) for v in row.split(',')] for row in self.palette.read_text().splitlines()]
        expected = b''.join(f'\x1b]P{i:x}{r:02x}{g:02x}{b:02x}'.encode()
                            for i, (r, g, b) in enumerate(zip(*rows)))
        self.assertEqual((self.root / 'stage/console-palette.ansi').read_bytes(), expected)

    def test_malformed_palette_refuses_media_staging(self):
        self.palette.write_text('256,2,3\n')
        self.assertNotEqual(self.stage().returncode, 0)

    def test_missing_font_refuses_media_staging(self):
        self.font.unlink()
        self.assertNotEqual(self.stage().returncode, 0)

    def apply(self, terminal='/dev/tty7', font_result=0):
        (self.root / 'console.psf').write_bytes(b'font')
        (self.root / 'console-palette.ansi').write_bytes(b'palette')
        script = function('bin/null-installer', 'installer_console') + f'''
DRY=0
tty() {{ printf '%s\\n' {shlex.quote(terminal)}; }}
setfont() {{ printf '%s\\n' "$@" > font-args; return {font_result}; }}
installer_console
'''
        return self.shell(script)

    def test_applies_font_and_palette_then_repaints_owned_virtual_console(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'palette\x1b[0m\x1b[2J\x1b[H')
        self.assertEqual((self.root / 'font-args').read_text().splitlines(),
                         ['-C', '/dev/tty7', str(self.root / 'console.psf')])

    def test_terminal_emulator_is_not_reconfigured(self):
        result = self.apply('/dev/pts/4')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'')
        self.assertFalse((self.root / 'font-args').exists())

    def test_font_failure_is_reported_before_drawing(self):
        result = self.apply(font_result=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')


if __name__ == '__main__':
    unittest.main()
