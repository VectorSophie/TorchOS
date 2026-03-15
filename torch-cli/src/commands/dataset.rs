use anyhow::Result;
use std::fs;
use std::path::Path;

const DATASETS_DIR: &str = "/torch-data/datasets";
const MODELS_DIR: &str = "/torch-data/models";

pub fn list_datasets() -> Result<()> {
    println!("Available Datasets:");
    list_dir(DATASETS_DIR)
}

pub fn list_models() -> Result<()> {
    println!("Stored Models:");
    list_dir(MODELS_DIR)
}

fn list_dir(path: &str) -> Result<()> {
    let p = Path::new(path);
    if !p.exists() {
        println!("  (directory missing)");
        return Ok(());
    }

    for entry in fs::read_dir(p)? {
        let entry = entry?;
        println!("  - {}", entry.file_name().to_string_lossy());
    }
    Ok(())
}
