use crate::exclude;
use crate::frecency::{mtime_boost, Frecency};
use crate::kind::{kind_of, Kind};
use crate::limits::which;
use crate::protocol::Hit;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;

#[derive(Clone, Debug)]
pub struct IndexedFile {
    pub path: String,
    pub name: String,
    pub mtime: u64,
    pub size: u64,
    pub kind: String,
    pub is_dir: bool,
}

impl IndexedFile {
    pub fn from_path(path: &Path) -> Option<Self> {
        let meta = fs::symlink_metadata(path).ok()?;
        if meta.file_type().is_symlink() {
            return None;
        }
        let is_dir = meta.is_dir();
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        if name.is_empty() {
            return None;
        }
        Some(Self {
            path: path.to_string_lossy().to_string(),
            name,
            mtime: mtime_ms(&meta),
            size: if is_dir { 0 } else { meta.len() },
            kind: kind_of(path, is_dir).as_str().into(),
            is_dir,
        })
    }

    pub fn to_hit(&self, score: i64) -> Hit {
        Hit {
            path: self.path.clone(),
            name: self.name.clone(),
            kind: self.kind.clone(),
            score,
            mtime: self.mtime,
            size: self.size,
        }
    }
}

pub fn mtime_ms(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn rank(files: &[IndexedFile], query: &str, frecency: &Frecency, limit: usize) -> Vec<Hit> {
    if query.trim().is_empty() {
        return files.iter().take(limit).map(|f| f.to_hit(1)).collect();
    }
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
    let mut path_buf = Vec::new();
    let mut name_buf = Vec::new();
    let mut scored: Vec<(i64, &IndexedFile)> = Vec::new();
    for f in files {
        let mut score = 0i64;
        if let Some(s) = pattern.score(Utf32Str::new(&f.path, &mut path_buf), &mut matcher) {
            score = s as i64;
        }
        if let Some(s) = pattern.score(Utf32Str::new(&f.name, &mut name_buf), &mut matcher) {
            score = score.max(s as i64 + 40);
        }
        if score <= 0 {
            continue;
        }
        score += mtime_boost(f.mtime);
        score += frecency.boost(&f.path);
        scored.push((score, f));
    }
    scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.path.cmp(&b.1.path)));
    scored
        .into_iter()
        .take(limit)
        .map(|(s, f)| f.to_hit(s))
        .collect()
}

pub fn rank_owned(files: &[IndexedFile], query: &str, limit: usize) -> Vec<Hit> {
    if query.trim().is_empty() {
        return files.iter().take(limit).map(|f| f.to_hit(1)).collect();
    }
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
    let mut path_buf = Vec::new();
    let mut name_buf = Vec::new();
    let mut scored: Vec<(i64, &IndexedFile)> = Vec::new();
    for f in files {
        let mut score = 0i64;
        if let Some(s) = pattern.score(Utf32Str::new(&f.path, &mut path_buf), &mut matcher) {
            score = s as i64;
        }
        if let Some(s) = pattern.score(Utf32Str::new(&f.name, &mut name_buf), &mut matcher) {
            score = score.max(s as i64 + 40);
        }
        if score <= 0 {
            continue;
        }
        score += mtime_boost(f.mtime);
        scored.push((score, f));
    }
    scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.path.cmp(&b.1.path)));
    scored
        .into_iter()
        .take(limit)
        .map(|(s, f)| f.to_hit(s))
        .collect()
}

#[derive(Clone, Debug)]
pub struct WalkConfig {
    pub roots: Vec<PathBuf>,
    pub extra_exclude: Vec<String>,
    pub max_files: usize,
    pub max_depth: usize,
}

pub fn walk_index(cfg: &WalkConfig, mut on_batch: impl FnMut(&[IndexedFile], usize) -> bool) -> Vec<IndexedFile> {
    let mut out = Vec::new();
    let mut seen = 0usize;
    for root in &cfg.roots {
        if !root.exists() {
            continue;
        }
        let walker = WalkDir::new(root)
            .follow_links(false)
            .max_depth(cfg.max_depth)
            .into_iter();
        for ent in walker.filter_entry(|e| {
            if e.depth() == 0 {
                return true;
            }
            let p = e.path();
            if e.file_type().is_dir() {
                !exclude::should_skip_dir(p, &cfg.extra_exclude, root)
            } else {
                !exclude::should_skip_file(p)
            }
        }) {
            let ent = match ent {
                Ok(e) => e,
                Err(_) => continue,
            };
            if ent.depth() == 0 && ent.file_type().is_dir() {
                continue;
            }
            if let Some(rec) = IndexedFile::from_path(ent.path()) {
                out.push(rec);
                seen += 1;
                if seen % 400 == 0 && !on_batch(&out, seen) {
                    return out;
                }
                if out.len() >= cfg.max_files {
                    return out;
                }
            }
        }
    }
    let _ = on_batch(&out, seen);
    out
}

pub fn bounded_walk_query(cfg: &WalkConfig, query: &str, budget: usize) -> Vec<IndexedFile> {
    let mut limited = cfg.clone();
    limited.max_files = budget;
    limited.max_depth = limited.max_depth.min(8);
    let files = walk_index(&limited, |_, _| true);
    if query.is_empty() {
        return files.into_iter().take(40).collect();
    }
    let hits = rank_owned(&files, query, 40);
    hits.into_iter()
        .filter_map(|h| files.iter().find(|f| f.path == h.path).cloned())
        .collect()
}

pub fn plocate_available() -> bool {
    which("plocate").is_some() || which("locate").is_some()
}

pub fn plocate(query: &str, limit: usize, extra: &[String], roots: &[PathBuf]) -> Option<Vec<IndexedFile>> {
    if query.trim().is_empty() {
        return None;
    }
    let bin = which("plocate").or_else(|| which("locate"))?;
    let output = Command::new(bin)
        .args(["-il", &limit.to_string(), "--", query])
        .output()
        .ok()?;
    if output.stdout.is_empty() {
        return None;
    }
    let mut out = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let path = PathBuf::from(line);
        if !exclude::normalize_components(&path) {
            continue;
        }
        if exclude::path_is_secret(&path) {
            continue;
        }
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if exclude::skip_dir_name(name, extra) {
                continue;
            }
        }
        if !roots.is_empty() && !exclude::under_root(&path, roots) {
            continue;
        }
        if let Some(rec) = IndexedFile::from_path(&path) {
            out.push(rec);
        }
        if out.len() >= limit {
            break;
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

pub fn demo_files(samples: &Path) -> Vec<IndexedFile> {
    let names = [
        "invoice.pdf",
        "photo.png",
        "sales.csv",
        "themed.rs",
        "README.md",
    ];
    let mut out = Vec::new();
    for name in names {
        let p = samples.join(name);
        if let Some(rec) = IndexedFile::from_path(&p) {
            out.push(rec);
        } else {
            out.push(IndexedFile {
                path: p.to_string_lossy().to_string(),
                name: name.into(),
                mtime: 0,
                size: 0,
                kind: kind_of(&p, false).as_str().into(),
                is_dir: false,
            });
        }
    }
    out
}

pub fn merge_unique(head: Vec<IndexedFile>, tail: Vec<IndexedFile>) -> Vec<IndexedFile> {
    let mut out = head;
    for item in tail {
        if !out.iter().any(|e| e.path == item.path) {
            out.push(item);
        }
    }
    out
}

pub fn top_dirs(files: &[IndexedFile], cap: usize) -> Vec<PathBuf> {
    use std::collections::HashMap;
    let mut best: HashMap<String, u64> = HashMap::new();
    for f in files {
        let parent = Path::new(&f.path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| "/".into());
        let e = best.entry(parent).or_insert(0);
        if f.mtime > *e {
            *e = f.mtime;
        }
    }
    let mut dirs: Vec<(u64, String)> = best.into_iter().map(|(p, t)| (t, p)).collect();
    dirs.sort_by(|a, b| b.0.cmp(&a.0));
    dirs.into_iter()
        .take(cap)
        .map(|(_, p)| PathBuf::from(p))
        .collect()
}

pub fn rescan_dir(dir: &Path, extra: &[String]) -> Vec<IndexedFile> {
    let mut out = Vec::new();
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return out,
    };
    for ent in rd.flatten() {
        let p = ent.path();
        if p.is_dir() && exclude::should_skip_dir(&p, extra, dir) {
            continue;
        }
        if p.is_file() && exclude::should_skip_file(&p) {
            continue;
        }
        if let Some(rec) = IndexedFile::from_path(&p) {
            out.push(rec);
        }
    }
    out
}

pub fn kind_label(k: Kind) -> &'static str {
    k.as_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, name: &str, kind: &str) -> IndexedFile {
        IndexedFile {
            path: path.into(),
            name: name.into(),
            mtime: 0,
            size: 10,
            kind: kind.into(),
            is_dir: false,
        }
    }

    #[test]
    fn invoice_ranks_first_for_inv() {
        let files = vec![
            file("/home/x/notes.md", "notes.md", "code"),
            file("/home/x/Documents/invoice.pdf", "invoice.pdf", "pdf"),
            file("/home/x/Photos/invited.png", "invited.png", "image"),
            file("/home/x/code/inventory.rs", "inventory.rs", "code"),
        ];
        let hits = rank_owned(&files, "inv", 10);
        assert!(!hits.is_empty());
        assert_eq!(hits[0].name, "invoice.pdf");
    }

    #[test]
    fn empty_query_keeps_input_order() {
        let files = vec![
            file("/a/invoice.pdf", "invoice.pdf", "pdf"),
            file("/a/photo.png", "photo.png", "image"),
        ];
        let hits = rank_owned(&files, "", 10);
        assert_eq!(hits[0].name, "invoice.pdf");
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn no_match_is_empty() {
        let files = vec![file("/a/photo.png", "photo.png", "image")];
        let hits = rank_owned(&files, "zzzz-nope", 10);
        assert!(hits.is_empty());
    }
}
