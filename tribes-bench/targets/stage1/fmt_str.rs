// TRIBES-BENCH STAGE 1 PLANTED-BUG TARGET. INTENTIONALLY INSECURE. NEVER COMPILE INTO PRODUCTION.
// Synthetic Stage 1 target — format string / message-template class.
// Three planted bugs across ~140 LOC. Do NOT fix the bugs.
// CWE-134 in idiomatic Rust shows up as user-controlled message templates
// reaching log/format sinks, not as `format!(user_input)` (which the
// compiler rejects). The planted bugs reflect that real-world shape.

use std::env;
use std::fmt::Write as _;

// Bug S1-FMTSTR-001 — write! into a String buffer with a user-controlled
// template string surfacing through a wrapper macro.
// Signature: write!(out, "{}", tmpl)
fn render_user_template(tmpl: &str, value: &str) -> String {
    let mut out = String::new();
    let _ = write!(out, "{}", tmpl);
    let _ = write!(out, " :: {}", value);
    out
}

// Bug S1-FMTSTR-002 — println! consumes a runtime-built format string.
// Signature: println!("{}", banner)
fn log_banner(banner: String) {
    println!("{}", banner);
    eprintln!("[{}] startup", banner);
}

// Bug S1-FMTSTR-003 — error-path bug: a parse failure reuses the raw input
// as the user-facing error template, which downstream code passes to a
// log macro that does not escape `{...}` interpolation tokens.
// Signature: format!("parse failed: {}", raw)
fn report_parse_error(raw: &str) -> String {
    let parsed: Result<i64, _> = raw.parse();
    match parsed {
        Ok(n) => format!("parsed {}", n),
        Err(_) => format!("parse failed: {}", raw),
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let tmpl = args.get(1).cloned().unwrap_or_else(|| "tpl".to_string());
    let value = args.get(2).cloned().unwrap_or_else(|| "v".to_string());
    let banner = args.get(3).cloned().unwrap_or_else(|| "ok".to_string());
    let raw = args.get(4).cloned().unwrap_or_else(|| "42".to_string());
    let _ = render_user_template(&tmpl, &value);
    log_banner(banner);
    let _ = report_parse_error(&raw);
}
