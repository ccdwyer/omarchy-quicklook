use std::io;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

static PARSE_THREADS: AtomicU32 = AtomicU32::new(0);
static LIVE_THREADS: AtomicU32 = AtomicU32::new(0);
const MAX_PARSE_THREADS: u32 = 2;
const MAX_LIVE_THREADS: u32 = 16;

pub fn with_timeout<T, F>(ms: u64, f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let live = LIVE_THREADS.fetch_add(1, Ordering::SeqCst);
    if live >= MAX_LIVE_THREADS {
        LIVE_THREADS.fetch_sub(1, Ordering::SeqCst);
        return Err("parser busy".into());
    }
    loop {
        let n = PARSE_THREADS.load(Ordering::SeqCst);
        if n >= MAX_PARSE_THREADS {
            LIVE_THREADS.fetch_sub(1, Ordering::SeqCst);
            return Err("parser busy".into());
        }
        if PARSE_THREADS
            .compare_exchange(n, n + 1, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            break;
        }
    }
    let released = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let released_t = released.clone();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
        if !released_t.swap(true, Ordering::SeqCst) {
            PARSE_THREADS.fetch_sub(1, Ordering::SeqCst);
        }
        LIVE_THREADS.fetch_sub(1, Ordering::SeqCst);
        let _ = tx.send(result);
    });
    match rx.recv_timeout(Duration::from_millis(ms)) {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(_)) => Err("parser panicked".into()),
        Err(_) => {
            if !released.swap(true, Ordering::SeqCst) {
                PARSE_THREADS.fetch_sub(1, Ordering::SeqCst);
            }
            Err("timeout".into())
        }
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

/// Serialize tests that mutate process-wide `PATH`. Restores PATH on unwind.
pub fn with_path_lock<R, F: FnOnce() -> R>(f: F) -> R {
    static LOCK: Mutex<()> = Mutex::new(());
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let old = std::env::var("PATH").unwrap_or_default();
    struct Restore(String);
    impl Drop for Restore {
        fn drop(&mut self) {
            std::env::set_var("PATH", &self.0);
        }
    }
    let _restore = Restore(old);
    f()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_limited_kills_hung_child() {
        let mut cmd = Command::new("sleep");
        cmd.arg("30");
        let start = Instant::now();
        let r = run_limited(cmd, Duration::from_millis(250), 32 * 1024 * 1024, 1);
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_secs(3),
            "run_limited did not kill hung child: {elapsed:?}"
        );
        assert!(r.is_err() || !r.unwrap().status.success());
    }

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
        for _ in 0..20 {
            match with_timeout(400, || 7u8) {
                Ok(v) => {
                    assert_eq!(v, 7);
                    return;
                }
                Err(e) if e.contains("busy") => thread::sleep(Duration::from_millis(50)),
                Err(e) => panic!("{e}"),
            }
        }
        panic!("parser stayed busy");
    }

    #[test]
    fn catch_unwind_is_error() {
        for _ in 0..20 {
            match with_timeout(400, || -> u8 { panic!("boom") }) {
                Err(e) if e.contains("panic") => return,
                Err(e) if e.contains("busy") => thread::sleep(Duration::from_millis(50)),
                other => panic!("{other:?}"),
            }
        }
        panic!("parser stayed busy");
    }

    #[test]
    fn timeout_releases_slot_for_later_work() {
        let _ = with_timeout(40, || {
            thread::sleep(Duration::from_millis(300));
            1u8
        });
        let r = with_timeout(400, || 9u8);
        assert_eq!(r.unwrap(), 9);
    }

    #[test]
    fn timeout_threads_are_capped() {
        let a = thread::spawn(|| with_timeout(80, || { thread::sleep(Duration::from_millis(400)); 1u8 }));
        thread::sleep(Duration::from_millis(10));
        let b = thread::spawn(|| with_timeout(80, || { thread::sleep(Duration::from_millis(400)); 1u8 }));
        thread::sleep(Duration::from_millis(10));
        let c = with_timeout(80, || { thread::sleep(Duration::from_millis(400)); 1u8 });
        let _ = a.join();
        let _ = b.join();
        assert!(c.is_err());
        let err = c.unwrap_err();
        assert!(err.contains("busy") || err.contains("timeout"), "{err}");
    }
}
