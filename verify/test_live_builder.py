"""Live compose control flow with fake image tools and a private filesystem."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'a' * 40


class LiveBuilder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='null-live-compose-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ['bin', 'commands', 'packaging/repo/repodata', 'work/results']:
            (self.root / name).mkdir(parents=True)
        shutil.copyfile(ROOT / 'bin/null-iso', self.root / 'bin/null-iso')
        (self.root / 'packaging/nulllinux.spec').write_text('fixture')
        (self.root / 'packaging/nulllinux-live.ks').write_text(
            'url --url=https://download.fedoraproject.org/pub/fedora/linux/releases/$releasever/Everything/$basearch/os/\n'
            'repo --name=nulllinux --baseurl=file://NULLLINUX_REPO\n')
        (self.root / 'packaging/repo/nulllinux-test.rpm').write_bytes(b'package')
        (self.root / 'packaging/repo/BUILD-INFO.json').write_text(json.dumps({'source_commit': REVISION}))
        (self.root / 'work/results/previous.iso').write_bytes(b'previous compose')
        (self.root / 'work/nulllinux-0.1.0.iso').write_bytes(b'previous complete ISO')
        self.command('rpmspec', 'echo 0.1.0\n')
        self.command('id', 'echo 0\n')
        self.command('df', 'printf "Avail\\n100G\\n"\n')
        self.command('createrepo_c', 'exit 0\n')
        self.command('ksvalidator', 'exit "${TEST_KS_STATUS:-0}"\n')
        self.command('git', 'case "$1" in rev-parse) printf "%s\\n" "' + REVISION + '" ;; status) : ;; esac\n')
        (self.root / 'bin/pkg').write_text('#!/bin/bash\necho 44\n')
        (self.root / 'bin/pkg').chmod(0o755)
        self.command('livemedia-creator', '''
printf '%s\\n' "$@" > "$NULL_ROOT/compose-args"
while [ "$#" -gt 0 ]; do
  case $1 in --resultdir) result=$2; shift ;; --ks) ks=$2; shift ;; esac
  shift
done
cp "$ks" "$NULL_ROOT/used.ks"
mkdir -p "$result/images"
printf 'composed ISO' > "$result/images/boot.iso"
exit "${TEST_COMPOSE_STATUS:-0}"
''')
        self.command('mkksiso', 'cp "${@: -2:1}" "${@: -1}"\n')
        self.environment = os.environ | {
            'NULL_ROOT': str(self.root), 'NULL_ISO_WORK': str(self.root / 'work'),
            'PATH': str(self.root / 'commands') + ':' + os.environ['PATH'],
        }

    def command(self, name, code):
        path = self.root / 'commands' / name
        path.write_text('#!/bin/bash\n' + code)
        path.chmod(0o755)

    def build(self, **environment):
        return subprocess.run(['bash', str(self.root / 'bin/null-iso'), '--yes'],
                              env=self.environment | environment, cwd=self.root,
                              capture_output=True, text=True, timeout=20)

    def assert_previous_survives(self):
        self.assertEqual((self.root / 'work/results/previous.iso').read_bytes(), b'previous compose')
        self.assertEqual((self.root / 'work/nulllinux-0.1.0.iso').read_bytes(), b'previous complete ISO')

    def test_invalid_kickstart_preserves_previous_composition(self):
        self.assertNotEqual(self.build(TEST_KS_STATUS='1').returncode, 0)
        self.assert_previous_survives()

    def test_failed_composition_preserves_previous_results(self):
        self.assertNotEqual(self.build(TEST_COMPOSE_STATUS='1').returncode, 0)
        self.assert_previous_survives()

    def test_success_uses_concrete_urls_and_new_work_directory(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        ks = (self.root / 'used.ks').read_text()
        self.assertNotIn('$releasever', ks)
        self.assertNotIn('$basearch', ks)
        self.assertNotIn('NULLLINUX_REPO', ks)
        self.assertIn('/44/Everything/x86_64/os/', ks)
        self.assertEqual((self.root / 'work/results/previous.iso').read_bytes(), b'previous compose')
        self.assertEqual((self.root / 'work/nulllinux-0.1.0.iso').read_bytes(), b'composed ISO')

    def test_stale_package_is_refused_before_composition(self):
        (self.root / 'packaging/repo/BUILD-INFO.json').write_text(json.dumps({'source_commit': 'b' * 40}))
        self.assertNotEqual(self.build().returncode, 0)
        self.assertFalse((self.root / 'compose-args').exists())
        self.assert_previous_survives()


if __name__ == '__main__':
    unittest.main()
