use anyhow::{bail, Result};

use crate::torchd_client;

pub fn run(packages: &[String]) -> Result<()> {
    if packages.is_empty() {
        bail!("usage: torch update <package>... (full-system upgrade is not wired up yet)");
    }
    println!("Installing: {}", packages.join(", "));
    println!("{}", torchd_client::call("package.install", serde_json::json!({"names": packages}))?);
    Ok(())
}
