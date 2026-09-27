use anyhow::Result;

use crate::torchd_client;

pub fn run(packages: &[String]) -> Result<()> {
    if packages.is_empty() {
        println!("Upgrading the system (a snapshot pair is taken automatically)...");
        println!("{}", torchd_client::call("system.upgrade", serde_json::Value::Null)?);
        return Ok(());
    }
    println!("Installing: {}", packages.join(", "));
    println!("{}", torchd_client::call("package.install", serde_json::json!({"names": packages}))?);
    Ok(())
}

pub fn remove(packages: &[String]) -> Result<()> {
    println!("{}", torchd_client::call("package.remove", serde_json::json!({"names": packages}))?);
    Ok(())
}
