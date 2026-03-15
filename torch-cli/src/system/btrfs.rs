use anyhow::{bail, Context, Result};
use std::path::Path;
use std::process::Command;

pub fn is_btrfs(path: &Path) -> Result<bool> {
    let output = Command::new("stat")
        .args(["-f", "-c", "%T", path.to_str().context("Invalid path")?])
        .output()
        .context("Failed to run stat")?;

    if !output.status.success() {
        bail!("Failed to determine filesystem type for {:?}", path);
    }

    let fs_type = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(fs_type == "btrfs")
}

pub fn create_subvolume(path: &Path) -> Result<()> {
    let output = Command::new("btrfs")
        .args([
            "subvolume",
            "create",
            path.to_str().context("Invalid path")?,
        ])
        .output()
        .context("Failed to execute btrfs subvolume create")?;

    if !output.status.success() {
        bail!(
            "Btrfs subvolume create failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

pub fn create_snapshot(base: &Path, dest: &Path) -> Result<()> {
    let output = Command::new("btrfs")
        .args([
            "subvolume",
            "snapshot",
            base.to_str().context("Invalid base path")?,
            dest.to_str().context("Invalid destination path")?,
        ])
        .output()
        .context("Failed to execute btrfs snapshot")?;

    if !output.status.success() {
        bail!(
            "Btrfs snapshot failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

pub fn delete_subvolume(path: &Path) -> Result<()> {
    let output = Command::new("btrfs")
        .args([
            "subvolume",
            "delete",
            path.to_str().context("Invalid path")?,
        ])
        .output()
        .context("Failed to execute btrfs delete")?;

    if !output.status.success() {
        bail!(
            "Btrfs delete failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}
