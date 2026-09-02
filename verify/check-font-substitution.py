#!/usr/bin/env python3
"""Does the intended font actually render? (NULL.md §8.10)

A rendering engine asked for a font it cannot use does not report the
substitution. Style queries echo the requested name straight back while the
renderer draws something else entirely -- so "I set the font and the setting
stuck" is not evidence of anything.

The only reliable question is a MEASUREMENT: how wide is a string in the font
the engine actually chose? And a measurement needs controls, or it proves
nothing:

  * a BOGUS family, which cannot exist. Whatever it measures IS the fallback.
    If the intended font measures the same as the bogus one, the intended font
    is not being used.
  * a family KNOWN TO DIFFER. If everything measures the same, including this,
    the probe itself is broken and its passes are worthless.

Both engines are probed, because they fail differently: a bitmap-only font is
usable by the toolkit and invisible to a browser engine at any size.
"""

import sys

CONTROL_BOGUS = "Nonexistent Family Zzyzx 9000"
CONTROL_DIFFERENT = "Liberation Mono"
SAMPLE = "MMMMMMMMMMWWWWWWWWWWiiiiiiiiii"   # wide spread of advances
SIZE_PT = int(__import__("os").environ.get("PROBE_PT", "12"))


# ----------------------------------------------------------------- toolkit
def measure_pango(families):
    import gi
    gi.require_version("Pango", "1.0")
    gi.require_version("PangoCairo", "1.0")
    from gi.repository import Pango, PangoCairo

    ctx = PangoCairo.font_map_get_default().create_context()
    out = {}
    for fam in families:
        desc = Pango.FontDescription()
        desc.set_family(fam)
        desc.set_size(SIZE_PT * Pango.SCALE)
        layout = Pango.Layout(ctx)
        layout.set_font_description(desc)
        layout.set_text(SAMPLE, -1)
        w, _ = layout.get_pixel_size()
        # What the engine actually resolved to, as opposed to what we asked
        # for. Pango will tell us if we ask the right question.
        got = layout.get_context().load_font(desc)
        resolved = got.describe().get_family() if got else "?"
        out[fam] = (w, resolved)
    return out


# ------------------------------------------------------------ browser engine
def measure_webkit(families):
    import os
    # An offscreen window cannot back a web view here: the web process wants a
    # GL context and the offscreen backend has none, which aborts the process
    # rather than degrading. A real window with compositing disabled measures
    # exactly the same text and does not need one.
    os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
    os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    from gi.repository import Gtk, WebKit2, GLib

    if not Gtk.init_check()[0]:
        return None  # no display; caller reports honestly rather than passing

    js_families = ",".join(repr(f) for f in families)
    # Measure AND draw. An advance width can come from metrics the engine can
    # read while painting falls back to something else entirely -- which is the
    # substitution being hunted, so a width alone cannot detect it. The ink
    # signature is what the engine actually put on the canvas.
    html = f"""<!doctype html><meta charset=utf-8><body><script>
      window.__r = (function () {{
        var out = {{}}, fams = [{js_families}];
        var cv = document.createElement('canvas');
        cv.width = 900; cv.height = 40;
        var c = cv.getContext('2d');
        for (var i = 0; i < fams.length; i++) {{
          // Quote the family so a multi-word name is one family, not several.
          var f = '{SIZE_PT}pt "' + fams[i].replace(/"/g, '') + '"';
          c.font = f;
          var w = c.measureText({SAMPLE!r}).width;
          c.fillStyle = '#000'; c.fillRect(0, 0, cv.width, cv.height);
          c.fillStyle = '#fff'; c.textBaseline = 'top';
          c.fillText({SAMPLE!r}, 0, 4);
          var d = c.getImageData(0, 0, cv.width, cv.height).data;
          var ink = 0, sig = 0;
          for (var p = 0; p < d.length; p += 4) {{
            if (d[p] > 40) {{ ink++; sig = (sig * 31 + p) % 2147483647; }}
          }}
          out[fams[i]] = [w, ink, sig];
        }}
        return JSON.stringify(out);
      }})();
    </script></body>"""

    win = Gtk.Window()
    win.set_default_size(1, 1)
    view = WebKit2.WebView()
    win.add(view)
    win.show_all()

    state = {}
    loop = GLib.MainLoop()

    def on_js(src, res, _):
        try:
            val = view.evaluate_javascript_finish(res)
            state["raw"] = val.to_string()
        except Exception as e:                       # noqa: BLE001
            state["error"] = str(e)
        loop.quit()

    def on_load(_v, event):
        if event == WebKit2.LoadEvent.FINISHED:
            view.evaluate_javascript("window.__r", -1, None, None, None, on_js, None)

    view.connect("load-changed", on_load)
    view.load_html(html, "file:///")
    GLib.timeout_add_seconds(20, lambda: (loop.quit(), False)[1])
    loop.run()

    if "raw" not in state:
        return {"__error__": state.get("error", "timed out")}
    import json
    return {k: (round(v[0], 2), f"ink {v[1]}, sig {v[2]}")
            for k, v in json.loads(state["raw"]).items()}


# --------------------------------------------------------------------- report
def report(engine, intended, results):
    print(f"\n== {engine}")
    if results is None:
        print("  SKIPPED: no display available. Not a pass.")
        return None
    if "__error__" in results:
        print(f"  FAILED TO PROBE: {results['__error__']}")
        return False

    width = max(len(f) for f in results)
    for fam, (w, resolved) in results.items():
        tag = ""
        if fam == intended:
            tag = "  <- intended"
        elif fam == CONTROL_BOGUS:
            tag = "  <- bogus (this IS the fallback)"
        elif fam == CONTROL_DIFFERENT:
            tag = "  <- control"
        extra = f"   resolved: {resolved}" if resolved else ""
        print(f"  {fam:<{width}}  {w:>8} px{extra}{tag}")

    # Compare on everything known about each family -- width AND, where the
    # engine gives it, the signature of what was actually painted.
    ours = results[intended]
    bogus = results[CONTROL_BOGUS]
    diff = results[CONTROL_DIFFERENT]

    ok = True
    if len({ours, bogus, diff}) == 1:
        print("\n  FAIL: every family measures the same. The PROBE is broken --")
        print("        a project-wide !important rule will do this -- so nothing")
        print("        it reports can be trusted, pass or fail.")
        return False
    if ours == bogus:
        print(f"\n  FAIL: '{intended}' measures exactly what a nonexistent family")
        print("        measures. The engine is drawing the fallback and saying")
        print("        nothing. This is the failure §8.10 is about.")
        ok = False
    else:
        print(f"\n  ok: '{intended}' is distinct from the fallback")
    if diff == bogus:
        print(f"  note: the control '{CONTROL_DIFFERENT}' is itself missing;")
        print("        it is not discriminating anything.")
    return ok


def main():
    intended = sys.argv[1] if len(sys.argv) > 1 else "Terminus"
    fams = [intended, CONTROL_DIFFERENT, CONTROL_BOGUS]
    if intended != "Terminus":
        fams.insert(1, "Terminus")

    print(f"intended family: {intended}")
    print(f"sample: {len(SAMPLE)} chars at {SIZE_PT}pt")

    results = [report("toolkit (Pango)", intended, measure_pango(fams))]
    try:
        results.append(report("browser engine (WebKit)", intended, measure_webkit(fams)))
    except Exception as e:                            # noqa: BLE001
        print(f"\n== browser engine (WebKit)\n  FAILED TO PROBE: {e}")
        results.append(False)

    verdict = [r for r in results if r is not None]
    print()
    if all(verdict) and verdict:
        print("PASS: the intended font renders in every engine probed.")
        return 0
    print("FAIL: at least one engine is not drawing the intended font.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
