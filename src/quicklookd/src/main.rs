use quicklookd::{AppConfig, Engine};
use std::io::{self, BufRead, Write};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(i) = args.iter().position(|a| a == "--downsample") {
        let src = args.get(i + 1).map(std::path::PathBuf::from);
        let dest = args.get(i + 2).map(std::path::PathBuf::from);
        let nw: u32 = args.get(i + 3).and_then(|s| s.parse().ok()).unwrap_or(1);
        let nh: u32 = args.get(i + 4).and_then(|s| s.parse().ok()).unwrap_or(1);
        let rc = match (src, dest) {
            (Some(s), Some(d)) => quicklookd::preview::downsample_cli(&s, &d, nw, nh),
            _ => 1,
        };
        std::process::exit(rc);
    }
    let oneshot = args.iter().any(|a| a == "--oneshot");
    let cfg = AppConfig::from_env_and_args(&args);
    let engine = Engine::new(cfg);
    // Indexing starts on `config` / `warmup` so inline shell.json roots
    // win the first walk. Oneshot queries use plocate / a bounded walk.

    if oneshot {
        let payload = oneshot_payload(&args);
        let out = engine.handle_line(&payload);
        println!("{out}");
        return;
    }

    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        if line.trim() == r#"{"cmd":"quit"}"# {
            break;
        }
        let out = engine.handle_line(&line);
        if writeln!(stdout, "{out}").is_err() {
            break;
        }
        let _ = stdout.flush();
    }
}

fn oneshot_payload(args: &[String]) -> String {
    let mut saw = false;
    for a in args {
        if saw {
            return a.clone();
        }
        if a == "--oneshot" {
            saw = true;
        }
    }
    let mut s = String::new();
    let _ = io::stdin().read_line(&mut s);
    s
}
