use quicklookd::{AppConfig, Engine};
use std::io::{self, BufRead, Write};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let oneshot = args.iter().any(|a| a == "--oneshot");
    let cfg = AppConfig::from_env_and_args(&args);
    let engine = Engine::new(cfg);
    engine.warmup_async();

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
