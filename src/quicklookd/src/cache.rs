use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

pub struct PreviewCache {
    pub dir: PathBuf,
    budget: AtomicU64,
}

impl PreviewCache {
    pub fn new(dir: PathBuf, budget: u64) -> Self {
        let previews = dir.join("previews");
        let _ = fs::create_dir_all(&previews);
        Self {
            dir,
            budget: AtomicU64::new(budget.max(1)),
        }
    }

    pub fn budget(&self) -> u64 {
        self.budget.load(Ordering::SeqCst)
    }

    pub fn set_budget(&self, bytes: u64) {
        self.budget.store(bytes.max(1), Ordering::SeqCst);
        self.gc();
    }

    pub fn preview_dir(&self) -> PathBuf {
        self.dir.join("previews")
    }

    pub fn key(&self, parts: &[&str]) -> String {
        let mut h = Sha256::new();
        for p in parts {
            h.update(p.as_bytes());
            h.update([0]);
        }
        hex::encode(h.finalize())
    }

    pub fn path_for(&self, parts: &[&str], ext: &str) -> PathBuf {
        self.preview_dir().join(format!("{}.{}", self.key(parts), ext))
    }

    pub fn bytes_used(&self) -> u64 {
        walk_size(&self.preview_dir())
    }

    pub fn gc(&self) {
        let dir = self.preview_dir();
        let mut files: Vec<(SystemTime, u64, PathBuf)> = Vec::new();
        let mut total = 0u64;
        if let Ok(rd) = fs::read_dir(&dir) {
            for ent in rd.flatten() {
                let p = ent.path();
                if !p.is_file() {
                    continue;
                }
                let meta = match p.metadata() {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                let mtime = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                let size = meta.len();
                total += size;
                files.push((mtime, size, p));
            }
        }
        let budget = self.budget();
        if total <= budget {
            return;
        }
        files.sort_by(|a, b| a.0.cmp(&b.0));
        for (_, size, path) in files {
            if total <= budget {
                break;
            }
            if fs::remove_file(&path).is_ok() {
                total = total.saturating_sub(size);
            }
        }
    }

    pub fn store_bytes(&self, parts: &[&str], ext: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
        let dest = self.path_for(parts, ext);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&dest, bytes)?;
        if self.bytes_used() > self.budget() {
            self.gc();
        }
        Ok(dest)
    }
}

fn walk_size(dir: &Path) -> u64 {
    let mut n = 0u64;
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return 0,
    };
    for ent in rd.flatten() {
        let p = ent.path();
        if p.is_file() {
            n += p.metadata().map(|m| m.len()).unwrap_or(0);
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn gc_drops_oldest_until_budget() {
        let dir = env::temp_dir().join(format!("ql-cache-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let cache = PreviewCache::new(dir.clone(), 64);
        cache.store_bytes(&["a"], "bin", &[0u8; 50]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        cache.store_bytes(&["b"], "bin", &[1u8; 50]).unwrap();
        assert!(cache.bytes_used() <= 64);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn keys_are_stable() {
        let dir = env::temp_dir().join("ql-cache-key");
        let cache = PreviewCache::new(dir, 100);
        let a = cache.key(&["/tmp/x", "1", "png"]);
        let b = cache.key(&["/tmp/x", "1", "png"]);
        let c = cache.key(&["/tmp/x", "2", "png"]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn set_budget_evicts_immediately() {
        let dir = env::temp_dir().join(format!("ql-cache-budget-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let cache = PreviewCache::new(dir.clone(), 200);
        cache.store_bytes(&["a"], "bin", &[0u8; 80]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        cache.store_bytes(&["b"], "bin", &[1u8; 80]).unwrap();
        assert!(cache.bytes_used() > 80);
        cache.set_budget(80);
        assert_eq!(cache.budget(), 80);
        assert!(cache.bytes_used() <= 80);
        let _ = fs::remove_dir_all(&dir);
    }
}
