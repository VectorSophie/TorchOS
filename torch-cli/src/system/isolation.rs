use crate::commands::lab::get_lab_path;
use anyhow::{Context, Result};
use std::process::Command;

pub fn enter_isolated(name: &str) -> Result<()> {
    let lab_path = get_lab_path(name);

    if !lab_path.exists() {
        anyhow::bail!("Lab '{}' does not exist", name);
    }

    println!("Entering isolated lab '{}' via systemd-nspawn...", name);

    let mut cmd = Command::new("systemd-nspawn");
    cmd.arg("--quiet")
        .arg("--directory")
        .arg(&lab_path)
        .arg("--machine")
        .arg(name)
        .arg("--bind")
        .arg("/torch-data/datasets:/data/datasets")
        .arg("--bind")
        .arg("/torch-data/models:/data/models");

    let status = cmd
        .status()
        .context("Failed to execute systemd-nspawn. Is systemd-container installed?")?;

    if !status.success() {
        anyhow::bail!("Lab session exited with error code: {:?}", status.code());
    }

    Ok(())
}
