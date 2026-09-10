"""Completed HDR bake provenance; historical HDR is an explicit legacy input."""
import hashlib
import json
from pathlib import Path

import numpy as np
from formats import read_hdr

TEMPERATURE_MODEL = 'linear-luminance-weighted-v1'
MANIFEST = 'bake-manifest.json'


def sha256(path):
    with Path(path).open('rb') as fh:
        return hashlib.file_digest(fh, 'sha256').hexdigest()


def write_manifest(directory, metadata):
    directory = Path(directory)
    _check_frames(directory, metadata)
    doc = dict(metadata, format=1, temperature_model=TEMPERATURE_MODEL,
               frames_sha256={p.name: sha256(p) for p in sorted(directory.glob('*.hdr'))})
    tmp = directory / (MANIFEST + '.tmp')
    tmp.write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n')
    tmp.replace(directory / MANIFEST)
    return doc


def _check_frames(directory, metadata):
    paths = sorted(directory.glob('*.hdr'))
    count = metadata.get('frames', 0)
    if count <= 0 or {p.name for p in paths} != {f'{i:04d}.hdr' for i in range(count)}:
        raise ValueError(f'{directory}: incomplete frame sequence')
    for path in paths:
        a = read_hdr(path)
        if a.shape != (metadata.get('rows'), metadata.get('cols'), 4):
            raise ValueError(f'{path}: geometry differs from the bake manifest')
        if not np.isfinite(a).all() or (a < 0).any():
            raise ValueError(f'{path}: nonfinite or negative HDR value')
        lit = (a[..., :3] > 0).any(axis=-1)
        if ((a[..., 3][lit] < 1666.99) | (a[..., 3][lit] > 25000.01)).any():
            raise ValueError(f'{path}: emitting temperature outside the Planckian range')
        if (a[..., 3][~lit] != 0).any():
            raise ValueError(f'{path}: dark samples carry temperature')


def verify_manifest(directory, allow_legacy=False):
    directory = Path(directory)
    path = directory / MANIFEST
    frames = sorted(directory.glob('*.hdr'))
    if not frames:
        raise ValueError(f'no HDR frames in {directory}')
    hashes = {p.name: sha256(p) for p in frames}
    if not path.is_file():
        if not allow_legacy:
            raise ValueError(f'{directory}: no completed bake manifest; historical HDR requires '
                             '--allow-legacy and cannot certify the corrected temperature model')
        return {'format': 1, 'temperature_model': 'legacy-unverified', 'frames_sha256': hashes}
    doc = json.loads(path.read_text())
    if doc.get('format') != 1 or doc.get('temperature_model') != TEMPERATURE_MODEL:
        raise ValueError(f'{path}: unsupported bake provenance')
    if doc.get('frames_sha256') != hashes:
        raise ValueError(f'{path}: HDR frame hashes do not match the completed bake')
    if set(hashes) != {f'{i:04d}.hdr' for i in range(doc.get('frames', 0))}:
        raise ValueError(f'{path}: missing or extra HDR frames')
    _check_frames(directory, doc)
    return doc
