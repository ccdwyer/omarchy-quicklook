use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub id: u64,
    #[serde(default)]
    pub cmd: Option<String>,
    #[serde(default)]
    pub q: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub page: Option<u32>,
    #[serde(default)]
    pub palette: Option<PaletteIn>,
    #[serde(default)]
    pub roots: Option<Vec<String>>,
    #[serde(default, alias = "watchCap")]
    pub watch_cap: Option<u32>,
    #[serde(default, alias = "cacheMb")]
    pub cache_mb: Option<u32>,
    #[serde(default, alias = "maxFiles")]
    pub max_files: Option<u32>,
    #[serde(default, alias = "extraExclude")]
    pub extra_exclude: Option<Vec<String>>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaletteIn {
    #[serde(default)]
    pub bg: Option<String>,
    #[serde(default)]
    pub fg: Option<String>,
    #[serde(default)]
    pub accent: Option<String>,
    #[serde(default)]
    pub surface: Option<String>,
}

impl Request {
    pub fn command(&self) -> &str {
        if let Some(c) = self.cmd.as_deref() {
            if !c.is_empty() {
                return c;
            }
        }
        if self.q.is_some() {
            return "query";
        }
        if self.path.is_some() {
            return "preview";
        }
        "status"
    }
}

pub fn parse(line: &str) -> Result<Request, String> {
    serde_json::from_str(line.trim()).map_err(|e| format!("bad json: {e}"))
}

#[derive(Debug, Clone, Serialize)]
pub struct Response {
    pub id: u64,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub results: Option<Vec<Hit>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<Preview>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub indexing: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backend: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Hit {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub score: i64,
    pub mtime: u64,
    pub size: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Preview {
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lang: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capped: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub large: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub headers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rows: Option<Vec<Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page_count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub need_poppler: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<DirEnt>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hex: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub magic: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DirEnt {
    pub name: String,
    pub kind: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub indexing: bool,
    pub progress: f32,
    pub backend: String,
    pub files: u64,
    #[serde(rename = "watchCount")]
    pub watch_count: u32,
    #[serde(rename = "watchCap")]
    pub watch_cap: u32,
    pub roots: Vec<String>,
    #[serde(rename = "cacheBytes")]
    pub cache_bytes: u64,
    #[serde(rename = "cacheBudget")]
    pub cache_budget: u64,
    pub poppler: bool,
    pub plocate: bool,
    pub ffmpeg: bool,
    pub helper: String,
    pub version: String,
}

impl Response {
    pub fn error(id: u64, msg: impl Into<String>) -> Self {
        Self {
            id,
            kind: "error".into(),
            results: None,
            preview: None,
            status: None,
            error: Some(msg.into()),
            indexing: None,
            progress: None,
            backend: None,
        }
    }

    pub fn ok(id: u64) -> Self {
        Self {
            id,
            kind: "ok".into(),
            results: None,
            preview: None,
            status: None,
            error: None,
            indexing: None,
            progress: None,
            backend: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn implicit_query_cmd() {
        let r = parse(r#"{"q":"invo","id":41}"#).unwrap();
        assert_eq!(r.id, 41);
        assert_eq!(r.command(), "query");
        assert_eq!(r.q.as_deref(), Some("invo"));
    }

    #[test]
    fn camel_case_config_aliases() {
        let r = parse(r#"{"id":1,"cmd":"config","watchCap":100,"cacheMb":50,"maxFiles":9}"#).unwrap();
        assert_eq!(r.watch_cap, Some(100));
        assert_eq!(r.cache_mb, Some(50));
        assert_eq!(r.max_files, Some(9));
    }

    #[test]
    fn results_json_stable_keys() {
        let resp = Response {
            id: 41,
            kind: "results".into(),
            results: Some(vec![Hit {
                path: "/tmp/invoice.pdf".into(),
                name: "invoice.pdf".into(),
                kind: "pdf".into(),
                score: 12,
                mtime: 1,
                size: 2,
            }]),
            preview: None,
            status: None,
            error: None,
            indexing: Some(false),
            progress: Some(1.0),
            backend: Some("demo".into()),
        };
        let s = serde_json::to_string(&resp).unwrap();
        assert!(s.contains("\"id\":41"));
        assert!(s.contains("\"kind\":\"results\""));
        assert!(s.contains("invoice.pdf"));
    }
}
