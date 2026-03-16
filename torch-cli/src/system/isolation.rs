use crate::commands::lab::get_lab_path;
use anyhow::{Context, Result};
use std::path::Path;
use std::process::Command;

pub fn enter_isolated(name: &str, args: Vec<String>) -> Result<()> {
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

    if Path::new("/dev/nvidiactl").exists() {
        cmd.arg("--bind").arg("/dev/nvidiactl");
        cmd.arg("--bind").arg("/dev/nvidia0");
        cmd.arg("--bind").arg("/dev/nvidia-uvm");
        cmd.arg("--bind").arg("/dev/nvidia-uvm-tools");
    }

    if Path::new("/dev/dri").exists() {
        cmd.arg("--bind").arg("/dev/dri");
    }

    if !args.is_empty() {
        for arg in args {
            cmd.arg(arg);
        }
    }

    let status = cmd
        .status()
        .context("Failed to execute systemd-nspawn. Is systemd-container installed?")?;

    if !status.success() {
        anyhow::bail!("Lab session exited with error code: {:?}", status.code());
    }

    Ok(())
}
