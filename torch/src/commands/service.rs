use anyhow::Result;

use crate::torchd_client;

pub fn restart(name: &str) -> Result<()> {
    println!("{}", torchd_client::call("service.restart", serde_json::json!({"name": name}))?);
    Ok(())
}
