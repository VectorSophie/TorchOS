use anyhow::Result;
use std::path::Path;
use std::process::Command;

// PHASE 1 NOTE: this is a small, real set of checks (not a stub) but it's not the
// full structured-diagnostics layer the design calls for. It shells out and greps
// text today; a later phase should have `torchd` expose these as typed queries so
// the AI assistant can consume structured data instead of re-parsing this output.

pub fn run() -> Result<()> {
    println!("TorchOS doctor\n");

    check("Root filesystem is Btrfs", is_btrfs_root());
    check("Snapper is configured for root", snapper_configured());
    check("NetworkManager is active", service_active("NetworkManager"));
    check("sshd is active", service_active("sshd"));

    Ok(())
}

fn check(label: &str, ok: bool) {
    let mark = if ok { "OK" } else { "FAIL" };
    println!("[{mark}] {label}");
}

fn is_btrfs_root() -> bool {
    Command::new("findmnt")
        .args(["-no", "FSTYPE", "/"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "btrfs")
        .unwrap_or(false)
}

fn snapper_configured() -> bool {
    Path::new("/etc/snapper/configs/root").exists()
}

fn service_active(name: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", name])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
