use anyhow::{bail, Context, Result};
use std::process::Command;

// PHASE 1 NOTE: wraps `snapper` directly. Phase 2's torchd owns snapshot.rollback as
// its one hand-built operation class (see CLAUDE.md's Gotchas — no systemd/Snapper
// D-Bus API exists for this); this command should route through torchd once it
// exists rather than continue shelling out with root-adjacent snapper permissions.

fn run_snapper(args: &[&str]) -> Result<std::process::ExitStatus> {
    Command::new("snapper")
        .args(args)
        .status()
        .context("couldn't run snapper — is it installed? (`torch doctor` checks this)")
}

pub fn list() -> Result<()> {
    let status = run_snapper(&["-c", "root", "list"])?;
    if !status.success() {
        bail!("snapper list failed — is snapper configured for 'root'? (torch doctor checks this)");
    }
    Ok(())
}

pub fn create(description: &str) -> Result<()> {
    println!("Creating checkpoint: {description}");
    let status = run_snapper(&[
        "-c",
        "root",
        "create",
        "-d",
        description,
        "-u",
        "important=yes",
    ])?;
    if !status.success() {
        bail!("snapper create failed");
    }
    println!("Checkpoint created. Run `torch snapshot list` to see it.");
    Ok(())
}
