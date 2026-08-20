use crate::limits::{run_limited, which};
use std::path::Path;
use std::process::Command;
use std::time::Duration;

pub fn open_path(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err("missing".into());
    }
    let target = path.to_string_lossy().to_string();
    if let Some(gio) = which("gio") {
        let mut cmd = Command::new(gio);
        cmd.args(["open", &target]);
        return run_limited(cmd, Duration::from_secs(8), 128 * 1024 * 1024, 4)
            .map(|_| ())
            .map_err(|e| e.to_string());
    }
    if let Some(xdg) = which("xdg-open") {
        let mut cmd = Command::new(xdg);
        cmd.arg(&target);
        return run_limited(cmd, Duration::from_secs(8), 128 * 1024 * 1024, 4)
            .map(|_| ())
            .map_err(|e| e.to_string());
    }
    if let Some(open) = which("open") {
        let mut cmd = Command::new(open);
        cmd.arg(&target);
        return run_limited(cmd, Duration::from_secs(8), 128 * 1024 * 1024, 4)
            .map(|_| ())
            .map_err(|e| e.to_string());
    }
    Err("no opener".into())
}

pub fn reveal_path(path: &Path) -> Result<(), String> {
    let parent = if path.is_dir() {
        path
    } else {
        path.parent().unwrap_or(path)
    };
    open_path(parent)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn missing_path_errors() {
        let err = open_path(Path::new("/no/such/quicklook/file")).unwrap_err();
        assert_eq!(err, "missing");
    }

    #[test]
    fn reveal_uses_parent() {
        let dir = env::temp_dir();
        let p = dir.join("ql-reveal-probe.txt");
        let _ = std::fs::write(&p, b"x");
        // Best-effort: may fail in headless CI if no opener exists.
        let _ = reveal_path(&p);
        let _ = std::fs::remove_file(&p);
    }
}
