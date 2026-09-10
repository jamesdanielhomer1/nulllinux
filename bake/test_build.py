"""Exercise the real build drivers in a disposable tree with tiny tool fixtures.

The fixtures enforce each external tool's input/output contract; no GPU, cargo
build, home-directory icon install or production assets are touched.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOL = r'''
import os, sys
from pathlib import Path
a=sys.argv[1:]
def opt(name, default=None):
    return a[a.index(name)+1] if name in a else default
def file(name):
    p=Path(name); p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'fixture')
def need(name):
    assert Path(name).is_file(), 'missing input: '+name
if Path(sys.argv[0]).name == 'cargo':
    crate=Path(opt('--manifest-path')).parent
    for name in (['render','column'] if crate.name=='render' else ['kerr-gpu']):
        file(str(crate/'target/release'/name))
    sys.exit(0)
name=Path(a[0]).name
if name=='build_state.py':
    os.execv(sys.executable, [sys.executable, '-B', *a])
elif name=='derive_palette.py':
    file('assets/palette.bin'); file('assets/palette.json')
elif name in ('derive_ramp.py','bake_atlas.py'):
    file(opt('--out'))
elif name=='export_theme.py':
    for p in ['config/sway/colours.conf','config/foot/foot.ini','config/shell/colours.sh',
              'config/vconsole/vtrgb','config/nano/nanorc','config/gtk-3.0/gtk.css',
              'config/gtk-3.0/settings.ini','config/gtk-4.0/gtk.css','config/gtk-4.0/settings.ini']:
        file(p)
    p=Path('assets/palette.json')
    if p.is_file(): Path('config/sway/colours.conf').write_bytes(p.read_bytes())
elif name in ('placeholder.py','bake.py'):
    out=Path(opt('--out')); out.mkdir(parents=True,exist_ok=True); file(str(out/'0000.hdr'))
elif name=='tune.py':
    print('--black-pct 0 --white-pct 99 --gamma 1')
elif name=='quantise.py':
    assert Path(opt('--frames-dir')).is_dir()
    file(opt('--out'))
elif name=='derive_targets.py':
    with Path('target-preparations.log').open('a') as log:
        log.write('prepare\n' if '--prepare-only' in a else 'quantise\n')
    if '--prepare-only' in a:
        file(str(Path(opt('--prepared'))/'ready'))
        sys.exit(0)
    if '--prepared' in a: need(str(Path(opt('--prepared'))/'ready'))
    for p in ['master.cells','target-2.cells','target-4.cells','tty.cells','logo.cells']:
        file('assets/'+p)
elif name=='pack_master.py':
    # The real writer cannot open its output when its parent is missing.
    Path(opt('--out')).write_bytes(b'NLHM')
elif name=='prebuilt.py':
    file(str(Path(opt('--write-manifest'))/'assets/prebuilt/MANIFEST.json'))
elif name=='make_icons.py':
    file(str(Path(opt('--out',str(Path.home()/'.local/share/icons/nulllinux')))/'index.theme'))
elif name=='make_boot_assets.py':
    for p in ['render/target/release/render', opt('--atlas','assets/atlas-bake.bin'),
              opt('--palette','assets/palette.json'),
              opt('--plymouth-cells','assets/target-4.cells'),
              opt('--sddm-cells','assets/target-2.cells')]: need(p)
    for p in ['plymouth-theme','sddm-theme']:
        file(str(Path(opt('--out','system'))/p/'frame.png'))
else: raise AssertionError('unexpected tool '+name)
'''


@unittest.skipUnless(os.name == 'posix' and shutil.which('bash'), 'Linux build drivers')
class BuildOrder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='null-build-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for p in ['bin', 'tools', 'assets', 'bake', 'render/src', 'machines', 'home']:
            (self.root/p).mkdir(parents=True)
        state = ROOT/'bake/build_state.py'
        if state.exists(): shutil.copyfile(state, self.root/'bake/build_state.py')
        machine = self.root/'bin/machine'
        machine.write_text('#!/bin/sh\necho ter-112n\n')
        machine.chmod(0o755)
        for name in ['python3', 'cargo']:
            p=self.root/'tools'/name
            p.write_text('#!'+sys.executable+'\n'+TOOL)
            p.chmod(0o755)
        cp = self.root/'tools/cp'
        cp.write_text('#!'+sys.executable+'\nimport os, sys\n'
                      'if sys.argv[-1] == os.environ.get("COPY_FAIL_ON"): sys.exit(1)\n'
                      'os.execv("/usr/bin/cp", ["cp", *sys.argv[1:]])\n')
        cp.chmod(0o755)
        self.env = dict(os.environ, NULL_ROOT=str(self.root), HOME=str(self.root/'home'),
                        PATH=str(self.root/'tools')+os.pathsep+os.environ['PATH'])

    def run_driver(self, name, *args):
        result = subprocess.run(['bash', str(ROOT/'bin'/name), *args],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        return result

    def test_unchanged_stage_is_skipped(self):
        self.run_driver('null-build', '--only=palette')
        result = self.run_driver('null-build', '--only=palette')
        self.assertIn('up to date', result.stdout)

    def test_missing_directory_member_is_rebuilt(self):
        self.run_driver('null-build', '--only=icons')
        (self.root/'assets/icons/index.theme').unlink()
        self.run_driver('null-build', '--only=icons')
        self.assertTrue((self.root/'assets/icons/index.theme').is_file())

    def test_directory_symlink_cycle_has_a_bounded_fingerprint(self):
        import json
        from build_state import tree_digest
        source = self.root/'cycle'
        source.mkdir()
        (source/'member').write_text('payload')
        (source/'again').symlink_to(source, target_is_directory=True)
        first = tree_digest(source)
        self.assertLess(len(json.dumps(first)), 1000)
        self.assertEqual(first, tree_digest(source))
        (source/'member').write_text('changed payload')
        self.assertNotEqual(first, tree_digest(source))

    def test_full_build_creates_renderer_before_boot_rasterisation(self):
        self.run_driver('null-build', '--force')
        self.assertTrue((self.root/'system/plymouth-theme/frame.png').is_file())

    def test_skip_hero_produces_a_cells_file(self):
        self.run_driver('null-build', '--force', '--skip-hero')
        self.assertTrue((self.root/'assets/placeholder.cells').is_file())

    def test_placeholder_stage_can_run_on_its_own(self):
        self.run_driver('null-build', '--skip-hero', '--only=placeholder')
        self.assertTrue((self.root/'assets/placeholder.cells').is_file())

    def test_icons_are_built_inside_the_output_tree(self):
        self.run_driver('null-build', '--only=icons')
        self.assertTrue((self.root/'assets/icons/index.theme').is_file())
        self.assertEqual(list((self.root/'home').iterdir()), [])

    def test_palette_change_rebuilds_the_generated_theme(self):
        palette = self.root/'assets/palette.json'
        palette.write_text('first palette')
        self.run_driver('null-build', '--only=theme')
        palette.write_text('changed palette')
        self.run_driver('null-build', '--only=theme')
        self.assertEqual((self.root/'config/sway/colours.conf').read_text(), 'changed palette')

    def test_a_damaged_secondary_output_is_rebuilt(self):
        self.run_driver('null-build', '--only=palette')
        (self.root/'assets/palette.json').write_text('damaged secondary output')
        self.run_driver('null-build', '--only=palette')
        self.assertEqual((self.root/'assets/palette.json').read_bytes(), b'fixture')

    def test_a_missing_generated_gtk_theme_is_rebuilt(self):
        self.run_driver('null-build', '--only=theme')
        (self.root/'config/gtk-4.0/gtk.css').unlink()
        self.run_driver('null-build', '--only=theme')
        self.assertTrue((self.root/'config/gtk-4.0/gtk.css').is_file())

    def test_incomplete_prebuilt_does_not_skip_missing_hero_generation(self):
        prebuilt = self.root/'assets/prebuilt/ter-112n'
        prebuilt.mkdir(parents=True)
        for name in ('master.cells', 'target-2.cells', 'target-4.cells', 'tty.cells', 'ramp-bake.json'):
            (prebuilt/name).write_bytes(b'incomplete')
        self.run_driver('null-build')
        self.assertTrue((self.root/'assets/master.hdrcells/0000.hdr').is_file())

    def test_clean_prebake_builds_all_prerequisites(self):
        if not list(Path('/usr/lib/kbd/consolefonts').glob('ter-1*n.psf.gz')):
            self.skipTest('the prebake driver enumerates installed Terminus strikes')
        (self.root/'master').mkdir()
        (self.root/'assets/ramp-bake.json').write_text('initial ramp')
        self.run_driver('null-prebake', str(self.root/'master'))
        self.assertTrue((self.root/'assets/prebuilt/master.hero').is_file())
        self.assertTrue((self.root/'assets/prebuilt/boot/plymouth-theme/frame.png').is_file())
        self.assertTrue((self.root/'assets/prebuilt/MANIFEST.json').is_file())
        self.assertEqual((self.root/'assets/ramp-bake.json').read_text(), 'initial ramp')
        preparations = (self.root/'target-preparations.log').read_text().splitlines()
        self.assertEqual(preparations.count('prepare'), 1,
                         'the same HDR target geometry must be traced only once across all strikes')

    def test_failed_copy_cannot_relabel_old_prebuilts_as_complete(self):
        if not list(Path('/usr/lib/kbd/consolefonts').glob('ter-1*n.psf.gz')):
            self.skipTest('the prebake driver enumerates installed Terminus strikes')
        (self.root/'master').mkdir()
        prebuilt = self.root/'assets/prebuilt/ter-112n'
        prebuilt.mkdir(parents=True)
        (prebuilt/'ramp-bake.json').write_text('old ramp')
        manifest = prebuilt.parent/'MANIFEST.json'
        manifest.write_text('old completed manifest')
        self.env['COPY_FAIL_ON'] = 'assets/prebuilt/ter-112n/ramp-bake.json'
        result = subprocess.run(['bash', str(ROOT/'bin/null-prebake'), str(self.root/'master')],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertFalse(manifest.exists(), 'a failed rebuild must invalidate earlier completion')


if __name__ == '__main__':
    unittest.main()
