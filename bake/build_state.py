"""Content-based build receipts, including every output and declared input."""
import hashlib
import json
from pathlib import Path
import sys

PHYSICS = ['bake.py', 'kerr.py', 'ladder.py', 'scene.py', 'formats.py', 'provenance.py']
SOURCES = {
    'palette': ['derive_palette.py'],
    'ramp-iface': ['derive_ramp.py', 'fontlib.py'],
    'ramp-bake': ['derive_ramp.py', 'fontlib.py'],
    'atlas-iface': ['bake_atlas.py', 'fontlib.py'],
    'atlas-bake': ['bake_atlas.py', 'fontlib.py'],
    'theme': ['export_theme.py'],
    'icons': ['make_icons.py'],
    'hero': PHYSICS,
    'quantise': ['quantise.py', 'formats.py'],
    'targets': PHYSICS + ['derive_targets.py', 'quantise.py'],
    'placeholder': ['placeholder.py', 'quantise.py', 'formats.py', 'ladder.py',
                    'kerr.py', 'derive_palette.py'],
    'boot': ['make_boot_assets.py'],
}
INPUTS = {
    'theme': ['assets/palette.json'],
    'icons': ['assets/palette.bin', 'assets/palette.json', '/usr/share/icons/Adwaita'],
    'hero': ['bake/gpu/target/release/kerr-gpu'],
    'quantise': ['assets/master.hdrcells', 'assets/ramp-bake.json',
                 'assets/palette.json', 'assets/palette.bin'],
    'targets': ['assets/master.hdrcells', 'assets/ramp-bake.json',
                'assets/palette.json', 'assets/palette.bin', 'bake/gpu/target/release/kerr-gpu'],
    'placeholder': ['assets/ramp-bake.json', 'assets/palette.json', 'assets/palette.bin'],
    'boot': ['render/target/release/render', 'assets/target-4.cells',
             'assets/target-2.cells', 'assets/atlas-bake.bin', 'assets/palette.json'],
}


def tree_digest(path, ancestors=frozenset()):
    path = Path(path)
    if path.is_file():
        with path.open('rb') as fh:
            return ['file', hashlib.file_digest(fh, 'sha256').hexdigest()]
    if path.is_dir():
        resolved = path.resolve()
        if resolved in ancestors:
            return ['directory-cycle', str(resolved)]
        ancestors = ancestors | {resolved}
        return ['directory', {str(p.relative_to(path)): tree_digest(p, ancestors)
                              for p in sorted(path.rglob('*')) if p.is_file() or p.is_symlink()}]
    return ['missing']


def inputs(stage, command):
    paths = ['bin/null-build', 'bin/machine', 'bake/build_state.py']
    paths += ['bake/' + p for p in SOURCES.get(stage, [])]
    paths += INPUTS.get(stage, [])
    if stage in ('render', 'kerr-gpu'):
        crate = 'render' if stage == 'render' else 'bake/gpu'
        paths += [crate + '/src', crate + '/Cargo.toml', crate + '/Cargo.lock']
    for flag in ('--font', '--source'):
        if flag in command:
            paths.append(command[command.index(flag) + 1])
    doc = [command, {p: tree_digest(p) for p in sorted(set(paths))}]
    return hashlib.sha256(json.dumps(doc, sort_keys=True).encode()).hexdigest()


def outputs(paths):
    result = {}
    for name in paths:
        p = Path(name)
        directory = name.endswith('.hdrcells') or name in (
            'assets/icons', 'system/plymouth-theme', 'system/sddm-theme')
        if not (p.is_dir() if directory else p.is_file()):
            return None
        digest = tree_digest(p)
        if directory and not digest[1]:
            return None
        result[name] = digest
    return result


def main():
    mode, stage = sys.argv[1:3]
    args = sys.argv[3:]
    split = args.index('--')
    names, command = args[:split], args[split + 1:]
    current_inputs = inputs(stage, command)
    receipt = Path('render/target/null-build-state') / (stage + '.json')
    if mode == 'fingerprint':
        print(current_inputs)
        return 0
    signature = names.pop(0)
    current_outputs = outputs(names)
    if mode == 'fresh':
        try:
            old = json.loads(receipt.read_text())
        except (OSError, ValueError):
            return 1
        return int(not current_outputs or old != {'inputs': current_inputs, 'outputs': current_outputs})
    if mode != 'record' or signature != current_inputs or not current_outputs:
        print(f'{stage}: inputs changed during the build or required outputs are missing', file=sys.stderr)
        return 1
    receipt.parent.mkdir(parents=True, exist_ok=True)
    temporary = receipt.with_suffix('.tmp')
    temporary.write_text(json.dumps({'inputs': current_inputs, 'outputs': current_outputs}, sort_keys=True))
    temporary.replace(receipt)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
