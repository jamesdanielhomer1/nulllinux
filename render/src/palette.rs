//! The palette, and the semantic roles sampled from it (NULL.md §4.6).

use std::collections::HashMap;
use std::fs;

/// A role is a NAME for a meaning, never a colour literal at the call site.
/// Nobody chooses a hex value (§1.1); adding a colour means finding it in the
/// render first (I6).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Void, Background, Surface, Line,
    Dim, Error, Warning, Neutral, Accent, Highlight,
}

impl Role {
    pub fn key(self) -> &'static str {
        match self {
            Role::Void => "void", Role::Background => "background",
            Role::Surface => "surface", Role::Line => "line",
            Role::Dim => "dim", Role::Error => "error",
            Role::Warning => "warning", Role::Neutral => "neutral",
            Role::Accent => "accent", Role::Highlight => "highlight",
        }
    }
}

pub struct Palette {
    roles: HashMap<String, [u8; 3]>,
    /// The 256-entry locus table from `palette.bin`, when it is beside the
    /// json. Absent is not an error: the roles alone are enough to draw with.
    entries: Option<Vec<[u8; 3]>>,
}

fn parse_hex(s: &str) -> Option<[u8; 3]> {
    let s = s.trim().trim_start_matches('#');
    if s.len() != 6 || !s.bytes().all(|b| b.is_ascii_hexdigit()) { return None }
    Some([u8::from_str_radix(&s[0..2], 16).ok()?,
          u8::from_str_radix(&s[2..4], 16).ok()?,
          u8::from_str_radix(&s[4..6], 16).ok()?])
}

#[cfg(test)]
mod hex_tests {
    use super::parse_hex;
    #[test]
    fn invalid_unicode_hex_returns_none() {
        assert_eq!(parse_hex("#aéabc"), None);
        assert_eq!(parse_hex("#abcdef"), Some([171,205,239]));
    }
}

impl Palette {
    /// Read the roles out of the generated palette metadata.
    ///
    /// Parsed from the file the bake produced rather than duplicated here: a
    /// colour written down in two places is a colour that will eventually
    /// disagree with itself.
    pub fn load(path: &str) -> Result<Self, String> {
        let text = fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
        let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let obj = v.get("roles").and_then(|r| r.as_object())
            .ok_or_else(|| format!("{path}: no roles"))?;
        let mut roles = HashMap::new();
        for (k, val) in obj {
            if let Some(h) = val.get("hex").and_then(|h| h.as_str()) {
                if let Some(rgb) = parse_hex(h) { roles.insert(k.clone(), rgb); }
            }
        }
        for r in ["void","background","surface","line","dim","error",
                  "warning","neutral","accent","highlight"] {
            if !roles.contains_key(r) {
                return Err(format!("{path}: role {r:?} missing"));
            }
        }
        // The binary table lives beside the json and is read from there
        // rather than being passed in, because the two are one artefact of one
        // bake and a caller that could pass mismatched halves eventually will.
        let entries = std::path::Path::new(path).parent()
            .map(|d| d.join("palette.bin"))
            .and_then(|p| fs::read(p).ok())
            .filter(|b| b.len() == 768)
            .map(|b| b.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect());
        Ok(Palette { roles, entries })
    }

    pub fn get(&self, r: Role) -> [u8; 3] { self.roles[r.key()] }

    /// The sixteen ANSI colours, taken from THIS palette's own locus.
    ///
    /// A hosted program that asks for "red" gets the coolest point on the
    /// Planckian curve; one that asks for "blue" gets the hottest. The
    /// terminal's own comment has claimed since it was written that "the
    /// surface remaps them", and nothing ever did -- so every 16-colour
    /// program hosted in the column drew in stock VGA blue and magenta
    /// against a palette sampled from a black hole.
    ///
    /// The mapping is by SPECTRAL ORDER, not by name. Red, yellow, green,
    /// cyan, blue, magenta is the order those hues run in the spectrum, and
    /// cool-to-hot is the order the locus runs in, so a program's own ordering
    /// survives the substitution even though the hues do not. Bright variants
    /// are the same temperature at a higher value, which is what "bright"
    /// means here and roughly what it meant on the hardware this convention
    /// comes from.
    ///
    /// What is LOST is worth stating: a program using green for good and red
    /// for bad keeps the contrast and loses the meaning, because there is no
    /// green anywhere on a Planckian locus. That is the trade this whole
    /// system makes everywhere else, and it is not free here either.
    pub fn ansi16(&self) -> [[u8; 3]; 16] {
        let e = match &self.entries {
            Some(v) if v.len() == 256 => v,
            // Without the table, fall back to roles. Fewer distinct colours,
            // but still this palette rather than someone else's.
            _ => {
                let (d, w, n, a, h) = (self.get(Role::Dim), self.get(Role::Warning),
                    self.get(Role::Neutral), self.get(Role::Accent), self.get(Role::Highlight));
                let (v, l) = (self.get(Role::Void), self.get(Role::Line));
                return [v, d, n, w, a, h, a, n, l, d, n, w, a, h, h, n];
            }
        };
        // index = temperature_index * 8 + value_index (32 x 8), per the
        // palette's own `layout` field. Named here rather than recomputed.
        let at = |t: usize, v: usize| e[t * 8 + v];
        // Six temperatures spanning the locus, in spectral order.
        const HUE_T: [usize; 6] = [0, 6, 12, 20, 25, 31];   // r  y  g  c  b  m
        const NORMAL_V: usize = 4;
        const BRIGHT_V: usize = 7;
        let hue = |i: usize, v: usize| at(HUE_T[i], v);
        [
            self.get(Role::Void),          // 0  black
            hue(0, NORMAL_V),              // 1  red      coolest
            hue(2, NORMAL_V),              // 2  green
            hue(1, NORMAL_V),              // 3  yellow
            hue(4, NORMAL_V),              // 4  blue
            hue(5, NORMAL_V),              // 5  magenta  hottest
            hue(3, NORMAL_V),              // 6  cyan
            self.get(Role::Neutral),       // 7  white
            self.get(Role::Line),          // 8  bright black -- the rule colour
            hue(0, BRIGHT_V),              // 9  bright red
            hue(2, BRIGHT_V),              // 10 bright green
            hue(1, BRIGHT_V),              // 11 bright yellow
            hue(4, BRIGHT_V),              // 12 bright blue
            hue(5, BRIGHT_V),              // 13 bright magenta
            hue(3, BRIGHT_V),              // 14 bright cyan
            self.get(Role::Highlight),     // 15 bright white
        ]
    }

    /// Every role the same colour. Test-only, and deliberately so: it exists
    /// for tests about GEOMETRY, where a real palette would only mean that a
    /// failure could be either a layout bug or a missing role.
    #[cfg(test)]
    pub fn uniform(rgb: [u8; 3]) -> Self {
        let mut roles = HashMap::new();
        for r in ["void","background","surface","line","dim","error",
                  "warning","neutral","accent","highlight"] {
            roles.insert(r.to_string(), rgb);
        }
        Palette { roles, entries: None }
    }

    /// Map a 0..1 reading onto the temperature sequence (§7.2).
    ///
    /// Every value maps onto the same Planckian sequence the hero is coloured
    /// by: cool outer disk to hot inner. An idle machine glows dim and a loaded
    /// one goes blue-white. Nothing is coloured because "network is blue".
    pub fn by_level(&self, x: f32) -> [u8; 3] {
        let x = x.clamp(0.0, 1.0);
        let seq = [Role::Dim, Role::Warning, Role::Neutral, Role::Accent, Role::Highlight];
        let i = ((x * (seq.len() - 1) as f32).round() as usize).min(seq.len() - 1);
        self.get(seq[i])
    }
}
