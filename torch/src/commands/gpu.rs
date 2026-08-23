use anyhow::Result;
use std::process::Command;

// PHASE 1 NOTE: v1's gpu_detect.rs shelled to nvidia-smi specifically — wrong vendor
// for TorchOS's actual target (Intel integrated graphics first) and a dead end the
// moment the machine isn't NVIDIA. This checks what's actually there instead of
// assuming a vendor, via `lspci`, which works regardless of GPU make.

pub fn run() -> Result<()> {
    let output = Command::new("lspci").output();

    let Ok(out) = output else {
        println!("lspci not available — cannot detect GPU.");
        return Ok(());
    };

    let text = String::from_utf8_lossy(&out.stdout);
    let gpu_lines: Vec<&str> = text
        .lines()
        .filter(|l| l.contains("VGA compatible controller") || l.contains("3D controller"))
        .collect();

    if gpu_lines.is_empty() {
        println!("No GPU detected via lspci.");
        return Ok(());
    }

    println!("Detected GPU(s):");
    for line in gpu_lines {
        println!("  {line}");
    }

    Ok(())
}
