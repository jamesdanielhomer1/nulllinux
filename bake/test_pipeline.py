"""Small CPU regressions for the HDR and screen-derivation contracts.

Run with python3 -m unittest discover -s bake -p 'test_*.py'.
"""
import tempfile
import unittest
import subprocess
import sys
from unittest.mock import patch
from pathlib import Path

import numpy as np

import bake
import derive_for_screen
from pack_master import write_master
from formats import write_hdr
from provenance import verify_manifest, write_manifest


class TemperatureReduction(unittest.TestCase):
    def test_empty_subsamples_reduce_light_without_cooling_it(self):
        hdr = np.zeros((2, 2, 4), dtype=np.float32)
        hdr[0, 0] = [1, 1, 1, 6000]
        got = bake.box_average(hdr, 2)
        np.testing.assert_array_equal(got[0, 0, :3], [.25, .25, .25])
        self.assertEqual(float(got[0, 0, 3]), 6000)

    def test_temperature_is_weighted_by_linear_luminance(self):
        hdr = np.zeros((2, 2, 4), dtype=np.float32)
        hdr[0, 0] = [1, 1, 1, 3000]
        hdr[0, 1] = [3, 3, 3, 9000]
        got = bake.box_average(hdr, 2)
        self.assertAlmostEqual(float(got[0, 0, 3]), 7500, places=3)
        np.testing.assert_array_equal(got[0, 0, :3], [1, 1, 1])

    def test_repeated_reduction_preserves_the_temperature_moment(self):
        rng = np.random.default_rng(42)
        hdr = rng.random((8, 8, 4), dtype=np.float32)
        hdr[..., 3] *= 25000
        once = bake.box_average(hdr, 4)
        twice = bake.box_average(bake.box_average(hdr, 2), 2)
        np.testing.assert_allclose(once, twice, rtol=2e-6)

    def test_all_dark_stays_finite_and_empty(self):
        got = bake.box_average(np.zeros((2, 2, 4), dtype=np.float32), 2)
        np.testing.assert_array_equal(got, np.zeros((1, 1, 4)))

    def test_screen_downsampling_keeps_the_lit_samples_temperature(self):
        row = np.array([[1, 6000], [0, 0], [.01, 2000], [.01, 2000],
                        [2, 10000], [2, 10000], [0, 0], [0, 0]], dtype=np.float16)
        plane = np.stack([row, row])
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'test.hero'
            write_master(path, 8, 2, 24, [plane, plane], (0, 100, 1))
            glyphs, colours, _, _ = derive_for_screen.derive(
                path, 4, 1, {'ramp': ' .:@', 'coverage': [0, .3, .6, 1]},
                {'temperatures_K': [2000, 6000, 10000]}, log=lambda _: None)
        self.assertGreater(int(glyphs[0][0, 0]), 0)
        self.assertEqual(int(colours[0][0, 0]) // 8, 1)

    def test_reference_supersampling_matches_hdr_reduction(self):
        import ladder
        import render_kerr
        bands = ladder.build()
        direct = render_kerr.render(16, 8, bands=bands, supersample=2)
        large = render_kerr.render(32, 16, bands=bands)
        reduced = bake.box_average(large, 2)
        np.testing.assert_allclose(direct[..., :3], reduced[..., :3], rtol=2e-6)
        np.testing.assert_allclose(direct[..., 3], reduced[..., 3], rtol=2e-6)

    def test_prebuilt_targets_use_the_screen_hysteresis_default(self):
        import argparse
        import inspect
        import derive_targets
        from quantise import quantise_sequence
        seen = []
        class ParserCaptured(Exception):
            pass
        def capture(parser):
            seen.append(parser.get_default('hysteresis'))
            raise ParserCaptured
        with patch.object(argparse.ArgumentParser, 'parse_args', autospec=True, side_effect=capture):
            with self.assertRaises(ParserCaptured):
                derive_targets.main()
        self.assertEqual(seen[0], inspect.signature(quantise_sequence).parameters['hysteresis'].default)


class MasterProvenance(unittest.TestCase):
    def test_incomplete_bake_cannot_acquire_a_completion_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            write_hdr(Path(td) / '0000.hdr', np.zeros((2, 2, 4), dtype=np.float32))
            with self.assertRaises(ValueError):
                write_manifest(td, {'frames': 2, 'cols': 2, 'rows': 2})

    def test_nonfinite_hdr_cannot_acquire_a_completion_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            a = np.zeros((2, 2, 4), dtype=np.float32)
            a[0, 0, 0] = np.nan
            write_hdr(Path(td) / '0000.hdr', a)
            with self.assertRaises(ValueError):
                write_manifest(td, {'frames': 1, 'cols': 2, 'rows': 2})

    def test_a_changed_completed_frame_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / '0000.hdr'
            a = np.zeros((2, 2, 4), dtype=np.float32)
            a[0, 0] = [1, 1, 1, 6000]
            write_hdr(p, a)
            write_manifest(td, {'frames': 1, 'cols': 2, 'rows': 2})
            self.assertEqual(verify_manifest(td)['frames'], 1)
            a[0, 0, 0] = 2
            write_hdr(p, a)
            with self.assertRaisesRegex(ValueError, 'hashes'):
                verify_manifest(td)

    def test_packing_historical_hdr_requires_an_explicit_legacy_choice(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            frames = root / 'frames'
            frames.mkdir()
            write_hdr(frames / '0000.hdr', np.ones((2, 2, 4), dtype=np.float32))
            result = subprocess.run(
                [sys.executable, '-B', str(Path(__file__).with_name('pack_master.py')),
                 '--frames-dir', str(frames), '--out', str(root / 'master.hero'),
                 '--black-pct', '0', '--white-pct', '99', '--gamma', '1'],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('--allow-legacy', result.stdout + result.stderr)


class PreparedTargets(unittest.TestCase):
    def test_camera_geometry_is_reused_and_changed_inputs_are_rejected(self):
        import derive_targets
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            master = root/'master'
            master.mkdir()
            a = np.zeros((8, 8, 4), dtype=np.float32)
            a[2, 2] = [1, 1, 1, 6000]
            write_hdr(master/'0000.hdr', a)
            gpu = root/'gpu'
            gpu.write_bytes(b'renderer identity')
            cache = root/'cache'
            traced = []
            def trace(cols, rows, frames, ss, out, max_steps, quiet):
                traced.append((cols, rows))
                Path(out).mkdir()
                write_hdr(Path(out)/'0000.hdr', np.zeros((rows, cols, 4), np.float32))
            with patch.object(bake, 'GPU', gpu), patch.object(bake, 'bake', side_effect=trace):
                derive_targets.prepare(master, cache, 1, 4, 3000)
                for _ in range(9):
                    derive_targets.verify_prepared(master, cache, 1, 4, 3000)
                self.assertEqual(traced, [(80, 24), (40, 16)])
                gpu.write_bytes(b'different renderer')
                with self.assertRaises(ValueError):
                    derive_targets.verify_prepared(master, cache, 1, 4, 3000)
                gpu.write_bytes(b'renderer identity')
                (cache/'target-2/0000.hdr').unlink()
                with self.assertRaises(ValueError):
                    derive_targets.verify_prepared(master, cache, 1, 4, 3000)


class InvalidRamp(unittest.TestCase):
    def test_ramp_needs_boundaries_representable_length_and_finite_coverage(self):
        from quantise import Ramp
        for chars, coverage in [(' ', [0]), (' .', [-.1, .5]), (' .', [0, 1.1]),
                                (' .', [0, float('inf')]), (' .', [0]),
                                ('a' * 256, np.linspace(0, 1, 256))]:
            with self.subTest(chars=chars, coverage=coverage):
                with self.assertRaisesRegex(ValueError, 'ramp'):
                    Ramp({'ramp': chars, 'coverage': coverage})


if __name__ == '__main__':
    unittest.main()
