pub mod cache;
pub mod exclude;
pub mod frecency;
pub mod kind;
pub mod limits;
pub mod open;
pub mod preview;
pub mod protocol;
pub mod search;
pub mod theme;

use crate::cache::PreviewCache;
use crate::frecency::Frecency;
use crate::limits::which;
use crate::protocol::{Request, Response, Status};
use crate::search::{IndexedFile, WalkConfig};
use crate::theme::{syntect_theme, Palette};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use syntect::highlighting::Theme;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub roots: Vec<PathBuf>,
    pub samples_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub state_dir: PathBuf,
    pub home: PathBuf,
    pub watch_cap: u32,
    pub cache_bytes: u64,
    pub max_files: usize,
    pub extra_exclude: Vec<String>,
}

impl AppConfig {
    pub fn from_env_and_args(args: &[String]) -> Self {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()));
        let cache_home = std::env::var("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join(".cache"));
        let state_home = std::env::var("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join(".local/state"));
        let plugin_dir = std::env::var("QUICKLOOK_PLUGIN_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."));
        let mut cfg = Self {
            roots: vec![home.clone()],
            samples_dir: plugin_dir.join("samples"),
            cache_dir: cache_home.join("quicklook"),
            state_dir: state_home.join("quicklook"),
            home,
            watch_cap: 2000,
            cache_bytes: 500 * 1024 * 1024,
            max_files: 500_000,
            extra_exclude: Vec::new(),
        };
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--plugin-dir" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.samples_dir = PathBuf::from(v).join("samples");
                        i += 1;
                    }
                }
                "--cache-dir" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.cache_dir = PathBuf::from(v);
                        i += 1;
                    }
                }
                "--state-dir" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.state_dir = PathBuf::from(v);
                        i += 1;
                    }
                }
                "--home" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.home = PathBuf::from(v);
                        i += 1;
                    }
                }
                "--watch-cap" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.watch_cap = v.parse().unwrap_or(cfg.watch_cap);
                        i += 1;
                    }
                }
                "--cache-mb" => {
                    if let Some(v) = args.get(i + 1) {
                        let mb: u64 = v.parse().unwrap_or(500);
                        cfg.cache_bytes = mb.max(16) * 1024 * 1024;
                        i += 1;
                    }
                }
                "--max-files" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.max_files = v.parse().unwrap_or(cfg.max_files);
                        i += 1;
                    }
                }
                "--root" => {
                    if let Some(v) = args.get(i + 1) {
                        let p = expand_home(v, &cfg.home);
                        if cfg.roots == [cfg.home.clone()] {
                            cfg.roots.clear();
                        }
                        cfg.roots.push(p);
                        i += 1;
                    }
                }
                _ => {}
            }
            i += 1;
        }
        if let Ok(dir) = std::env::var("QUICKLOOK_PLUGIN_DIR") {
            cfg.samples_dir = PathBuf::from(dir).join("samples");
        }
        cfg
    }
}

fn expand_home(s: &str, home: &std::path::Path) -> PathBuf {
    if s == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = s.strip_prefix("~/") {
        return home.join(rest);
    }
    PathBuf::from(s)
}

struct Inner {
    cfg: Mutex<AppConfig>,
    files: Mutex<Vec<IndexedFile>>,
    indexing: AtomicBool,
    progress_cents: AtomicU32,
    backend: Mutex<String>,
    watch_count: AtomicU32,
    theme: Mutex<Palette>,
    syn_theme: Mutex<Theme>,
    frecency: Mutex<Frecency>,
    cache: PreviewCache,
    poppler: bool,
    plocate: bool,
    ffmpeg: bool,
    latest_preview: AtomicU64,
    samples: Mutex<Vec<IndexedFile>>,
}

#[derive(Clone)]
pub struct Engine {
    inner: Arc<Inner>,
}

impl Engine {
    pub fn new(cfg: AppConfig) -> Self {
        let _ = std::fs::create_dir_all(&cfg.cache_dir);
        let _ = std::fs::create_dir_all(&cfg.state_dir);
        let db = cfg.state_dir.join("index.sqlite");
        let frecency = Frecency::open(&db).expect("open frecency db");
        let persisted = frecency.load_files();
        let cache = PreviewCache::new(cfg.cache_dir.clone(), cfg.cache_bytes);
        cache.gc();
        let samples = search::demo_files(&cfg.samples_dir);
        let palette = Palette::default();
        let syn = syntect_theme(&palette);
        let inner = Inner {
            cfg: Mutex::new(cfg),
            files: Mutex::new(if persisted.is_empty() {
                samples.clone()
            } else {
                search::merge_unique(samples.clone(), persisted)
            }),
            indexing: AtomicBool::new(false),
            progress_cents: AtomicU32::new(0),
            backend: Mutex::new("demo".into()),
            watch_count: AtomicU32::new(0),
            theme: Mutex::new(palette),
            syn_theme: Mutex::new(syn),
            frecency: Mutex::new(frecency),
            cache,
            poppler: which("pdftoppm").is_some(),
            plocate: search::plocate_available(),
            ffmpeg: which("ffmpeg").is_some(),
            latest_preview: AtomicU64::new(0),
            samples: Mutex::new(samples),
        };
        Self {
            inner: Arc::new(inner),
        }
    }

    pub fn warmup_async(&self) {
        if self.inner.indexing.swap(true, Ordering::SeqCst) {
            return;
        }
        let inner = self.inner.clone();
        thread::spawn(move || warmup_loop(inner));
    }

    pub fn handle_line(&self, line: &str) -> String {
        match protocol::parse(line) {
            Ok(req) => serde_json::to_string(&self.handle(req)).unwrap_or_else(|e| {
                format!(r#"{{"id":0,"kind":"error","error":"{}"}}"#, e)
            }),
            Err(e) => serde_json::to_string(&Response::error(0, e)).unwrap(),
        }
    }

    pub fn handle(&self, req: Request) -> Response {
        match req.command() {
            "query" => self.do_query(&req),
            "preview" | "prefetch" | "page" => self.do_preview(&req),
            "open" => self.do_open(&req, false),
            "reveal" => self.do_open(&req, true),
            "select" => self.do_select(&req),
            "status" | "capabilities" => self.do_status(&req),
            "theme" => self.do_theme(&req),
            "warmup" => {
                self.warmup_async();
                Response::ok(req.id)
            }
            "config" => self.do_config(&req),
            other => Response::error(req.id, format!("unknown cmd {other}")),
        }
    }

    fn do_config(&self, req: &Request) -> Response {
        {
            let mut cfg = self.inner.cfg.lock().unwrap();
            if let Some(roots) = &req.roots {
                let home = cfg.home.clone();
                cfg.roots = roots.iter().map(|r| expand_home(r, &home)).collect();
                if cfg.roots.is_empty() {
                    cfg.roots.push(home);
                }
            }
            if let Some(n) = req.watch_cap {
                cfg.watch_cap = n.max(16);
            }
            if let Some(n) = req.cache_mb {
                cfg.cache_bytes = (n.max(16) as u64) * 1024 * 1024;
            }
            if let Some(n) = req.max_files {
                cfg.max_files = n.max(1000) as usize;
            }
            if let Some(ex) = &req.extra_exclude {
                cfg.extra_exclude = ex.clone();
            }
        }
        self.warmup_async();
        self.do_status(req)
    }

    fn do_theme(&self, req: &Request) -> Response {
        if let Some(p) = &req.palette {
            let mut pal = self.inner.theme.lock().unwrap();
            theme::apply_in(&mut pal, p);
            let syn = syntect_theme(&pal);
            *self.inner.syn_theme.lock().unwrap() = syn;
        }
        Response::ok(req.id)
    }

    fn do_select(&self, req: &Request) -> Response {
        if let Some(path) = &req.path {
            let _ = self.inner.frecency.lock().unwrap().touch(path);
        }
        Response::ok(req.id)
    }

    fn do_open(&self, req: &Request, reveal: bool) -> Response {
        let path = match req.path.as_deref() {
            Some(p) => PathBuf::from(p),
            None => return Response::error(req.id, "missing path"),
        };
        if let Some(s) = req.path.as_deref() {
            let _ = self.inner.frecency.lock().unwrap().touch(s);
        }
        let r = if reveal {
            open::reveal_path(&path)
        } else {
            open::open_path(&path)
        };
        match r {
            Ok(()) => Response::ok(req.id),
            Err(e) => Response::error(req.id, e),
        }
    }

    fn do_status(&self, req: &Request) -> Response {
        let mut resp = Response::ok(req.id);
        resp.kind = "status".into();
        resp.status = Some(self.status_now());
        resp.indexing = Some(self.inner.indexing.load(Ordering::SeqCst));
        resp.progress = Some(self.progress());
        resp.backend = Some(self.inner.backend.lock().unwrap().clone());
        resp
    }

    fn progress(&self) -> f32 {
        self.inner.progress_cents.load(Ordering::SeqCst) as f32 / 10000.0
    }

    fn status_now(&self) -> Status {
        let cfg = self.inner.cfg.lock().unwrap();
        let files = self.inner.files.lock().unwrap().len() as u64;
        Status {
            indexing: self.inner.indexing.load(Ordering::SeqCst),
            progress: self.progress(),
            backend: self.inner.backend.lock().unwrap().clone(),
            files,
            watch_count: self.inner.watch_count.load(Ordering::SeqCst),
            watch_cap: cfg.watch_cap,
            roots: cfg.roots.iter().map(|p| p.to_string_lossy().into()).collect(),
            cache_bytes: self.inner.cache.bytes_used(),
            cache_budget: cfg.cache_bytes,
            poppler: self.inner.poppler,
            plocate: self.inner.plocate,
            ffmpeg: self.inner.ffmpeg,
            helper: "rust".into(),
            version: VERSION.into(),
        }
    }

    fn do_query(&self, req: &Request) -> Response {
        let q = req.q.clone().unwrap_or_default();
        let samples = self.inner.samples.lock().unwrap().clone();
        let indexed = self.inner.files.lock().unwrap().clone();
        let cfg = self.inner.cfg.lock().unwrap().clone();
        let frecency = self.inner.frecency.lock().unwrap();
        let (hits, backend) = if q.trim().is_empty() {
            let recent_paths = frecency.recent(12);
            let mut recent = Vec::new();
            for p in recent_paths {
                if let Some(f) = indexed.iter().find(|x| x.path == p).cloned() {
                    recent.push(f);
                } else if let Some(f) = search::IndexedFile::from_path(std::path::Path::new(&p)) {
                    recent.push(f);
                }
            }
            let merged = search::merge_unique(samples, recent);
            (search::rank(&merged, "", &frecency, 40), "demo".to_string())
        } else if !indexed.is_empty() && self.inner.progress_cents.load(Ordering::SeqCst) > 0 {
            let backend = if self.inner.indexing.load(Ordering::SeqCst) {
                "index-warming".to_string()
            } else {
                "index".to_string()
            };
            let pool = search::merge_unique(samples, indexed);
            (search::rank(&pool, &q, &frecency, 40), backend)
        } else if let Some(found) = search::plocate(&q, 80, &cfg.extra_exclude, &cfg.roots) {
            let pool = search::merge_unique(samples, found);
            (search::rank(&pool, &q, &frecency, 40), "plocate".to_string())
        } else {
            let walk_cfg = WalkConfig {
                roots: cfg.roots.clone(),
                extra_exclude: cfg.extra_exclude.clone(),
                max_files: 2500,
                max_depth: 8,
            };
            let walked = search::bounded_walk_query(&walk_cfg, &q, 2500);
            let pool = search::merge_unique(samples, walked);
            (search::rank(&pool, &q, &frecency, 40), "walk".to_string())
        };
        *self.inner.backend.lock().unwrap() = backend.clone();
        drop(frecency);
        Response {
            id: req.id,
            kind: "results".into(),
            results: Some(hits),
            preview: None,
            status: None,
            error: None,
            indexing: Some(self.inner.indexing.load(Ordering::SeqCst)),
            progress: Some(self.progress()),
            backend: Some(backend),
        }
    }

    fn do_preview(&self, req: &Request) -> Response {
        let path = match req.path.as_deref() {
            Some(p) => PathBuf::from(p),
            None => return Response::error(req.id, "missing path"),
        };
        self.inner.latest_preview.store(req.id, Ordering::SeqCst);
        let theme = self.inner.syn_theme.lock().unwrap().clone();
        let palette = self.inner.theme.lock().unwrap().clone();
        let page = req.page.unwrap_or(1);
        let preview = preview::render(
            &path,
            page,
            &theme,
            &palette,
            &self.inner.cache,
            self.inner.ffmpeg,
            self.inner.poppler,
        );
        if self.inner.latest_preview.load(Ordering::SeqCst) != req.id {
            return Response {
                id: req.id,
                kind: "preview".into(),
                results: None,
                preview: None,
                status: None,
                error: Some("stale".into()),
                indexing: None,
                progress: None,
                backend: None,
            };
        }
        Response {
            id: req.id,
            kind: "preview".into(),
            results: None,
            preview: Some(preview),
            status: None,
            error: None,
            indexing: None,
            progress: None,
            backend: None,
        }
    }
}

fn warmup_loop(inner: Arc<Inner>) {
    inner.indexing.store(true, Ordering::SeqCst);
    inner.progress_cents.store(0, Ordering::SeqCst);
    let cfg = inner.cfg.lock().unwrap().clone();
    let walk_cfg = WalkConfig {
        roots: cfg.roots.clone(),
        extra_exclude: cfg.extra_exclude.clone(),
        max_files: cfg.max_files,
        max_depth: 16,
    };
    let samples = search::demo_files(&cfg.samples_dir);
    *inner.samples.lock().unwrap() = samples.clone();
    let collected = search::walk_index(&walk_cfg, |batch, seen| {
        let cap = walk_cfg.max_files.max(1);
        let pct = ((seen.min(cap) as f32 / cap as f32) * 10000.0) as u32;
        inner.progress_cents.store(pct.min(9999), Ordering::SeqCst);
        let merged = search::merge_unique(samples.clone(), batch.to_vec());
        *inner.files.lock().unwrap() = merged;
        *inner.backend.lock().unwrap() = "index-warming".into();
    });
    let merged = search::merge_unique(samples, collected);
    if let Ok(db) = inner.frecency.lock() {
        let _ = db.replace_files(&merged);
    }
    *inner.files.lock().unwrap() = merged.clone();
    inner.progress_cents.store(10000, Ordering::SeqCst);
    *inner.backend.lock().unwrap() = "index".into();
    inner.indexing.store(false, Ordering::SeqCst);

    let dirs = search::top_dirs(&merged, cfg.watch_cap as usize);
    inner
        .watch_count
        .store(dirs.len() as u32, Ordering::SeqCst);
    let mut last_full = std::time::Instant::now();
    loop {
        thread::sleep(Duration::from_secs(3));
        let extra = inner.cfg.lock().unwrap().extra_exclude.clone();
        let mut current = inner.files.lock().unwrap().clone();
        for dir in &dirs {
            let kids = search::rescan_dir(dir, &extra);
            for kid in kids {
                if let Some(existing) = current.iter_mut().find(|f| f.path == kid.path) {
                    *existing = kid;
                } else {
                    current.push(kid);
                }
            }
        }
        if last_full.elapsed() > Duration::from_secs(90) {
            let cfg = inner.cfg.lock().unwrap().clone();
            let walk_cfg = WalkConfig {
                roots: cfg.roots.clone(),
                extra_exclude: cfg.extra_exclude.clone(),
                max_files: cfg.max_files,
                max_depth: 16,
            };
            let samples = search::demo_files(&cfg.samples_dir);
            let collected = search::walk_index(&walk_cfg, |_, _| {});
            current = search::merge_unique(samples, collected);
            last_full = std::time::Instant::now();
            if let Ok(db) = inner.frecency.lock() {
                let _ = db.replace_files(&current);
            }
        }
        if current.len() > inner.cfg.lock().unwrap().max_files {
            current.truncate(inner.cfg.lock().unwrap().max_files);
        }
        *inner.files.lock().unwrap() = current;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn test_engine() -> Engine {
        let dir = env::temp_dir().join(format!("ql-eng-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let samples = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("samples");
        let cfg = AppConfig {
            roots: vec![samples.clone()],
            samples_dir: samples,
            cache_dir: dir.join("cache"),
            state_dir: dir.join("state"),
            home: dir.clone(),
            watch_cap: 32,
            cache_bytes: 8 * 1024 * 1024,
            max_files: 200,
            extra_exclude: vec![],
        };
        Engine::new(cfg)
    }

    #[test]
    fn implicit_query_returns_results_shape() {
        let eng = test_engine();
        let resp = eng.handle_line(r#"{"q":"inv","id":41}"#);
        let v: serde_json::Value = serde_json::from_str(&resp).unwrap();
        assert_eq!(v["id"], 41);
        assert_eq!(v["kind"], "results");
        assert!(v["results"].is_array());
    }

    #[test]
    fn stale_preview_id_can_be_dropped_by_caller() {
        assert!(protocol::parse(r#"{"id":2,"kind":"x"}"#).is_ok());
    }

    #[test]
    fn status_reports_helper_identity() {
        let eng = test_engine();
        let resp = eng.handle(protocol::parse(r#"{"id":1,"cmd":"status"}"#).unwrap());
        let st = resp.status.unwrap();
        assert_eq!(st.helper, "rust");
        assert_eq!(st.version, VERSION);
    }
}
