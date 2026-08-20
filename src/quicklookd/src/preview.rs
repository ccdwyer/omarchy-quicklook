use crate::cache::PreviewCache;
use crate::kind::{ext_of, kind_of, Kind};
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
const CSV_CAP: usize = 1024 * 1024;
const PDF_HEAD: usize = 256 * 1024;
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
        let budget = cache.budget();
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
    let ext = ext_of(path);
    let dims = if ext == "svg" {
        svg_dims(path)
    } else {
        header_dims(path)
    };
    let Some((w, h)) = dims else {
        return image_unsafe(path, "unverifiable image");
    };
    if w == 0 || h == 0 {
        return image_unsafe(path, "unverifiable image");
    }
    let pixels = w as u64 * h as u64;
    if pixels > MEGAPIXELS {
        if let Some(p) = downsample_cached(path, cache, w, h) {
            return p;
        }
        return oversized_image(path, w, h);
    }
    if ext == "svg" || ext == "gif" {
        return Preview {
            kind: "image".into(),
            path: Some(path.to_string_lossy().into()),
            width: Some(w),
            height: Some(h),
            animated: Some(ext == "gif"),
            ..Preview::default()
        };
    }
    match decode_bounded(path) {
        Ok(_) => Preview {
            kind: "image".into(),
            path: Some(path.to_string_lossy().into()),
            width: Some(w),
            height: Some(h),
            animated: Some(false),
            ..Preview::default()
        },
        Err(_) => image_unsafe(path, "can't render this — hex view"),
    }
}

pub fn fit_megapixels(w: u32, h: u32, cap: u64) -> (u32, u32) {
    let pixels = (w as u64).saturating_mul(h as u64).max(1);
    if pixels <= cap {
        return (w.max(1), h.max(1));
    }
    let scale = (cap as f64 / pixels as f64).sqrt();
    let nw = ((w as f64) * scale).floor().max(1.0) as u32;
    let nh = ((h as f64) * scale).floor().max(1.0) as u32;
    (nw.max(1), nh.max(1))
}

fn downsample_cached(path: &Path, cache: &PreviewCache, w: u32, h: u32) -> Option<Preview> {
    let (nw, nh) = fit_megapixels(w, h, MEGAPIXELS);
    let mtime = fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis().to_string())
        .unwrap_or_default();
    let dest = cache.path_for(
        &[
            &path.to_string_lossy(),
            &mtime,
            "ds",
            &nw.to_string(),
            &nh.to_string(),
        ],
        "png",
    );
    if dest.is_file() && dest.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        return Some(downsampled_preview(&dest, nw, nh));
    }
    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if downsample_external(path, &dest, nw, nh) || downsample_self(path, &dest, nw, nh) {
        if dest.is_file() && dest.metadata().map(|m| m.len() > 0).unwrap_or(false) {
            cache.gc();
            return Some(downsampled_preview(&dest, nw, nh));
        }
    }
    None
}

fn downsampled_preview(dest: &Path, nw: u32, nh: u32) -> Preview {
    Preview {
        kind: "image".into(),
        path: Some(dest.to_string_lossy().into()),
        width: Some(nw),
        height: Some(nh),
        label: Some("downsampled".into()),
        animated: Some(false),
        ..Preview::default()
    }
}

fn downsample_external(src: &Path, dest: &Path, nw: u32, nh: u32) -> bool {
    let src_s = src.to_string_lossy().into_owned();
    let dest_s = dest.to_string_lossy().into_owned();
    let scale = format!("{nw}:{nh}");
    let geom = format!("{nw}x{nh}");
    let candidates: Vec<Command> = {
        let mut v = Vec::new();
        if let Some(bin) = which("ffmpeg") {
            let mut c = Command::new(bin);
            c.args([
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                &src_s,
                "-vf",
                &format!("scale={scale}"),
                "-frames:v",
                "1",
                "-y",
                &dest_s,
            ]);
            v.push(c);
        }
        if let Some(bin) = which("magick") {
            let mut c = Command::new(bin);
            c.args([&src_s, "-resize", &geom, &dest_s]);
            v.push(c);
        }
        if let Some(bin) = which("convert") {
            let mut c = Command::new(bin);
            c.args([&src_s, "-resize", &geom, &dest_s]);
            v.push(c);
        }
        v
    };
    for cmd in candidates {
        if dest.is_file() {
            let _ = fs::remove_file(dest);
        }
        if run_limited(cmd, Duration::from_secs(12), 512 * 1024 * 1024, 12).is_ok()
            && dest.is_file()
            && dest.metadata().map(|m| m.len() > 0).unwrap_or(false)
        {
            return true;
        }
    }
    false
}

fn downsample_self(src: &Path, dest: &Path, nw: u32, nh: u32) -> bool {
    if cfg!(test) {
        return false;
    }
    let exe = match std::env::current_exe() {
        Ok(e) => e,
        Err(_) => return false,
    };
    let name = exe.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if name != "quicklookd" {
        return false;
    }
    let mut cmd = Command::new(exe);
    cmd.args([
        "--downsample",
        &src.to_string_lossy(),
        &dest.to_string_lossy(),
        &nw.to_string(),
        &nh.to_string(),
    ]);
    run_limited(cmd, Duration::from_secs(12), 512 * 1024 * 1024, 12).is_ok()
        && dest.is_file()
        && dest.metadata().map(|m| m.len() > 0).unwrap_or(false)
}

pub fn downsample_cli(src: &Path, dest: &Path, nw: u32, nh: u32) -> i32 {
    let nw = nw.max(1);
    let nh = nh.max(1);
    let img = match decode_for_downsample(src) {
        Ok(i) => i,
        Err(_) => return 1,
    };
    let resized = img.resize(nw, nh, image::imageops::FilterType::Triangle);
    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if resized.save(dest).is_ok() {
        0
    } else {
        1
    }
}

fn decode_for_downsample(path: &Path) -> Result<image::DynamicImage, String> {
    let reader = image::ImageReader::open(path).map_err(|e| e.to_string())?;
    let mut reader = reader.with_guessed_format().map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(100_000);
    limits.max_image_height = Some(100_000);
    limits.max_alloc = Some(400 * 1024 * 1024);
    reader.limits(limits);
    reader.decode().map_err(|e| e.to_string())
}

fn header_dims(path: &Path) -> Option<(u32, u32)> {
    if let Some(d) = sniff_raster_dims(path) {
        return Some(d);
    }
    let reader = image::ImageReader::open(path).ok()?;
    let reader = reader.with_guessed_format().ok()?;
    reader.into_dimensions().ok()
}

fn sniff_raster_dims(path: &Path) -> Option<(u32, u32)> {
    let head = read_capped(path, 96 * 1024).ok()?;
    if head.len() >= 24 && head.starts_with(b"\x89PNG\r\n\x1a\n") {
        let w = u32::from_be_bytes(head[16..20].try_into().ok()?);
        let h = u32::from_be_bytes(head[20..24].try_into().ok()?);
        if w > 0 && h > 0 {
            return Some((w, h));
        }
    }
    if head.len() >= 10 && (head.starts_with(b"GIF87a") || head.starts_with(b"GIF89a")) {
        let w = u16::from_le_bytes(head[6..8].try_into().ok()?) as u32;
        let h = u16::from_le_bytes(head[8..10].try_into().ok()?) as u32;
        if w > 0 && h > 0 {
            return Some((w, h));
        }
    }
    None
}

fn decode_bounded(path: &Path) -> Result<image::DynamicImage, String> {
    let reader = image::ImageReader::open(path).map_err(|e| e.to_string())?;
    let mut reader = reader.with_guessed_format().map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(20_000);
    limits.max_image_height = Some(20_000);
    limits.max_alloc = Some(96 * 1024 * 1024);
    reader.limits(limits);
    reader.decode().map_err(|e| e.to_string())
}

fn image_unsafe(path: &Path, label: &str) -> Preview {
    let mut p = preview_hex(path);
    p.label = Some(label.into());
    p
}

fn oversized_image(path: &Path, w: u32, h: u32) -> Preview {
    let mut p = preview_hex(path);
    p.magic = Some(format!("image {w}x{h}"));
    p.label = Some("image exceeds 20 MP — hex view".into());
    p.width = Some(w);
    p.height = Some(h);
    p
}

fn svg_dims(path: &Path) -> Option<(u32, u32)> {
    let bytes = read_capped(path, 16 * 1024).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    if let Some((w, h)) = parse_svg_viewbox(&text) {
        if w > 0 && h > 0 {
            return Some((w, h));
        }
    }
    let w = parse_svg_len(&text, "width")?;
    let h = parse_svg_len(&text, "height")?;
    if w > 0 && h > 0 {
        Some((w, h))
    } else {
        None
    }
}

fn parse_svg_viewbox(s: &str) -> Option<(u32, u32)> {
    let lower = s.to_ascii_lowercase();
    let idx = lower.find("viewbox")?;
    let rest = s[idx + 7..].trim_start();
    let rest = rest.trim_start_matches(['=', '"', '\'', ' ', '\t']);
    let mut nums = rest.split(|c: char| c.is_whitespace() || c == ',' || c == '"' || c == '\'');
    let _x = nums.next()?;
    let _y = nums.next()?;
    let w = parse_svg_len_token(nums.next()?)?;
    let h = parse_svg_len_token(nums.next()?)?;
    Some((w, h))
}

fn parse_svg_len(s: &str, attr: &str) -> Option<u32> {
    let lower = s.to_ascii_lowercase();
    let key = format!("{attr}=");
    let idx = lower.find(&key)?;
    let rest = s[idx + key.len()..].trim_start();
    let rest = rest.trim_start_matches(['"', '\'']);
    let token = rest
        .split(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == '>' || c == '/')
        .next()?;
    parse_svg_len_token(token)
}

fn parse_svg_len_token(t: &str) -> Option<u32> {
    let t = t.trim();
    if t.ends_with('%') {
        return None;
    }
    let t = t.trim_end_matches(|c: char| c.is_ascii_alphabetic());
    let v: f64 = t.parse().ok()?;
    if !v.is_finite() || v <= 0.0 || v > 1_000_000.0 {
        return None;
    }
    Some(v.round() as u32)
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
    let data = match read_capped(path, CSV_CAP) {
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
        Ok(_) | Err(_) => {
            let head = read_capped(path, HEX_BYTES).unwrap_or_default();
            let hex = hex_dump(&head);
            Preview {
                kind: "pdf".into(),
                need_poppler: Some(false),
                render_error: Some(true),
                page: Some(page),
                page_count: Some(page_count),
                label: Some("couldn't render this page".into()),
                magic: Some("PDF document".into()),
                hex: Some(hex),
                path: None,
                ..Preview::default()
            }
        }
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
    let bytes = read_capped(path, PDF_HEAD).unwrap_or_default();
    let s = String::from_utf8_lossy(&bytes);
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
    fn pdf_failure_is_render_error_not_raw_pdf() {
        let dir = env::temp_dir().join(format!("ql-pdf-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("broken.pdf");
        fs::write(&path, b"%PDF-1.4 not really a pdf").unwrap();
        let cache = PreviewCache::new(dir.join("c"), 1024 * 1024);
        let p = preview_pdf(&path, 1, &cache, true);
        assert_eq!(p.kind, "pdf");
        assert_eq!(p.render_error, Some(true));
        assert!(p.path.is_none(), "must not hand the raw PDF to QML Image");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn image_garbage_falls_back() {
        let dir = env::temp_dir().join(format!("ql-img-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("junk.png");
        fs::write(&path, b"\x00\x01\xff not an image").unwrap();
        let cache = PreviewCache::new(dir.join("c"), 1024 * 1024);
        let p = preview_image(&path, &cache);
        assert_eq!(p.kind, "hex", "corrupt stills must not be handed to QML Image");
        assert_eq!(p.label.as_deref(), Some("unverifiable image"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn huge_header_does_not_hand_original_to_qml() {
        let dir = env::temp_dir().join(format!("ql-huge-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("huge.png");
        let mut raw = b"\x89PNG\r\n\x1a\n".to_vec();
        raw.extend_from_slice(&13u32.to_be_bytes());
        raw.extend_from_slice(b"IHDR");
        raw.extend_from_slice(&8000u32.to_be_bytes());
        raw.extend_from_slice(&8000u32.to_be_bytes());
        raw.extend_from_slice(&[8, 2, 0, 0, 0]);
        raw.extend_from_slice(&[0, 0, 0, 0]);
        raw.extend_from_slice(b"IEND");
        fs::write(&path, raw).unwrap();
        let cache = PreviewCache::new(dir.join("c"), 1024 * 1024);
        let p = preview_image(&path, &cache);
        assert_ne!(p.kind, "image");
        assert_eq!(p.kind, "hex");
        assert_eq!(p.width, Some(8000));
        assert_eq!(p.height, Some(8000));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn fit_megapixels_caps_product() {
        let (w, h) = fit_megapixels(8000, 8000, MEGAPIXELS);
        assert!((w as u64).saturating_mul(h as u64) <= MEGAPIXELS);
        assert!(w >= 1000 && h >= 1000);
        assert_eq!(fit_megapixels(100, 100, MEGAPIXELS), (100, 100));
    }

    #[test]
    fn downsample_cli_writes_png() {
        let dir = env::temp_dir().join(format!("ql-ds-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let src = dir.join("in.png");
        let dest = dir.join("out.png");
        let img = image::RgbImage::from_pixel(32, 32, image::Rgb([10, 20, 30]));
        img.save(&src).unwrap();
        assert_eq!(downsample_cli(&src, &dest, 8, 8), 0);
        assert!(dest.is_file());
        let out = image::ImageReader::open(&dest).unwrap().decode().unwrap();
        assert!(out.width() <= 8);
        assert!(out.height() <= 8);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn svg_without_dims_is_hex() {
        let dir = env::temp_dir().join(format!("ql-svg-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("bomb.svg");
        fs::write(&path, b"<svg xmlns='http://www.w3.org/2000/svg'><rect width='100%' height='100%'/></svg>").unwrap();
        let cache = PreviewCache::new(dir.join("c"), 1024 * 1024);
        let p = preview_image(&path, &cache);
        assert_eq!(p.kind, "hex");
        let safe = dir.join("ok.svg");
        fs::write(&safe, b"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 24'><rect width='32' height='24'/></svg>").unwrap();
        let ok = preview_image(&safe, &cache);
        assert_eq!(ok.kind, "image");
        assert_eq!(ok.width, Some(32));
        assert_eq!(ok.height, Some(24));
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
