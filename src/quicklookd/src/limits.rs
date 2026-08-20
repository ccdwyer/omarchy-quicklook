use std::io;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub fn with_timeout<T, F>(ms: u64, f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
        let _ = tx.send(result);
    });
    match rx.recv_timeout(Duration::from_millis(ms)) {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(_)) => Err("parser panicked".into()),
        Err(_) => Err("timeout".into()),
    }
}

pub fn run_limited(mut cmd: Command, timeout: Duration, mem_bytes: u64, cpu_secs: u64) -> io::Result<Output> {
    apply_rlimits(&mut cmd, mem_bytes, cpu_secs);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    let start = Instant::now();
    loop {
        match child.try_wait()? {
            Some(_) => return child.wait_with_output(),
            None => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "killed"));
                }
                thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

fn apply_rlimits(cmd: &mut Command, mem_bytes: u64, cpu_secs: u64) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let mem = mem_bytes;
        let cpu = cpu_secs;
        unsafe {
            cmd.pre_exec(move || {
                let as_lim = libc::rlimit {
                    rlim_cur: mem,
                    rlim_max: mem,
                };
                libc::setrlimit(libc::RLIMIT_AS, &as_lim);
                let cpu_lim = libc::rlimit {
                    rlim_cur: cpu,
                    rlim_max: cpu,
                };
                libc::setrlimit(libc::RLIMIT_CPU, &cpu_lim);
                let nproc = libc::rlimit {
                    rlim_cur: 32,
                    rlim_max: 32,
                };
                #[cfg(any(target_os = "linux", target_os = "android"))]
                libc::setrlimit(libc::RLIMIT_NPROC, &nproc);
                let _ = nproc;
                Ok(())
            });
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (cmd, mem_bytes, cpu_secs);
    }
}

pub fn which(name: &str) -> Option<std::path::PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

pub fn file_exists(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeout_kills_slow_closure() {
        let r: Result<u8, _> = with_timeout(50, || {
            thread::sleep(Duration::from_millis(400));
            1
        });
        assert!(r.is_err());
    }

    #[test]
    fn timeout_allows_fast_closure() {
        let r = with_timeout(400, || 7u8).unwrap();
        assert_eq!(r, 7);
    }

    #[test]
    fn catch_unwind_is_error() {
        let r: Result<u8, _> = with_timeout(400, || panic!("boom"));
        assert!(r.unwrap_err().contains("panic"));
    }
}
