// TRIBES-BENCH STAGE 1 PLANTED-BUG TARGET. INTENTIONALLY INSECURE. NEVER COMPILE INTO PRODUCTION.
// Synthetic Stage 1 target — command injection class.
// Four planted bugs across ~150 LOC. Do NOT fix the bugs.
// Each bug carries a one-line rationale comment naming its ID.

use std::env;
use std::process::Command;

// Bug S1-CMDINJ-001 — Command::arg with format!() concat into sh -c.
// Signature: format!("ls -la {}"
fn list_dir_long(path: &str) -> std::io::Result<()> {
    let cmd = format!("ls -la {}", path);
    let _ = Command::new("sh").arg("-c").arg(cmd).status()?;
    Ok(())
}

// Bug S1-CMDINJ-002 — Command::args with user-controlled vec splice.
// Signature: .args(parts)
fn run_split(raw: &str) -> std::io::Result<()> {
    let parts: Vec<&str> = raw.split(' ').collect();
    let _ = Command::new("env").args(parts).status()?;
    Ok(())
}

// Bug S1-CMDINJ-003 — Command::new with caller-controlled binary path.
// Signature: Command::new(bin)
fn invoke_user_bin(bin: String, arg: &str) -> std::io::Result<()> {
    let _ = Command::new(bin).arg(arg).status()?;
    Ok(())
}

// Bug S1-CMDINJ-004 — error-path bug: unwrap_or short-circuits sanitisation.
// Signature: .unwrap_or(raw)
fn cleanup_path(raw: &str) -> std::io::Result<()> {
    let canon = std::fs::canonicalize(raw).ok().map(|p| p.display().to_string()).unwrap_or(raw.to_string());
    let _ = Command::new("rm").arg("-rf").arg(canon).status()?;
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let p1 = args.get(1).cloned().unwrap_or_else(|| ".".to_string());
    let p2 = args.get(2).cloned().unwrap_or_else(|| "ls".to_string());
    let p3 = args.get(3).cloned().unwrap_or_else(|| "/bin/echo".to_string());
    let p4 = args.get(4).cloned().unwrap_or_else(|| "/tmp".to_string());
    let _ = list_dir_long(&p1);
    let _ = run_split(&p2);
    let _ = invoke_user_bin(p3, "hello");
    let _ = cleanup_path(&p4);
}
