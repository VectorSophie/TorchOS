use super::check_name;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct ServiceArgs {
    name: String,
}

pub fn restart(args: &serde_json::Value) -> Result<String> {
    let args: ServiceArgs = serde_json::from_value(args.clone()).context("bad args for service.restart")?;
    check_name(&args.name)?;
    let status = Command::new("systemctl")
        .args(["restart", "--", &args.name])
        .status()
        .context("running systemctl restart")?;
    if !status.success() {
        bail!("systemctl restart {} failed", args.name);
    }
    Ok(format!("restarted: {}", args.name))
}
