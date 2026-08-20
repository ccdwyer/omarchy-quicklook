use rusqlite::{params, Connection};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Frecency {
    conn: Connection,
}

impl Frecency {
    pub fn open(path: &Path) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let conn = Connection::open(path).map_err(|e| e.to_string())?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                mtime INTEGER NOT NULL,
                size INTEGER NOT NULL,
                kind TEXT NOT NULL,
                is_dir INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS selects (
                path TEXT PRIMARY KEY,
                count INTEGER NOT NULL,
                last_ms INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS meta (
                k TEXT PRIMARY KEY,
                v TEXT NOT NULL
             );",
        )
        .map_err(|e| e.to_string())?;
        Ok(Self { conn })
    }

    pub fn touch(&self, path: &str) -> Result<(), String> {
        let now = now_ms();
        self.conn
            .execute(
                "INSERT INTO selects(path, count, last_ms) VALUES (?1, 1, ?2)
                 ON CONFLICT(path) DO UPDATE SET count = count + 1, last_ms = ?2",
                params![path, now as i64],
            )
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn boost(&self, path: &str) -> i64 {
        let row = self.conn.query_row(
            "SELECT count, last_ms FROM selects WHERE path = ?1",
            params![path],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
        );
        let (count, last) = match row {
            Ok(v) => v,
            Err(_) => return 0,
        };
        let freq = log2_boost(count);
        let recency = recency_boost(last as u64, now_ms());
        freq + recency
    }

    pub fn recent(&self, limit: usize) -> Vec<String> {
        let mut stmt = match self
            .conn
            .prepare("SELECT path FROM selects ORDER BY last_ms DESC LIMIT ?1")
        {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = stmt.query_map(params![limit as i64], |r| r.get::<_, String>(0));
        match rows {
            Ok(iter) => iter.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn replace_files(&self, files: &[crate::search::IndexedFile]) -> Result<(), String> {
        let tx = self.conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute("DELETE FROM files", []).map_err(|e| e.to_string())?;
        {
            let mut stmt = tx
                .prepare("INSERT INTO files(path, name, mtime, size, kind, is_dir) VALUES (?1,?2,?3,?4,?5,?6)")
                .map_err(|e| e.to_string())?;
            for f in files {
                stmt.execute(params![
                    f.path,
                    f.name,
                    f.mtime as i64,
                    f.size as i64,
                    f.kind,
                    if f.is_dir { 1 } else { 0 }
                ])
                .map_err(|e| e.to_string())?;
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn load_files(&self) -> Vec<crate::search::IndexedFile> {
        let mut stmt = match self
            .conn
            .prepare("SELECT path, name, mtime, size, kind, is_dir FROM files")
        {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = stmt.query_map([], |r| {
            Ok(crate::search::IndexedFile {
                path: r.get(0)?,
                name: r.get(1)?,
                mtime: r.get::<_, i64>(2)? as u64,
                size: r.get::<_, i64>(3)? as u64,
                kind: r.get(4)?,
                is_dir: r.get::<_, i64>(5)? != 0,
            })
        });
        match rows {
            Ok(iter) => iter.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn set_meta(&self, k: &str, v: &str) {
        let _ = self.conn.execute(
            "INSERT INTO meta(k, v) VALUES (?1, ?2)
             ON CONFLICT(k) DO UPDATE SET v = ?2",
            params![k, v],
        );
    }

    pub fn get_meta(&self, k: &str) -> Option<String> {
        self.conn
            .query_row("SELECT v FROM meta WHERE k = ?1", params![k], |r| r.get(0))
            .ok()
    }
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn mtime_boost(mtime_ms: u64) -> i64 {
    recency_boost(mtime_ms, now_ms())
}

pub fn recency_boost(then_ms: u64, now: u64) -> i64 {
    if then_ms == 0 || now < then_ms {
        return 0;
    }
    let age = now.saturating_sub(then_ms);
    const HOUR: u64 = 3_600_000;
    const DAY: u64 = 24 * HOUR;
    const WEEK: u64 = 7 * DAY;
    const MONTH: u64 = 30 * DAY;
    if age < HOUR {
        200
    } else if age < DAY {
        100
    } else if age < WEEK {
        40
    } else if age < MONTH {
        15
    } else {
        0
    }
}

pub fn log2_boost(count: i64) -> i64 {
    if count <= 0 {
        return 0;
    }
    let mut n = count as u64 + 1;
    let mut bits = 0i64;
    while n > 1 {
        n >>= 1;
        bits += 1;
    }
    bits * 80
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn atime_is_not_used_in_boost() {
        let now = 1_700_000_000_000u64;
        assert_eq!(recency_boost(now - 1_000, now), 200);
        assert_eq!(recency_boost(now - 3_600_000 * 2, now), 100);
        assert_eq!(recency_boost(0, now), 0);
    }

    #[test]
    fn sqlite_roundtrip_and_boost() {
        let dir = env::temp_dir().join(format!("ql-fre-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let db = dir.join("i.sqlite");
        let _ = std::fs::remove_file(&db);
        let f = Frecency::open(&db).unwrap();
        f.touch("/tmp/invoice.pdf").unwrap();
        f.touch("/tmp/invoice.pdf").unwrap();
        assert!(f.boost("/tmp/invoice.pdf") > 0);
        assert_eq!(f.boost("/nope"), 0);
        assert_eq!(f.recent(4)[0], "/tmp/invoice.pdf");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn log2_grows_slowly() {
        assert_eq!(log2_boost(1), 80);
        assert_eq!(log2_boost(3), 160);
        assert!(log2_boost(1000) < 10000);
    }
}
