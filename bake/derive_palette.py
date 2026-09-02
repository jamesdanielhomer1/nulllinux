#!/usr/bin/env python3
"""Derive the render palette from the Planckian locus (NULL.md §4.5).

256 entries: 32 blackbody temperatures x 8 values.

Built ANALYTICALLY, never by clustering over the frames. A data-fitted palette
drifts as the object rotates, and the entire point is that the same colours
hold across every surface and every frame (I6).

The construction is valid because of the physics: Doppler shifting a blackbody
yields another blackbody, so observed chromaticity is a function of ONE
variable. The chromaticity axis is one-dimensional and the value axis only
trims the residual between ramp steps (§4.3).
"""

import argparse
import json
import struct
from pathlib import Path

# The validity window of the cubic-spline approximation to the Planckian locus
# used below. Going outside it does not fail loudly, it just returns nonsense.
T_MIN, T_MAX = 1667.0, 25000.0

N_TEMPS, N_VALUES = 32, 8

# §4.5: the value axis is deliberately narrow. It exists only to carry the
# residual between ramp steps. 0.35 linear is about 63% once sRGB-encoded, so
# the darkest entry is NOT dark -- darkness comes from sparse glyphs, not from
# dark colour. A wide value axis WILL be used to make things dark, and the
# result is a muddy frame in which the void has stopped being empty.
V_MIN, V_MAX = 0.35, 1.0


def planckian_xy(t):
    """CIE 1931 xy chromaticity of a blackbody at temperature t (Kelvin).

    Kim et al. cubic-spline approximation, valid 1667 K .. 25000 K.
    """
    if not (T_MIN - 1e-9 <= t <= T_MAX + 1e-9):
        raise ValueError(f"{t} K is outside the approximation's validity window")

    t2, t3 = t * t, t * t * t
    if t <= 4000.0:
        x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
    else:
        x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390

    x2, x3 = x * x, x * x * x
    if t <= 2222.0:
        y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
    elif t <= 4000.0:
        y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
    else:
        y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
    return x, y


def xy_to_linear_srgb(x, y):
    """xy chromaticity -> linear sRGB, normalised so the brightest channel is 1.

    Normalising rather than clamping preserves HUE: the temperature decides the
    colour and the value axis decides the brightness, and letting an
    out-of-range channel clip would quietly desaturate the hottest and coolest
    ends -- exactly the two ends that carry the Doppler asymmetry (§4.7).
    """
    if y <= 1e-9:
        raise ValueError("degenerate chromaticity")
    X, Y, Z = x / y, 1.0, (1.0 - x - y) / y

    r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z
    g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
    b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z

    # Colours outside the sRGB gamut give a negative channel. Lift toward the
    # achromatic axis by the smallest amount that makes every channel valid;
    # this is desaturation, which is honest, rather than clipping, which is a
    # hue shift.
    m = min(r, g, b)
    if m < 0.0:
        r, g, b = r - m, g - m, b - m

    peak = max(r, g, b)
    if peak <= 0.0:
        return 0.0, 0.0, 0.0
    return r / peak, g / peak, b / peak


def srgb_encode(c):
    c = 0.0 if c < 0.0 else (1.0 if c > 1.0 else c)
    return 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1.0 / 2.4)) - 0.055


def build():
    """Return (entries, temps, values). Index = temperature*N_VALUES + value."""
    # Log-spaced temperatures: perceived colour change per octave is far more
    # uniform than per kelvin, so a linear sweep would crowd the blue end.
    ratio = (T_MAX / T_MIN) ** (1.0 / (N_TEMPS - 1))
    temps = [T_MIN * ratio ** i for i in range(N_TEMPS)]
    values = [V_MIN + (V_MAX - V_MIN) * i / (N_VALUES - 1) for i in range(N_VALUES)]

    entries = []
    for t in temps:
        lr, lg, lb = xy_to_linear_srgb(*planckian_xy(t))
        for v in values:
            entries.append(tuple(
                max(0, min(255, round(srgb_encode(c * v) * 255.0)))
                for c in (lr, lg, lb)
            ))
    return entries, temps, values


def sample_at(entries, temps, kelvin, value_index=N_VALUES - 1):
    """Nearest palette entry to a named temperature -- how §4.6 samples roles."""
    ti = min(range(len(temps)), key=lambda i: abs(temps[i] - kelvin))
    return ti * N_VALUES + value_index, entries[ti * N_VALUES + value_index], temps[ti]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="assets/palette.bin")
    ap.add_argument("--meta", default="assets/palette.json")
    ap.add_argument("--show", action="store_true")
    args = ap.parse_args()

    entries, temps, values = build()
    assert len(entries) == 256, len(entries)

    Path(args.out).write_bytes(b"".join(struct.pack("BBB", *e) for e in entries))

    # Semantic roles (§4.6). Emissive roles are SAMPLED from the palette at
    # named temperatures and are physics. Chrome neutrals are the absence of
    # emission: they are chosen, and are labelled chosen rather than dressed up
    # as derived.
    roles_emissive = {
        "dim":       T_MIN,
        "error":     1900.0,
        "warning":   2800.0,
        "neutral":   5700.0,   # the solar band
        "accent":   13500.0,
        "highlight": T_MAX,
    }
    roles = {}
    for name, k in roles_emissive.items():
        idx, rgb, actual = sample_at(entries, temps, k)
        roles[name] = {"origin": "sampled from the locus", "requested_K": k,
                       "actual_K": round(actual, 1), "index": idx,
                       "hex": "#%02x%02x%02x" % rgb}
    for name, hexv, why in (
        ("void",       "#000000", "the true empty -- rendered as the space character, not a colour"),
        ("background", "#05060a", "chosen; near-black"),
        ("surface",    "#0c0f16", "chosen; lifted, for genuinely raised elements ONLY (§4.6)"),
        ("line",       "#232c40", "chosen; the rule colour"),
    ):
        roles[name] = {"origin": "CHOSEN, not derived", "hex": hexv, "why": why}

    Path(args.meta).write_text(json.dumps({
        "entries": 256, "temps": N_TEMPS, "values": N_VALUES,
        "temperature_range_K": [T_MIN, T_MAX],
        "value_range_linear": [V_MIN, V_MAX],
        "layout": "index = temperature_index * 8 + value_index",
        "temperatures_K": [round(t, 1) for t in temps],
        "values_linear": values,
        "roles": roles,
    }, indent=2) + "\n")

    print(f"palette: 256 entries = {N_TEMPS} temperatures x {N_VALUES} values")
    print(f"  {T_MIN:.0f} K .. {T_MAX:.0f} K, log-spaced")
    print(f"  value {V_MIN} .. {V_MAX} linear "
          f"({srgb_encode(V_MIN)*100:.0f}% .. {srgb_encode(V_MAX)*100:.0f}% encoded — deliberately narrow)")
    print(f"  -> {args.out} ({Path(args.out).stat().st_size} bytes), {args.meta}")

    if args.show:
        print("\n  semantic roles (§4.6):")
        for n, r in roles.items():
            tag = r["hex"]
            extra = f"  {r['actual_K']:.0f} K" if "actual_K" in r else "  chosen"
            print(f"    {n:<11} {tag} {extra}")
        print("\n  the locus, at full value:")
        for i, t in enumerate(temps):
            rgb = entries[i * N_VALUES + N_VALUES - 1]
            print(f"    {t:>8.0f} K  #%02x%02x%02x" % rgb)


if __name__ == "__main__":
    main()
