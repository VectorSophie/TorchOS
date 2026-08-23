use anyhow::Result;
use std::process::Command;

// PHASE 1 NOTE: this is what the locked design calls "structured diagnostics" — the
// same kind of facts `status`/`doctor` print for a human, but as JSON so the AI
// assistant (Phase 3) can consume them as data instead of re-parsing terminal text.
// Hand-rolled JSON, not serde: the shape is a flat list of fields, not worth a
// dependency yet — revisit if/when torchd needs to pass richer structures around.

pub fn run() -> Result<()> {
    let mut fields: Vec<(&str, String)> = Vec::new();

    fields.push(("kernel", cmd_output("uname", &["-r"])));
    fields.push(("hostname", cmd_output("hostnamectl", &["hostname"])));
    fields.push(("root_fstype", cmd_output("findmnt", &["-no", "FSTYPE", "/"])));
    fields.push(("gpu", first_gpu_line()));
    fields.push(("failed_units", failed_units()));
    fields.push(("mem_available_kb", mem_available_kb()));

    print!("{{");
    for (i, (key, value)) in fields.iter().enumerate() {
        if i > 0 {
            print!(",");
        }
        print!("\"{key}\":{}", json_string(value));
    }
    println!("}}");

    Ok(())
}

fn cmd_output(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn first_gpu_line() -> String {
    let out = cmd_output("lspci", &[]);
    out.lines()
        .find(|l| l.contains("VGA compatible controller"))
        .unwrap_or("")
        .to_string()
}

fn failed_units() -> String {
    cmd_output(
        "systemctl",
        &["list-units", "--failed", "--no-legend", "--plain"],
    )
}

fn mem_available_kb() -> String {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|l| l.starts_with("MemAvailable:"))
                .map(|l| l.split_whitespace().nth(1).unwrap_or("").to_string())
        })
        .unwrap_or_default()
}

/// Minimal JSON string escaping — good enough for the plain command output we feed
/// it here (no control characters expected), not a general-purpose JSON encoder.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
