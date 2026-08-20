use std::io;
use std::io::Read;
use std::path::Path;
use std::process::{Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

/// Hard cap on captured stdout/stderr from any child subprocess. Excess is
/// drained and discarded so a flooding child can neither exhaust memory nor
/// deadlock on a full pipe.
pub const OUTPUT_CAP: usize = 96 * 1024;

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

/// Read `src` to EOF, retaining at most `OUTPUT_CAP` bytes and discarding the
/// rest. Keeps draining after the cap so the writer never blocks on a full pipe.
fn spawn_capped_reader<R: Read + Send + 'static>(mut src: R) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut kept: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 16 * 1024];
        loop {
            match src.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    if kept.len() < OUTPUT_CAP {
                        let room = OUTPUT_CAP - kept.len();
                        kept.extend_from_slice(&chunk[..n.min(room)]);
                    }
                    // Bytes beyond the cap are read and dropped so the child's
                    // write() never blocks on a full pipe buffer.
                }
                Err(_) => break,
            }
        }
        kept
    })
}

#[cfg(unix)]
fn signal_group(pid: u32, sig: libc::c_int) {
    // Child is its own process-group leader (pgid == pid) via process_group(0),
    // so a negative pid signals the whole group, reaping descendants too.
    unsafe {
        libc::kill(-(pid as i32), sig);
    }
}
#[cfg(not(unix))]
fn signal_group(_pid: u32, _sig: i32) {}

/// True if the process group `pid` still has at least one signalable member.
/// `kill(-pgid, 0)` returns 0 when the group exists with a member and -1/ESRCH
/// when it is empty. Once the leader has exited, this is true iff a descendant
/// is still alive in the group (and may be holding the child's pipes open).
#[cfg(unix)]
fn group_has_members(pid: u32) -> bool {
    unsafe { libc::kill(-(pid as i32), 0) == 0 }
}

/// Force the whole process group down before we join the drain threads: TERM,
/// a brief grace, then an unconditional KILL. SIGKILL is uncatchable, so any
/// TERM-ignoring descendant is guaranteed dead afterward — which closes the
/// child's stdout/stderr and lets the drain joins complete instead of hanging.
#[cfg(unix)]
fn reap_group(pid: u32) {
    signal_group(pid, libc::SIGTERM);
    thread::sleep(Duration::from_millis(50));
    signal_group(pid, libc::SIGKILL);
}
#[cfg(not(unix))]
fn reap_group(_pid: u32) {}

/// Spawn `cmd` in its own process group, drain its output under a hard cap, and
/// enforce a wall-clock timeout with a group TERM-then-KILL so no descendant
/// outlives the deadline. Never buffers more than `OUTPUT_CAP` of output.
pub fn run_limited(mut cmd: Command, timeout: Duration, mem_bytes: u64, cpu_secs: u64) -> io::Result<Output> {
    apply_rlimits(&mut cmd, mem_bytes, cpu_secs);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // New process group with pgid == child pid; lets us kill the whole tree.
        cmd.process_group(0);
    }
    let mut child = cmd.spawn()?;
    let pid = child.id();
    let out_h = child.stdout.take().map(spawn_capped_reader);
    let err_h = child.stderr.take().map(spawn_capped_reader);

    let collect = |h: Option<thread::JoinHandle<Vec<u8>>>| -> Vec<u8> {
        h.map(|j| j.join().unwrap_or_default()).unwrap_or_default()
    };

    let start = Instant::now();
    loop {
        match child.try_wait()? {
            Some(status) => {
                // The leader exited. A descendant still in the group may hold the
                // child's stdout/stderr open, which would hang the drain joins
                // below forever. If the group is non-empty, force it down (TERM,
                // grace, unconditional KILL) *before* joining so the pipes are
                // guaranteed closed. The common clean-exit case leaves the group
                // empty, so a well-behaved tool returns with no added latency.
                #[cfg(unix)]
                if group_has_members(pid) {
                    reap_group(pid);
                }
                let stdout = collect(out_h);
                let stderr = collect(err_h);
                return Ok(build_output(status, stdout, stderr));
            }
            None => {
                if start.elapsed() >= timeout {
                    // Timed out: TERM, grace, unconditional group KILL, reap the
                    // leader, then join the (now-closed) drains.
                    reap_group(pid);
                    let _ = child.wait();
                    let _ = collect(out_h);
                    let _ = collect(err_h);
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "killed"));
                }
                thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

fn build_output(status: ExitStatus, stdout: Vec<u8>, stderr: Vec<u8>) -> Output {
    Output {
        status,
        stdout,
        stderr,
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
                // RLIMIT_AS is applied on Linux only: on macOS a low
                // address-space cap makes dyld fail to map shared libraries and
                // exec aborts, so it is unusable there. Linux enforces it
                // cleanly, bounding a hostile renderer's memory.
                #[cfg(target_os = "linux")]
                {
                    let as_lim = libc::rlimit {
                        rlim_cur: mem,
                        rlim_max: mem,
                    };
                    libc::setrlimit(libc::RLIMIT_AS, &as_lim);
                }
                #[cfg(not(target_os = "linux"))]
                let _ = mem;
                let cpu_lim = libc::rlimit {
                    rlim_cur: cpu,
                    rlim_max: cpu,
                };
                libc::setrlimit(libc::RLIMIT_CPU, &cpu_lim);
                // RLIMIT_NPROC is intentionally NOT set: it counts the real
                // user's entire existing process table, so any absolute cap
                // makes fork/pthread_create fail (EAGAIN) for a normally-busy
                // user — which would break threaded tools like pdftoppm. Fork
                // bombs are bounded by RLIMIT_CPU plus the wall-clock group
                // TERM-then-KILL in run_limited.
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
    fn run_limited_returns_small_output() {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg("printf hello");
        let out = run_limited(cmd, Duration::from_millis(2000), 128 * 1024 * 1024, 2).unwrap();
        assert_eq!(out.stdout, b"hello");
    }

    #[test]
    fn run_limited_bounds_flooding_output() {
        // `yes` floods stdout forever. The old wait_with_output path would buffer
        // it unboundedly (OOM) or block on the full pipe; the capped drain must
        // keep memory bounded and the timeout must still fire promptly.
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg("yes ABCDEFGHIJKLMNOP");
        let start = Instant::now();
        let r = run_limited(cmd, Duration::from_millis(300), 512 * 1024 * 1024, 4);
        assert!(
            start.elapsed() < Duration::from_secs(3),
            "flooding output was not bounded/killed in time: {:?}",
            start.elapsed()
        );
        assert!(r.is_err(), "flooding child should hit the timeout");
    }

    #[cfg(unix)]
    #[test]
    fn run_limited_kills_term_ignoring_descendant() {
        // Parent ignores TERM and spawns a TERM-ignoring descendant that writes
        // its pid to a marker file, then both sleep well past the timeout. After
        // run_limited returns, a group SIGKILL must have reaped the descendant.
        let marker = std::env::temp_dir().join(format!("ql_desc_{}", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        let script = format!(
            "trap '' TERM; ( trap '' TERM; echo $$ > '{m}'; sleep 30 ) & sleep 30",
            m = marker.display()
        );
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg(&script);
        let start = Instant::now();
        let r = run_limited(cmd, Duration::from_millis(400), 128 * 1024 * 1024, 4);
        assert!(r.is_err());
        assert!(start.elapsed() < Duration::from_secs(3));
        // Give the group KILL a moment to take effect, then confirm the
        // descendant pid recorded in the marker is gone.
        thread::sleep(Duration::from_millis(200));
        if let Ok(txt) = std::fs::read_to_string(&marker) {
            if let Ok(desc) = txt.trim().parse::<i32>() {
                // kill(pid, 0) returns -1/ESRCH when the process no longer exists.
                let alive = unsafe { libc::kill(desc, 0) } == 0;
                assert!(!alive, "TERM-ignoring descendant {desc} survived group kill");
            }
        }
        let _ = std::fs::remove_file(&marker);
    }

    #[cfg(unix)]
    #[test]
    fn run_limited_early_leader_exit_does_not_hang() {
        // The regression this guards: the group LEADER exits cleanly and
        // immediately, but a TERM-ignoring descendant it spawned inherits
        // stdout/stderr and keeps them open. The old code sent only TERM on the
        // normal-exit path and then joined the drain threads, which hung forever
        // because the descendant ignored TERM and never closed the pipes. The
        // fix must group-KILL before joining so this returns promptly.
        let marker = std::env::temp_dir().join(format!("ql_early_{}", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        // Descendant: its own sh (so `$$` is its real pid), ignores TERM, keeps
        // stdout open in an infinite loop — only SIGKILL ends it. Leader spawns
        // it in the background, then exits 0 at once.
        let script = format!(
            "sh -c 'trap \"\" TERM; echo $$ > \"{m}\"; while true; do sleep 1; done' & exit 0",
            m = marker.display()
        );
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg(&script);
        let start = Instant::now();
        // Generous timeout: if the fix is wrong the drain join hangs and this
        // never returns, so completing far under the timeout proves the fix.
        let r = run_limited(cmd, Duration::from_secs(20), 128 * 1024 * 1024, 30);
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_secs(3),
            "early-leader-exit hung on the drain join: {elapsed:?}"
        );
        // Leader exited 0, so run_limited returns Ok with the leader's status.
        assert!(r.is_ok(), "expected Ok on clean leader exit, got {r:?}");
        // The TERM-ignoring descendant must have been reaped by the group KILL.
        thread::sleep(Duration::from_millis(200));
        if let Ok(txt) = std::fs::read_to_string(&marker) {
            if let Ok(desc) = txt.trim().parse::<i32>() {
                let alive = unsafe { libc::kill(desc, 0) } == 0;
                assert!(
                    !alive,
                    "TERM-ignoring descendant {desc} survived after early leader exit"
                );
            }
        }
        let _ = std::fs::remove_file(&marker);
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
