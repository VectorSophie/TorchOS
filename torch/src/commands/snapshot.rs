use anyhow::{bail, Context, Result};
use std::process::Command;

use crate::torchd_client;

// `list` is an unprivileged read and stays direct; create/rollback go through torchd.

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
    torchd_client::call("snapshot.create", serde_json::json!({"description": description}))?;
    println!("Checkpoint created. Run `torch snapshot list` to see it.");
    Ok(())
}

pub fn rollback(snapshot_id: &str) -> Result<()> {
    let msg = torchd_client::call("snapshot.rollback", serde_json::json!({"snapshot_id": snapshot_id}))?;
    println!("{msg}");
    Ok(())
}
