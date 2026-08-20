use syntect::highlighting::{Color, FontStyle, ScopeSelectors, StyleModifier, Theme, ThemeItem, ThemeSettings};

#[derive(Clone, Debug)]
pub struct Palette {
    pub bg: Color,
    pub fg: Color,
    pub accent: Color,
    pub surface: Color,
}

impl Default for Palette {
    fn default() -> Self {
        Self {
            bg: rgb(26, 27, 38),
            fg: rgb(192, 202, 245),
            accent: rgb(122, 162, 247),
            surface: rgb(36, 40, 59),
        }
    }
}

pub fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color { r, g, b, a: 255 }
}

pub fn parse_hex(s: &str) -> Option<Color> {
    let t = s.trim();
    let h = t.strip_prefix('#').unwrap_or(t);
    let h = if h.len() == 8 { &h[2..] } else { h };
    if h.len() == 3 {
        let r = u8::from_str_radix(&h[0..1].repeat(2), 16).ok()?;
        let g = u8::from_str_radix(&h[1..2].repeat(2), 16).ok()?;
        let b = u8::from_str_radix(&h[2..3].repeat(2), 16).ok()?;
        return Some(rgb(r, g, b));
    }
    if h.len() == 6 {
        let r = u8::from_str_radix(&h[0..2], 16).ok()?;
        let g = u8::from_str_radix(&h[2..4], 16).ok()?;
        let b = u8::from_str_radix(&h[4..6], 16).ok()?;
        return Some(rgb(r, g, b));
    }
    None
}

fn mix(a: Color, b: Color, t: f32) -> Color {
    let t = t.clamp(0.0, 1.0);
    rgb(
        (a.r as f32 + (b.r as f32 - a.r as f32) * t) as u8,
        (a.g as f32 + (b.g as f32 - a.g as f32) * t) as u8,
        (a.b as f32 + (b.b as f32 - a.b as f32) * t) as u8,
    )
}

fn item(sel: &str, fg: Color, bold: bool) -> ThemeItem {
    ThemeItem {
        scope: sel.parse::<ScopeSelectors>().unwrap_or_else(|_| {
            "text"
                .parse::<ScopeSelectors>()
                .unwrap_or_else(|_| ScopeSelectors { selectors: vec![] })
        }),
        style: StyleModifier {
            foreground: Some(fg),
            background: None,
            font_style: if bold { Some(FontStyle::BOLD) } else { None },
        },
    }
}

pub fn syntect_theme(p: &Palette) -> Theme {
    let comment = mix(p.fg, p.bg, 0.55);
    let string = mix(p.accent, rgb(232, 176, 96), 0.45);
    let number = mix(p.accent, rgb(140, 210, 180), 0.35);
    let func = mix(p.fg, p.accent, 0.28);
    let ty = mix(p.accent, rgb(180, 140, 230), 0.4);
    Theme {
        name: Some("omarchy-quicklook".into()),
        author: Some("quicklook".into()),
        settings: ThemeSettings {
            foreground: Some(p.fg),
            background: Some(p.bg),
            caret: Some(p.accent),
            line_highlight: Some(p.surface),
            selection: Some(mix(p.accent, p.bg, 0.65)),
            ..ThemeSettings::default()
        },
        scopes: vec![
            item("comment, comment.line, comment.block", comment, false),
            item("keyword, keyword.control, keyword.operator.word, storage, storage.type, storage.modifier", p.accent, true),
            item("string, string.quoted, string.quoted.double, string.quoted.single", string, false),
            item("constant.numeric, constant.language, constant.character", number, false),
            item("entity.name.function, support.function, variable.function", func, false),
            item("entity.name.type, entity.name.class, support.type, support.class", ty, false),
            item("variable, variable.other, variable.parameter", p.fg, false),
            item("punctuation, meta.brace", mix(p.fg, p.bg, 0.25), false),
        ],
    }
}

pub fn apply_in(p: &mut Palette, incoming: &crate::protocol::PaletteIn) {
    if let Some(s) = incoming.bg.as_deref().and_then(parse_hex) {
        p.bg = s;
    }
    if let Some(s) = incoming.fg.as_deref().and_then(parse_hex) {
        p.fg = s;
    }
    if let Some(s) = incoming.accent.as_deref().and_then(parse_hex) {
        p.accent = s;
    }
    if let Some(s) = incoming.surface.as_deref().and_then(parse_hex) {
        p.surface = s;
    } else {
        p.surface = mix(p.bg, p.fg, 0.08);
    }
}

pub fn hex_of(c: Color) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hash_and_argb() {
        assert_eq!(parse_hex("#7aa2f7").unwrap().r, 0x7a);
        assert_eq!(parse_hex("#ff1a1b26").unwrap().r, 0x1a);
        assert_eq!(parse_hex("#abc").unwrap().b, 0xcc);
    }

    #[test]
    fn theme_has_keyword_scope() {
        let t = syntect_theme(&Palette::default());
        assert!(!t.scopes.is_empty());
        assert_eq!(t.name.as_deref(), Some("omarchy-quicklook"));
    }
}
