# Bake contract

The HDR channels are linear RGB and observed temperature in kelvin. Temperature
is the **linear-luminance-weighted mean** of the emitting samples. The additive
quantities are `L = RGB · (0.2126, 0.7152, 0.0722)` and `L*T`. Sum or average those
quantities through both resampling axes, then divide to recover temperature;
use zero when `L == 0`. Empty samples reduce radiance without cooling the light.
The CPU reference, WGSL tracer, HDR box filter and both screen derivers use this
definition. Averaging temperature directly, including empty samples, is invalid.

The GPU bake writes `bake-manifest.json` only after every requested HDR frame
has been written. It records the scene, geometry, supersampling, step budget,
renderer and source hashes, temperature model and every frame's SHA-256.
`pack_master.py` verifies that manifest and emits `master.hero.provenance.json`
alongside the packed master. `null-prebake` validates the complete resulting
asset set before writing its package manifest.

The historical v0.1.0 master predates this temperature contract. Its RGB can be
recovered exactly from the release archive, but its averaged temperature has
already lost information. Resampling cannot recover the missing temperature
moments. A corrected release therefore requires a new GPU bake and fresh tone,
strike, boot and screen-cache derivation. Do not overwrite the old release's
checksums or describe repacked legacy HDR as a corrected bake.

For historical comparisons and recovery only, `pack_master.py --allow-legacy`
or `null-prebake --allow-legacy /path/to/master.hdrcells` permits HDR with no bake
manifest and records `temperature_model: legacy-unverified` in the packed
master's provenance. This explicit label is not release acceptance.

Small CPU and build-driver regressions run with:

```sh
python3 -B -m unittest discover -s bake -p 'test_*.py'
cargo test --locked --manifest-path render/Cargo.toml --lib derive::
```

`test_build.py` executes the real shell drivers against disposable external-tool
fixtures. It verifies build ordering and output locations without a GPU or
touching the user's icon theme. Actual shader parity and a full production bake
remain separate release checks.

Production generation needs Python 3.14, numpy, Pillow, Rust/Cargo, all nine
Terminus console strikes, Adwaita icons and Vulkan. Software Vulkan is supported.
`bin/null-prebake` builds both Rust crates, selects the tone curve and prepares
each target camera once; the resulting HDR geometry is reused across strikes.
The target cache checks its input and frame hashes before reuse. Quantisation
uses the same 0.25 hysteresis margin as screen derivation.

```sh
cargo build --locked --release --manifest-path bake/gpu/Cargo.toml
python3 bake/bake.py --out assets/master.hdrcells
bin/null-prebake assets/master.hdrcells
```
