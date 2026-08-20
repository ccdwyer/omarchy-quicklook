use crate::limits::which;
use std::path::Path;
use std::process::{Command, Stdio};

fn spawn_detached(bin: &Path, args: &[&str]) -> Result<(), String> {
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

pub fn open_path(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err("missing".into());
    }
    let target = path.to_string_lossy().to_string();
    // Detach. run_limited reaps the process group when xdg-open/gio exits,
    // which kills the app they just launched.
    if let Some(gio) = which("gio") {
        return spawn_detached(&gio, &["open", &target]);
    }
    if let Some(xdg) = which("xdg-open") {
        return spawn_detached(&xdg, &[&target]);
    }
    if let Some(open) = which("open") {
        return spawn_detached(&open, &[&target]);
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
