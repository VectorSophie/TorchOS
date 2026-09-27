use anyhow::Result;

use super::doctor::{installed_kernels, out};
use crate::torchd_client;

pub fn list() -> Result<()> {
    println!("running:   {}", out("uname", &["-r"]).unwrap_or_default());
    println!("installed: {}", installed_kernels().join(", "));
    println!("available: linux, linux-lts, linux-zen, linux-hardened, linux-cachyos (`torch kernel add <name>`)");
    Ok(())
}

pub fn add(name: &str) -> Result<()> {
    println!("{}", torchd_client::call("kernel.install", serde_json::json!({"name": name}))?);
    Ok(())
}
