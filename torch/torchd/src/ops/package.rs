use super::check_name;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct PackageArgs {
    names: Vec<String>,
}

fn run(flags: &[&str], verb: &str, args: &serde_json::Value) -> Result<String> {
    let args: PackageArgs =
        serde_json::from_value(args.clone()).with_context(|| format!("bad args for package.{verb}"))?;
    if args.names.is_empty() {
        bail!("package.{verb} requires at least one package name");
    }
    args.names.iter().try_for_each(|n| check_name(n))?;
    let status = Command::new("pacman")
        .args(flags)
        .arg("--noconfirm")
        .arg("--")
        .args(&args.names)
        .status()
        .context("running pacman")?;
    if !status.success() {
        bail!("pacman {} failed for: {}", flags[0], args.names.join(", "));
    }
    Ok(format!("{verb}: {}", args.names.join(", ")))
}

pub fn install(args: &serde_json::Value) -> Result<String> {
    run(&["-S", "--needed"], "installed", args)
}

pub fn remove(args: &serde_json::Value) -> Result<String> {
    run(&["-R"], "removed", args)
}
