use anyhow::Result;
use std::process::Command;

pub fn get_gpu_status() -> Result<()> {
    let output = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.total,driver_version",
            "--format=csv,noheader,nounits",
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            for line in stdout.lines() {
                let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
                if parts.len() >= 3 {
                    println!("GPU: {}", parts[0]);
                    println!("VRAM: {} MB", parts[1]);
                    println!("Driver: {}", parts[2]);
                    println!("CUDA: available");
                }
            }
        }
        _ => {
            println!("No compatible GPU detected.");
        }
    }

    Ok(())
}
