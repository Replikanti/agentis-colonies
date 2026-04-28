// TRIBES-BENCH STAGE 1 PLANTED-BUG TARGET. INTENTIONALLY INSECURE. NEVER COMPILE INTO PRODUCTION.
// Synthetic Stage 1 target — path traversal class.
// Three planted bugs across ~120 LOC. Do NOT fix the bugs.

use std::env;
use std::fs;
use std::path::PathBuf;

// Bug S1-PATHTRV-001 — PathBuf::push with un-normalised user input.
// Signature: base.push(name)
fn read_under(base_dir: &str, name: &str) -> std::io::Result<String> {
    let mut base = PathBuf::from(base_dir);
    base.push(name);
    fs::read_to_string(base)
}

// Bug S1-PATHTRV-002 — direct fs::read of caller-supplied path.
// Signature: fs::read(path)
fn slurp(path: &str) -> std::io::Result<Vec<u8>> {
    fs::read(path)
}

// Bug S1-PATHTRV-003 — error-path bug: failed canonicalize falls back to raw.
// Signature: .unwrap_or_else(|_| PathBuf::from(rel))
fn open_logfile(rel: &str) -> std::io::Result<String> {
    let logs = PathBuf::from("/var/log/myapp");
    let target = logs.join(rel).canonicalize().unwrap_or_else(|_| PathBuf::from(rel));
    fs::read_to_string(target)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let base = args.get(1).cloned().unwrap_or_else(|| "/tmp".to_string());
    let name = args.get(2).cloned().unwrap_or_else(|| "x".to_string());
    let raw = args.get(3).cloned().unwrap_or_else(|| "/etc/hostname".to_string());
    let rel = args.get(4).cloned().unwrap_or_else(|| "app.log".to_string());
    let _ = read_under(&base, &name);
    let _ = slurp(&raw);
    let _ = open_logfile(&rel);
}
