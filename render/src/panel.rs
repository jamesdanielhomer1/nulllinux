//! Chrome primitives (NULL.md §7.1).
//!
//! Frames are box-drawing, meters are characters, readouts are name + dot
//! leader + value. Every surface draws them from here, so they cannot differ
//! between surfaces.

use crate::grid::TextGrid;
use crate::palette::{Palette, Role};

/// The one renderer of "no reading" (§7.1).
///
/// A missing value printed four different ways is four different things to
/// search for. One token, one unit, one alignment -- so a column keeps its
/// shape when a sensor is absent.
pub const UNMEASURED: &str = "--";

/// Replace what the atlas cannot draw with something VISIBLE.
///
/// Never a blank: a blank reads as the program having printed nothing (§7.3).
pub fn sanitise(s: &str, has: impl Fn(char) -> bool) -> String {
    s.chars().map(|c| if has(c) { c } else { '·' }).collect()
}

/// name + dot leader + value, filling exactly `width` cells.
///
/// A row reads as ONE thing rather than two columns floating apart. The label
/// is chrome and the value is data, so they take different roles (§4.6) --
/// colouring the label with its own reading makes every label pulse.
pub fn leader(g: &mut TextGrid, x: usize, y: usize, width: usize,
              name: &str, value: &str, pal: &Palette, value_fg: [u8; 3]) {
    if width < 3 { return }
    let name_len = name.chars().count().min(width);
    let val_len = value.chars().count().min(width.saturating_sub(name_len + 1));
    g.text(x, y, &name[..name.len().min(name_len)], pal.get(Role::Dim));

    let dots = width.saturating_sub(name_len + val_len);
    let line = pal.get(Role::Line);
    for i in 0..dots {
        g.set(x + name_len + i, y, if i == 0 || i == dots.saturating_sub(1) { ' ' } else { '.' }, line);
    }
    g.text(x + width - val_len, y, value, value_fg);
}

/// A meter drawn in CHARACTERS, never a filled rectangle (I1).
///
/// The empty track is a dot, not a space: a space has no readable extent, so a
/// meter at zero would be indistinguishable from an absent one.
pub fn meter(g: &mut TextGrid, x: usize, y: usize, width: usize, level: f32,
             ramp: &[char], pal: &Palette) {
    let fallback = [' ', '@'];
    let ramp = if ramp.is_empty() { &fallback[..] } else { ramp };
    let level = level.clamp(0.0, 1.0);
    let fg = pal.by_level(level);
    let track = pal.get(Role::Line);
    let filled = (level * width as f32).floor() as usize;
    let dense = *ramp.last().unwrap_or(&'@');
    for i in 0..width {
        if i < filled {
            g.set(x + i, y, dense, fg);
        } else if i == filled && filled < width {
            // Sub-cell resolution without a single block character: the
            // boundary cell carries the remainder as ink density.
            let frac = level * width as f32 - filled as f32;
            let idx = ((frac * (ramp.len() - 1) as f32).round() as usize).min(ramp.len() - 1);
            g.set(x + i, y, ramp[idx], fg);
        } else {
            g.set(x + i, y, '·', track);
        }
    }
}



/// A horizontal rule carrying its own section labels, so headers cost no row.
pub fn rule_with_labels(g: &mut TextGrid, y: usize, width: usize,
                        sections: &[(usize, &str)], pal: &Palette) {
    let line = pal.get(Role::Line);
    let dim = pal.get(Role::Dim);
    for x in 0..width { g.set(x, y, '─', line) }
    g.set(0, y, '┌', line);
    for (at, label) in sections {
        let at = *at;
        if at == 0 {
            g.text(2, y, label, dim);
        } else if at < width {
            g.set(at, y, '┬', line);
            g.text(at + 2, y, label, dim);
        }
    }
}

/// A row of bars, one per value, filled the same way a graph is.
///
/// Not a graph: the axis is a LIST, not time. Each bar is drawn several cells
/// wide with a gap between, so it reads as separate columns rather than as a
/// continuous series -- which matters on a panel where every other filled
/// shape is a history and the frame says "last 26s".
pub fn bars(g: &mut TextGrid, x: usize, y: usize, width: usize, height: usize,
            values: &[f32], ramp: &[char], pal: &Palette) {
    if width == 0 || height == 0 || values.is_empty() || ramp.is_empty() { return }
    let track = pal.get(Role::Line);
    let fg = pal.get(Role::Neutral);
    // As wide as fits with a single-cell gap, and at least one cell.
    let each = ((width + 1) / values.len()).max(1);
    let bar = each.saturating_sub(1).max(1);
    for (i, v) in values.iter().enumerate() {
        let bx = x + i * each;
        if bx >= x + width { break }
        let v = v.clamp(0.0, 1.0);
        for r in 0..height {
            let from_bottom = (height - 1 - r) as f32;
            let mut frac = (v * height as f32 - from_bottom).clamp(0.0, 1.0);
            const FLOOR: f32 = 0.12;
            if r == height - 1 { frac = frac.max(FLOOR) }
            const STEPS: f32 = 4.0;
            let ch = if frac <= 0.0 { '·' } else {
                let q = (frac * STEPS).ceil() / STEPS;
                ramp[((q * (ramp.len() - 1) as f32).round() as usize).min(ramp.len() - 1)]
            };
            for c in 0..bar.min((x + width).saturating_sub(bx)) {
                g.set(bx + c, y + r, ch, if frac <= 0.0 { track } else { fg });
            }
        }
    }
}

/// Where the bottom of the column begins, given its height.
///
/// Returns (footer rule row, equaliser's first row, `bottom_from`).
///
/// `bottom_from` is the FIRST ROW THE BOTTOM OWNS -- the SPECTRUM label's row.
/// One meaning, and the only one, because the previous phrasing ("the last row
/// content may use") was read as "the last row written" in the guards above
/// and as "the next free row" in the test below, which differ by one and cost
/// the equaliser three separate times.
///
/// So: a section may write any row STRICTLY BELOW `bottom_from`, and after the
/// sections have run their next-free cursor may be at most `bottom_from`.
///
/// A free function, and tested, because this arithmetic has silently deleted
/// the equaliser twice. Both times the cause was the same shape of mistake: a
/// section above computed "do I have room" one way and the equaliser computed
/// "did they leave me room" another way, the two differed by one, and the
/// result was not a misdrawn panel but a missing feature -- which is the kind
/// of bug you only find by looking at a screenshot and noticing an absence.
pub fn bottom_reserve(rows: usize, footer_h: usize, eq_h: usize)
    -> (usize, usize, usize) {
    let fy = rows.saturating_sub(footer_h);
    let ey = fy.saturating_sub(eq_h + 1);
    let bottom_from = ey.saturating_sub(1);
    (fy, ey, bottom_from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_can_never_reach_the_equalisers_label() {
        // The whole invariant in one line: a section that stops below
        // `bottom_from` leaves the SPECTRUM label row free. Off by one here is
        // a deleted feature, not a cosmetic slip -- it removed the equaliser
        // three separate times.
        for rows in 20..200 {
            let (fy, ey, bottom_from) = bottom_reserve(rows, 4, 6);
            assert_eq!(bottom_from, ey - 1, "rows={rows}: the label is not where the bottom starts");
            assert!(ey + 6 <= fy, "rows={rows}: the equaliser overruns the footer rule");
        }
    }

    #[test]
    fn a_short_panel_yields_everything_rather_than_underflowing() {
        // Subtracting more rows than exist is how this becomes a panic in a
        // compositor callback rather than a missing section.
        for rows in 0..12 {
            let (fy, ey, bottom_from) = bottom_reserve(rows, 4, 6);
            assert!(bottom_from <= ey && ey <= fy && fy <= rows.max(1));
        }
    }

    #[test]
    fn the_column_and_these_tests_reserve_the_same_rows() {
        // Two copies of a constant is how two copies come to disagree.
        let src = include_str!("bin/column.rs");
        assert!(src.contains("const FOOTER_H: usize = 4;"), "FOOTER_H changed");
        assert!(src.contains("const EQ_H: usize = 6;"), "EQ_H changed");
    }

    fn pal() -> Palette { Palette::uniform([1, 2, 3]) }
    fn ramp() -> Vec<char> { " .^<+=*cn3wUyH0@".chars().collect() }
    fn full(ramp: &[char]) -> char { *ramp.last().unwrap() }

    // `bars` is the only filled renderer left, and it inherited the fill rules
    // the graphs were carrying, so the tests come with it.

    #[test]
    fn a_full_bar_reaches_the_top_and_an_empty_one_marks_only_the_floor() {
        let (r, mut g) = (ramp(), TextGrid::new(8, 8, [0, 0, 0]));
        bars(&mut g, 0, 0, 8, 4, &[0.0, 1.0], &r, &pal());
        assert_eq!(g.char_at(4, 0), full(&r), "1.0 fills to the top row");
        assert_eq!(g.char_at(0, 0), '·', "0.0 leaves the top empty");
        assert_ne!(g.char_at(0, 3), '·', "0.0 still marks the floor -- it is a reading");
    }

    #[test]
    fn a_partial_row_uses_only_four_glyphs() {
        // Sixteen ramp levels are monotonic in ink and NOT in shape, so at
        // this size a finely-quantised row reads as text rather than as a
        // level. Nearby values must land on the same glyph.
        let r = ramp();
        let mut seen = std::collections::BTreeSet::new();
        for i in 0..=100 {
            let mut g = TextGrid::new(2, 2, [0, 0, 0]);
            bars(&mut g, 0, 0, 1, 1, &[i as f32 / 100.0], &r, &pal());
            seen.insert(g.char_at(0, 0));
        }
        assert!(seen.len() <= 4, "one row took {} distinct glyphs: {seen:?}", seen.len());
    }

    #[test]
    fn every_value_gets_its_own_bar_and_they_do_not_overlap() {
        // Eight cores in twenty-six columns: each bar must land in its own
        // slot, or the panel draws seven cores and a lie.
        let (r, mut g) = (ramp(), TextGrid::new(30, 4, [0, 0, 0]));
        let vals = [1.0f32, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0];
        bars(&mut g, 0, 0, 26, 2, &vals, &r, &pal());
        let top: String = (0..26).map(|x| g.char_at(x, 0)).collect();
        let filled = top.chars().filter(|c| *c == full(&r)).count();
        assert!(filled >= 4 && filled <= 12, "expected four bars' worth of ink, got {filled}");
        assert!(top.contains('·'), "the empty cores must leave gaps");
    }

    #[test]
    fn bars_with_nothing_to_draw_do_not_panic() {
        let (r, mut g) = (ramp(), TextGrid::new(4, 4, [0, 0, 0]));
        bars(&mut g, 0, 0, 0, 2, &[0.5], &r, &pal());
        bars(&mut g, 0, 0, 4, 0, &[0.5], &r, &pal());
        bars(&mut g, 0, 0, 4, 2, &[], &r, &pal());
        bars(&mut g, 0, 0, 4, 2, &[0.5], &[], &pal());
        assert_eq!((0..4).map(|x| g.char_at(x, 0)).collect::<String>(), "    ");
    }

    #[test]
    fn a_missing_meter_ramp_uses_a_safe_fallback() {
        let mut g = TextGrid::new(4,1,[0,0,0]);
        meter(&mut g,0,0,4,0.5,&[],&pal());
        assert_eq!(g.char_at(0,0),'@');
    }

    #[test]
    fn a_bar_value_outside_zero_to_one_is_clamped_into_the_field() {
        let (r, mut g) = (ramp(), TextGrid::new(8, 8, [0, 0, 0]));
        g.text(0, 0, "XXXX", [9, 9, 9]);
        bars(&mut g, 0, 1, 4, 2, &[-3.0, 4.0], &r, &pal());
        assert_eq!((0..4).map(|x| g.char_at(x, 0)).collect::<String>(), "XXXX",
                   "the row above is untouched");
    }
}
