use super::check_name;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct CreateArgs {
    description: String,
}

#[derive(Deserialize)]
struct RollbackArgs {
    snapshot_id: String,
}

pub fn create(args: &serde_json::Value) -> Result<String> {
    let args: CreateArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.create")?;
    let status = Command::new("snapper")
        .args(["-c", "root", "create", "-d", &args.description, "-u", "important=yes"])
        .status()
        .context("running snapper create")?;
    if !status.success() {
        bail!("snapper create failed");
    }
    Ok(format!("snapshot created: {}", args.description))
}

// snapper rollback is NOT instant — it creates a new snapshot pair and sets
// the target as the default subvolume for the *next boot*. Message the
// caller honestly rather than implying this takes effect immediately.
pub fn rollback(args: &serde_json::Value) -> Result<String> {
    let args: RollbackArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.rollback")?;
    check_name(&args.snapshot_id)?;
    let status = Command::new("snapper")
        .args(["-c", "root", "rollback", &args.snapshot_id])
        .status()
        .context("running snapper rollback")?;
    if !status.success() {
        bail!("snapper rollback failed");
    }
    Ok(format!(
        "rollback to snapshot {} prepared — reboot to complete it",
        args.snapshot_id
    ))
}
