use crate::cache::PreviewCache;
use crate::kind::{ext_of, is_animated, kind_of, pass_through_image, Kind};
use crate::limits::{run_limited, which, with_timeout};
use crate::protocol::{DirEnt, Preview};
use crate::theme::Palette;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;
use syntect::easy::HighlightLines;
use syntect::highlighting::{Style, Theme};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

const CODE_CAP: usize = 200 * 1024;
const CSV_ROWS: usize = 500;
const HEX_BYTES: usize = 256;
const MEGAPIXELS: u64 = 20_000_000;

fn syntaxes() -> &'static SyntaxSet {
    static SET: OnceLock<SyntaxSet> = OnceLock::new();
    SET.get_or_init(SyntaxSet::load_defaults_newlines)
}

pub fn render(
    path: &Path,
    page: u32,
    theme: &Theme,
    _palette: &Palette,
    cache: &PreviewCache,
    ffmpeg: bool,
    poppler: bool,
) -> Preview {
    let page = page.max(1);
    let meta = fs::metadata(path).ok();
    let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
    let kind = kind_of(path, is_dir);
    let result = with_timeout(2000, {
        let path = path.to_path_buf();
        let theme = theme.clone();
        let cache_dir = cache.dir.clone();
        let budget = cache.budget;
        move || {
            let cache = PreviewCache::new(cache_dir, budget);
            match kind {
                Kind::Dir => preview_dir(&path),
                Kind::Image => preview_image(&path, &cache),
                Kind::Code => preview_code(&path, &theme),
                Kind::Csv => preview_csv(&path),
                Kind::Pdf => preview_pdf(&path, page, &cache, poppler),
                Kind::Video => preview_video(&path, &cache, ffmpeg),
                Kind::Hex => preview_hex(&path),
            }
        }
    });
    match result {
        Ok(p) => p,
        Err(e) => {
            let mut p = preview_hex(path);
            p.label = Some(e);
            p
        }
    }
}

pub fn preview_image(path: &Path, cache: &PreviewCache) -> Preview {
    if pass_through_image(path) {
        return Preview {
            kind: "image".into(),
            path: Some(path.to_string_lossy().into()),
            animated: Some(is_animated(path)),
            ..Preview::default()
        };
    }
    let meta = fs::metadata(path).ok();
    let mtime = meta
        .as_ref()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis().to_string())
        .unwrap_or_default();
    let reader = match image::ImageReader::open(path) {
        Ok(r) => r,
        Err(_) => {
            return Preview {
                kind: "image".into(),
                path: Some(path.to_string_lossy().into()),
                ..Preview::default()
            }
        }
    };
    let reader = match reader.with_guessed_format() {
        Ok(r) => r,
        Err(_) => {
            return Preview {
                kind: "image".into(),
                path: Some(path.to_string_lossy().into()),
                ..Preview::default()
            }
        }
    };
    let img = match reader.decode() {
        Ok(i) => i,
        Err(_) => {
            return Preview {
                kind: "image".into(),
                path: Some(path.to_string_lossy().into()),
                ..Preview::default()
            }
        }
    };
    let w = img.width();
    let h = img.height();
    let pixels = w as u64 * h as u64;
    if pixels <= MEGAPIXELS {
        return Preview {
            kind: "image".into(),
            path: Some(path.to_string_lossy().into()),
            width: Some(w),
            height: Some(h),
            animated: Some(false),
            ..Preview::default()
        };
    }
    let scale = (MEGAPIXELS as f64 / pixels as f64).sqrt();
    let nw = ((w as f64) * scale).max(1.0) as u32;
    let nh = ((h as f64) * scale).max(1.0) as u32;
    let resized = img.resize(nw, nh, image::imageops::FilterType::Triangle);
    let dest = cache.path_for(&[&path.to_string_lossy(), &mtime, "img"], "png");
    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if resized.save(&dest).is_ok() {
        cache.gc();
        Preview {
            kind: "image".into(),
            path: Some(dest.to_string_lossy().into()),
            width: Some(nw),
            height: Some(nh),
            label: Some("downsampled".into()),
            ..Preview::default()
        }
    } else {
        Preview {
            kind: "image".into(),
            path: Some(path.to_string_lossy().into()),
            width: Some(w),
            height: Some(h),
            ..Preview::default()
        }
    }
}

pub fn preview_code(path: &Path, theme: &Theme) -> Preview {
    let bytes = match read_capped(path, CODE_CAP + 1) {
        Ok(b) => b,
        Err(_) => return preview_hex(path),
    };
    let large = bytes.len() > CODE_CAP;
    let slice = if large { &bytes[..CODE_CAP] } else { &bytes };
    let text = String::from_utf8_lossy(slice);
    if looks_binary(slice) {
        return preview_hex(path);
    }
    let ext = ext_of(path);
    let ps = syntaxes();
    let syntax = ps
        .find_syntax_by_extension(&ext)
        .or_else(|| ps.find_syntax_by_name("Plain Text"))
        .unwrap_or_else(|| ps.find_syntax_plain_text());
    let mut h = HighlightLines::new(syntax, theme);
    let mut html = String::from("<pre>");
    for line in LinesWithEndings::from(&text) {
        let ranges = h.highlight_line(line, ps).unwrap_or_default();
        for (style, chunk) in ranges {
            html.push_str(&font_span(style, chunk));
        }
    }
    html.push_str("</pre>");
    Preview {
        kind: "code".into(),
        html: Some(html),
        lang: Some(if syntax.name == "Plain Text" {
            "text".into()
        } else {
            syntax.name.to_ascii_lowercase()
        }),
        capped: Some(large),
        large: Some(large),
        label: if large { Some("large file".into()) } else { None },
        path: Some(path.to_string_lossy().into()),
        ..Preview::default()
    }
}

pub fn highlight_source(src: &str, ext: &str, theme: &Theme) -> String {
    let ps = syntaxes();
    let syntax = ps
        .find_syntax_by_extension(ext)
        .unwrap_or_else(|| ps.find_syntax_plain_text());
    let mut h = HighlightLines::new(syntax, theme);
    let mut html = String::from("<pre>");
    for line in LinesWithEndings::from(src) {
        let ranges = h.highlight_line(line, ps).unwrap_or_default();
        for (style, chunk) in ranges {
            html.push_str(&font_span(style, chunk));
        }
    }
    html.push_str("</pre>");
    html
}

fn font_span(style: Style, text: &str) -> String {
    let c = style.foreground;
    format!(
        "<font color=\"#{:02x}{:02x}{:02x}\">{}</font>",
        c.r,
        c.g,
        c.b,
        escape_html(text)
    )
}

fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
    out
}

pub fn preview_csv(path: &Path) -> Preview {
    let data = match fs::read(path) {
        Ok(d) => d,
        Err(_) => return preview_hex(path),
    };
    preview_csv_bytes(&data)
}

pub fn preview_csv_bytes(data: &[u8]) -> Preview {
    let delim = sniff_delim(data);
    let mut rdr = csv::ReaderBuilder::new()
        .delimiter(delim)
        .has_headers(false)
        .flexible(true)
        .from_reader(data);
    let mut rows: Vec<Vec<String>> = Vec::new();
    for rec in rdr.records() {
        match rec {
            Ok(r) => rows.push(r.iter().map(|s| s.to_string()).collect()),
            Err(_) => continue,
        }
        if rows.len() > CSV_ROWS {
            break;
        }
    }
    if rows.is_empty() {
        return Preview {
            kind: "hex".into(),
            hex: Some(hex_dump(&data[..data.len().min(HEX_BYTES)])),
            magic: Some("empty table".into()),
            ..Preview::default()
        };
    }
    let headers = rows.remove(0);
    let truncated = rows.len() >= CSV_ROWS;
    Preview {
        kind: "csv".into(),
        headers: Some(headers),
        rows: Some(rows),
        truncated: Some(truncated),
        ..Preview::default()
    }
}

fn sniff_delim(data: &[u8]) -> u8 {
    let line = data.split(|b| *b == b'\n').next().unwrap_or(data);
    let comma = line.iter().filter(|b| **b == b',').count();
    let tab = line.iter().filter(|b| **b == b'\t').count();
    let semi = line.iter().filter(|b| **b == b';').count();
    let pipe = line.iter().filter(|b| **b == b'|').count();
    let mut best = (comma, b',');
    if tab > best.0 {
        best = (tab, b'\t');
    }
    if semi > best.0 {
        best = (semi, b';');
    }
    if pipe > best.0 {
        best = (pipe, b'|');
    }
    best.1
}

pub fn preview_pdf(path: &Path, page: u32, cache: &PreviewCache, poppler: bool) -> Preview {
    let page_count = pdf_page_count(path).max(1);
    let page = page.clamp(1, page_count);
    if !poppler {
        return Preview {
            kind: "pdf".into(),
            need_poppler: Some(true),
            page: Some(page),
            page_count: Some(page_count),
            magic: Some("PDF document".into()),
            label: Some("install poppler for PDF previews".into()),
            path: Some(path.to_string_lossy().into()),
            ..Preview::default()
        };
    }
    let mtime = fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis().to_string())
        .unwrap_or_default();
    let dest = cache.path_for(
        &[&path.to_string_lossy(), &mtime, &page.to_string(), "pdf"],
        "png",
    );
    if dest.is_file() {
        return Preview {
            kind: "pdf".into(),
            path: Some(dest.to_string_lossy().into()),
            page: Some(page),
            page_count: Some(page_count),
            need_poppler: Some(false),
            ..Preview::default()
        };
    }
    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let prefix = dest.with_extension("");
    let bin = which("pdftoppm").unwrap_or_else(|| Path::new("pdftoppm").to_path_buf());
    let mut cmd = Command::new(bin);
    cmd.args([
        "-f",
        &page.to_string(),
        "-l",
        &page.to_string(),
        "-png",
        "-r",
        "140",
        "-singlefile",
        &path.to_string_lossy(),
        &prefix.to_string_lossy(),
    ]);
    match run_limited(cmd, Duration::from_secs(8), 512 * 1024 * 1024, 8) {
        Ok(out) if out.status.success() && dest.is_file() => {
            cache.gc();
            Preview {
                kind: "pdf".into(),
                path: Some(dest.to_string_lossy().into()),
                page: Some(page),
                page_count: Some(page_count),
                need_poppler: Some(false),
                ..Preview::default()
            }
        }
        Ok(_) | Err(_) => Preview {
            kind: "pdf".into(),
            need_poppler: Some(false),
            page: Some(page),
            page_count: Some(page_count),
            label: Some("couldn't render this page".into()),
            magic: Some("PDF document".into()),
            path: Some(path.to_string_lossy().into()),
            ..Preview::default()
        },
    }
}

pub fn pdf_page_count(path: &Path) -> u32 {
    if let Some(info) = which("pdfinfo") {
        if let Ok(out) = Command::new(info).arg(path).output() {
            let text = String::from_utf8_lossy(&out.stdout);
            for line in text.lines() {
                if let Some(rest) = line.strip_prefix("Pages:") {
                    if let Ok(n) = rest.trim().parse::<u32>() {
                        return n.max(1);
                    }
                }
            }
        }
    }
    let bytes = fs::read(path).unwrap_or_default();
    let head = &bytes[..bytes.len().min(256 * 1024)];
    let s = String::from_utf8_lossy(head);
    let mut best = 1u32;
    let mut idx = 0;
    while let Some(at) = s[idx..].find("/Count") {
        let rest = s[idx + at + 6..].trim_start();
        let n: u32 = rest
            .split(|c: char| !c.is_ascii_digit())
            .next()
            .and_then(|x| x.parse().ok())
            .unwrap_or(0);
        if n > best && n < 10_000 {
            best = n;
        }
        idx += at + 6;
        if idx >= s.len() {
            break;
        }
    }
    best
}

pub fn preview_dir(path: &Path) -> Preview {
    let mut entries = Vec::new();
    let mut total = 0u64;
    if let Ok(rd) = fs::read_dir(path) {
        let mut raw: Vec<_> = rd.flatten().collect();
        raw.sort_by_key(|e| e.file_name());
        for ent in raw.iter().take(200) {
            let p = ent.path();
            let meta = ent.metadata().ok();
            let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
            let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
            if !is_dir {
                total += size;
            }
            entries.push(DirEnt {
                name: ent.file_name().to_string_lossy().into(),
                kind: kind_of(&p, is_dir).as_str().into(),
                size,
            });
        }
    }
    let walked = dir_total_size(path, 4000);
    Preview {
        kind: "dir".into(),
        entries: Some(entries),
        total_size: Some(if walked.0 > total { walked.0 } else { total }),
        truncated: Some(walked.1),
        path: Some(path.to_string_lossy().into()),
        ..Preview::default()
    }
}

fn dir_total_size(path: &Path, cap: usize) -> (u64, bool) {
    let mut n = 0u64;
    let mut count = 0usize;
    for ent in walkdir::WalkDir::new(path).follow_links(false).into_iter().flatten() {
        if ent.file_type().is_file() {
            n += ent.metadata().map(|m| m.len()).unwrap_or(0);
            count += 1;
            if count >= cap {
                return (n, true);
            }
        }
    }
    (n, false)
}

pub fn preview_hex(path: &Path) -> Preview {
    let mut buf = vec![0u8; HEX_BYTES];
    let n = fs::File::open(path)
        .and_then(|mut f| f.read(&mut buf))
        .unwrap_or(0);
    buf.truncate(n);
    Preview {
        kind: "hex".into(),
        hex: Some(hex_dump(&buf)),
        magic: Some(magic_of(path, &buf)),
        path: Some(path.to_string_lossy().into()),
        label: Some("can't render this — hex view".into()),
        ..Preview::default()
    }
}

pub fn hex_dump(bytes: &[u8]) -> String {
    let mut out = String::new();
    for (i, chunk) in bytes.chunks(16).enumerate() {
        out.push_str(&format!("{:08x}  ", i * 16));
        for (j, b) in chunk.iter().enumerate() {
            out.push_str(&format!("{:02x} ", b));
            if j == 7 {
                out.push(' ');
            }
        }
        for _ in chunk.len()..16 {
            out.push_str("   ");
        }
        if chunk.len() <= 8 {
            out.push(' ');
        }
        out.push(' ');
        for b in chunk {
            let c = if b.is_ascii_graphic() || *b == b' ' {
                *b as char
            } else {
                '.'
            };
            out.push(c);
        }
        out.push('\n');
    }
    if out.is_empty() {
        out.push_str("(empty)");
    }
    out
}

fn magic_of(path: &Path, head: &[u8]) -> String {
    if let Some(kind) = infer::get(head) {
        return format!("{} ({})", kind.mime_type(), kind.extension());
    }
    if let Ok(k) = infer::get_from_path(path) {
        if let Some(kind) = k {
            return format!("{} ({})", kind.mime_type(), kind.extension());
        }
    }
    if let Some(file) = which("file") {
        if let Ok(out) = Command::new(file).args(["-b", "--", &path.to_string_lossy()]).output() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    "data".into()
}

pub fn preview_video(path: &Path, cache: &PreviewCache, ffmpeg: bool) -> Preview {
    let meta = fs::metadata(path).ok();
    let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
    let magic = magic_of(path, &[]);
    if !ffmpeg {
        return Preview {
            kind: "video".into(),
            magic: Some(magic),
            label: Some("video metadata only".into()),
            path: Some(path.to_string_lossy().into()),
            total_size: Some(size),
            ..Preview::default()
        };
    }
    let mtime = meta
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis().to_string())
        .unwrap_or_default();
    let dest = cache.path_for(&[&path.to_string_lossy(), &mtime, "poster"], "png");
    if !dest.is_file() {
        if let Some(parent) = dest.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let bin = which("ffmpeg").unwrap_or_else(|| Path::new("ffmpeg").to_path_buf());
        let mut cmd = Command::new(bin);
        cmd.args([
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-ss",
            "1",
            "-i",
            &path.to_string_lossy(),
            "-frames:v",
            "1",
            "-y",
            &dest.to_string_lossy(),
        ]);
        let _ = run_limited(cmd, Duration::from_secs(6), 512 * 1024 * 1024, 6);
    }
    if dest.is_file() {
        cache.gc();
        Preview {
            kind: "image".into(),
            path: Some(dest.to_string_lossy().into()),
            label: Some("video poster".into()),
            magic: Some(magic),
            total_size: Some(size),
            ..Preview::default()
        }
    } else {
        Preview {
            kind: "video".into(),
            magic: Some(magic),
            label: Some("video metadata only".into()),
            path: Some(path.to_string_lossy().into()),
            total_size: Some(size),
            ..Preview::default()
        }
    }
}

fn read_capped(path: &Path, cap: usize) -> std::io::Result<Vec<u8>> {
    let mut f = fs::File::open(path)?;
    let mut buf = Vec::new();
    let mut tmp = [0u8; 8192];
    while buf.len() < cap {
        let n = f.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        let take = n.min(cap - buf.len());
        buf.extend_from_slice(&tmp[..take]);
    }
    Ok(buf)
}

fn looks_binary(bytes: &[u8]) -> bool {
    let n = bytes.len().min(800);
    if n == 0 {
        return false;
    }
    let zeros = bytes[..n].iter().filter(|b| **b == 0).count();
    zeros > n / 8
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme::{syntect_theme, Palette};
    use std::env;

    #[test]
    fn csv_sniffs_and_caps_rows() {
        let mut src = String::from("date,sku,qty\n");
        for i in 0..600 {
            src.push_str(&format!("2024-01-01,WIDGET-{i},1\n"));
        }
        let p = preview_csv_bytes(src.as_bytes());
        assert_eq!(p.kind, "csv");
        assert_eq!(p.headers.as_ref().unwrap()[0], "date");
        assert_eq!(p.rows.as_ref().unwrap().len(), 500);
        assert_eq!(p.truncated, Some(true));
    }

    #[test]
    fn csv_tab_delimiter() {
        let p = preview_csv_bytes(b"a\tb\nc\td\n");
        assert_eq!(p.headers.as_ref().unwrap().len(), 2);
        assert_eq!(p.rows.as_ref().unwrap()[0][1], "d");
    }

    #[test]
    fn csv_garbage_does_not_panic() {
        let p = preview_csv_bytes(b"\x00\x01\xff\xfe,,,,,,,\n\n\n");
        assert!(p.kind == "csv" || p.kind == "hex");
    }

    #[test]
    fn code_uses_font_color_not_css() {
        let theme = syntect_theme(&Palette::default());
        let html = highlight_source("fn main() { println!(\"hi\"); }\n", "rs", &theme);
        assert!(html.contains("<font color="));
        assert!(html.contains("fn"));
        assert!(!html.contains("class="));
        assert!(!html.contains("<span"));
        assert!(html.starts_with("<pre>"));
    }

    #[test]
    fn hex_dump_is_never_blank() {
        assert!(hex_dump(b"").contains("empty") || !hex_dump(b"").is_empty());
        let d = hex_dump(b"ABC");
        assert!(d.contains("41 42 43"));
        assert!(d.contains("ABC"));
    }

    #[test]
    fn image_garbage_falls_back() {
        let dir = env::temp_dir().join(format!("ql-img-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("junk.png");
        fs::write(&path, b"\x00\x01\xff not an image").unwrap();
        let cache = PreviewCache::new(dir.join("c"), 1024 * 1024);
        let p = preview_image(&path, &cache);
        assert_eq!(p.kind, "image");
        assert!(p.path.is_some());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn large_code_is_capped() {
        let dir = env::temp_dir().join(format!("ql-code-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("big.rs");
        let mut src = String::from("// large file\n");
        while src.len() < CODE_CAP + 50 {
            src.push_str("fn x() { let a = 1; }\n");
        }
        fs::write(&path, src).unwrap();
        let theme = syntect_theme(&Palette::default());
        let p = preview_code(&path, &theme);
        assert_eq!(p.large, Some(true));
        assert_eq!(p.label.as_deref(), Some("large file"));
        let _ = fs::remove_dir_all(&dir);
    }
}
