use anyhow::Result;
use std::process::Command;

pub fn run() -> Result<()> {
    println!("TorchOS status\n");

    run_and_print("Hostname", "hostnamectl", &["hostname"]);
    run_and_print("Uptime", "uptime", &["-p"]);
    run_and_print("Kernel", "uname", &["-r"]);

    println!();
    println!("Disk (/):");
    let _ = Command::new("df")
        .args(["-h", "/"])
        .status()
        .map_err(|e| eprintln!("  (df failed: {e})"));

    println!();
    println!("Memory:");
    let _ = Command::new("free")
        .args(["-h"])
        .status()
        .map_err(|e| eprintln!("  (free failed: {e})"));

    Ok(())
}

fn run_and_print(label: &str, cmd: &str, args: &[&str]) {
    match Command::new(cmd).args(args).output() {
        Ok(out) if out.status.success() => {
            let text = String::from_utf8_lossy(&out.stdout);
            println!("{label}: {}", text.trim());
        }
        _ => println!("{label}: (unavailable)"),
    }
}
