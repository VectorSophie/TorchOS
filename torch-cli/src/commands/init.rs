use crate::system::btrfs;
use anyhow::{Context, Result};
use std::fs;
use std::path::Path;

pub const TORCH_ROOT: &str = "/torch";
pub const BASE_LAB: &str = "/torch/base-lab";
pub const LABS_DIR: &str = "/torch/labs";
pub const DATASETS_DIR: &str = "/torch-data/datasets";
pub const MODELS_DIR: &str = "/torch-data/models";
pub const RESULTS_DIR: &str = "/torch-data/results";

pub fn run_init() -> Result<()> {
    println!("Initializing Torch OS environment...");

    let root = Path::new("/");
    if !btrfs::is_btrfs(root)? {
        anyhow::bail!("Root filesystem is not Btrfs. Torch OS requires Btrfs for lab snapshots.");
    }

    let dirs = [TORCH_ROOT, LABS_DIR, DATASETS_DIR, MODELS_DIR, RESULTS_DIR];

    for dir in dirs {
        if !Path::new(dir).exists() {
            fs::create_dir_all(dir)
                .with_context(|| format!("Failed to create directory: {}", dir))?;
            println!("Created directory: {}", dir);
        }
    }

    let base_lab_path = Path::new(BASE_LAB);
    if !base_lab_path.exists() {
        btrfs::create_subvolume(base_lab_path)?;
        println!("Created base-lab subvolume: {}", BASE_LAB);
    } else {
        println!("Base-lab already exists.");
    }

    // 2. Create directories
    let dirs = [TORCH_ROOT, LABS_DIR, DATASETS_DIR, MODELS_DIR, RESULTS_DIR];

    for dir in dirs {
        if !Path::new(dir).exists() {
            fs::create_dir_all(dir)
                .with_context(|| format!("Failed to create directory: {}", dir))?;
            println!("Created directory: {}", dir);
        }
    }

    // 3. Create base-lab subvolume
    let base_lab_path = Path::new(BASE_LAB);
    if !base_lab_path.exists() {
        btrfs::create_subvolume(base_lab_path)?;
        println!("Created base-lab subvolume: {}", BASE_LAB);
    } else {
        println!("Base-lab already exists.");
    }

    println!("Torch OS initialization complete.");
    Ok(())
}
