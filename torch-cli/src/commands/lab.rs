use crate::system::btrfs;
use crate::types::lab::LabMetadata;
use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};

pub const LABS_DIR: &str = "/torch/labs";
pub const BASE_LAB: &str = "/torch/base-lab";

pub fn create(name: &str) -> Result<()> {
    let lab_path = get_lab_path(name);

    if lab_path.exists() {
        anyhow::bail!("Lab '{}' already exists", name);
    }

    println!("Creating lab '{}'...", name);
    btrfs::create_snapshot(Path::new(BASE_LAB), &lab_path)?;

    let metadata = LabMetadata::new(name.to_string(), "base-lab".to_string());
    let toml_str = toml::to_string(&metadata).context("Failed to serialize metadata")?;
    fs::write(lab_path.join("lab.toml"), toml_str).context("Failed to write lab.toml")?;

    println!("Lab '{}' created successfully.", name);
    Ok(())
}

pub fn delete(name: &str) -> Result<()> {
    let lab_path = get_lab_path(name);
    if !lab_path.exists() {
        anyhow::bail!("Lab '{}' does not exist", name);
    }

    println!("Deleting lab '{}'...", name);
    btrfs::delete_subvolume(&lab_path)?;
    Ok(())
}

pub fn reset(name: &str) -> Result<()> {
    let lab_path = get_lab_path(name);
    if !lab_path.exists() {
        anyhow::bail!("Lab '{}' does not exist", name);
    }

    println!("Resetting lab '{}'...", name);
    btrfs::delete_subvolume(&lab_path)?;
    btrfs::create_snapshot(Path::new(BASE_LAB), &lab_path)?;

    let metadata = LabMetadata::new(name.to_string(), "base-lab".to_string());
    let toml_str = toml::to_string(&metadata).context("Failed to serialize metadata")?;
    fs::write(lab_path.join("lab.toml"), toml_str).context("Failed to write lab.toml")?;

    println!("Lab '{}' reset to original state.", name);
    Ok(())
}

pub fn commit(name: &str) -> Result<()> {
    let lab_path = get_lab_path(name);
    let base_path = Path::new(BASE_LAB);

    if !lab_path.exists() {
        anyhow::bail!("Lab '{}' does not exist", name);
    }

    println!("Committing changes from lab '{}' to base-lab...", name);

    if !base_path.exists() {
        anyhow::bail!("Base-lab not found at {}. Cannot commit.", BASE_LAB);
    }

    let tmp_base = Path::new("/torch/base-lab-tmp");
    if tmp_base.exists() {
        btrfs::delete_subvolume(tmp_base)?;
    }

    btrfs::create_snapshot(&lab_path, tmp_base)?;
    btrfs::delete_subvolume(base_path)?;
    fs::rename(tmp_base, base_path).context("Failed to promote lab to base-lab")?;

    println!("Lab '{}' has been committed as the new base-lab.", name);
    Ok(())
}

pub fn list() -> Result<()> {
    let labs_dir = Path::new(LABS_DIR);
    if !labs_dir.exists() {
        println!("No labs found.");
        return Ok(());
    }

    println!("Torch Labs:");
    for entry in fs::read_dir(labs_dir).context("Failed to read labs directory")? {
        let entry = entry?;
        if entry.path().is_dir() {
            if let Some(name) = entry.file_name().to_str() {
                println!("  - {}", name);
            }
        }
    }
    Ok(())
}

pub fn info(name: &str) -> Result<()> {
    let lab_path = get_lab_path(name);
    let meta_path = lab_path.join("lab.toml");

    if !meta_path.exists() {
        anyhow::bail!("Metadata for lab '{}' not found", name);
    }

    let content = fs::read_to_string(meta_path)?;
    let metadata: LabMetadata = toml::from_str(&content)?;

    println!("Lab: {}", metadata.name);
    println!("Created: {}", metadata.created);
    println!("Base snapshot: {}", metadata.base);

    Ok(())
}

pub fn get_lab_path(name: &str) -> PathBuf {
    Path::new(LABS_DIR).join(name)
}
