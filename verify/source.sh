#!/usr/bin/env bash
# Source/build checks only. No installed-system configuration or session changes.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"
unset NULL_TEST_MACHINE

python3 - <<'PY'
import ast
from pathlib import Path
import subprocess

files = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z']
).decode().split('\0')
shells = python = 0
for name in sorted(set(filter(None, files))):
    path = Path(name)
    if not path.is_file():
        continue
    data = path.read_bytes()
    first = data.split(b'\n', 1)[0]
    if name.endswith('.sh') or (first.startswith(b'#!') and b'bash' in first):
        if b'\r\n' in data:
            raise SystemExit(f'{name}: CRLF breaks Linux scripts; check .gitattributes')
        subprocess.run(['bash', '-n', name], check=True)
        shells += 1
    elif name.endswith('.py'):
        ast.parse(data, filename=name)
        python += 1
print(f'PASS: syntax of {shells} shell and {python} Python sources')
PY

for check in check-package-abstraction selftest-package-abstraction \
             check-callers selftest-callers check-binds selftest-binds \
             selftest-report-first; do
  bash "verify/$check.sh"
done
python3 verify/check-report-first.py
python3 -m unittest discover -s verify -p 'test_*.py' -v
python3 -m unittest discover -s bake -p 'test_*.py' -v
python3 bake/ladder.py
python3 bake/validate.py
cargo test --manifest-path render/Cargo.toml --locked --all-targets
cargo clippy --manifest-path render/Cargo.toml --locked --all-targets -- -D clippy::correctness
cargo build --manifest-path render/Cargo.toml --locked --release --bins
printf '\nPASS: source checks and production renderer build\n'
