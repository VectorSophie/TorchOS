use anyhow::Result;

use super::doctor::out;

/// Highest x86-64 micro-architecture level glibc's loader reports as "supported" (v2/v3/v4).
pub fn parse_x86_level(ld_help: &str) -> Option<String> {
    ld_help
        .lines()
        .filter(|l| l.contains("(supported, searched)"))
        .filter_map(|l| l.split_whitespace().next())
        .filter(|w| w.starts_with("x86-64-v"))
        .max()
        .map(String::from)
}

/// (device line, kernel driver in use) for display controllers in `lspci -k` output.
pub fn parse_gpu_drivers(lspci_k: &str) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = Vec::new();
    for l in lspci_k.lines() {
        if !l.starts_with(char::is_whitespace) {
            if ["VGA", "3D controller", "Display controller"].iter().any(|k| l.contains(k)) {
                v.push((l.split_once(": ").map_or(l, |x| x.1).to_string(), "none".into()));
            }
        } else if let (Some(last), Some(d)) = (v.last_mut(), l.trim().strip_prefix("Kernel driver in use: ")) {
            if last.1 == "none" {
                last.1 = d.to_string();
            }
        }
    }
    v
}

fn advice(device: &str, driver: &str) -> &'static str {
    let d = device.to_lowercase();
    if d.contains("nvidia") {
        "NVIDIA is untested on TorchOS; nvidia-open is the path to try"
    } else if d.contains("intel") && driver == "xe" {
        "Xe driver (opt-in on TorchOS; i915 is the default)"
    } else if d.contains("intel") {
        "i915 is the TorchOS default; Xe is opt-in for Lunar Lake/Battlemage-class hardware"
    } else {
        ""
    }
}

fn secure_boot() -> &'static str {
    let Ok(dir) = std::fs::read_dir("/sys/firmware/efi/efivars") else { return "n/a (BIOS boot)" };
    let Some(var) = dir.flatten().find(|e| e.file_name().to_string_lossy().starts_with("SecureBoot-")) else {
        return "disabled (firmware has no Secure Boot support)";
    };
    // efivar layout: 4 attribute bytes, then the value byte.
    match std::fs::read(var.path()).ok().and_then(|b| b.get(4).copied()) {
        Some(1) => "enabled",
        Some(_) => "disabled",
        None => "unknown",
    }
}

pub fn run() -> Result<()> {
    let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let cpu = cpuinfo.lines().find_map(|l| l.strip_prefix("model name")).map(|s| s.trim_start_matches([' ', '\t', ':']));
    let cores = cpuinfo.lines().filter(|l| l.starts_with("processor")).count();
    let level = out("/lib/ld-linux-x86-64.so.2", &["--help"]).and_then(|t| parse_x86_level(&t));
    println!("CPU:        {} ({cores} threads)", cpu.unwrap_or("unknown"));
    println!("ISA level:  {}", level.as_deref().unwrap_or("unknown"));
    let mem = std::fs::read_to_string("/proc/meminfo").ok().and_then(|t| {
        t.lines().find(|l| l.starts_with("MemTotal:"))?.split_whitespace().nth(1)?.parse::<u64>().ok()
    });
    println!("Memory:     {}", mem.map_or("unknown".into(), |kb| format!("{:.1} GiB", kb as f64 / 1048576.0)));
    let boot = if std::path::Path::new("/sys/firmware/efi").exists() { "UEFI" } else { "BIOS" };
    println!("Firmware:   {boot}, Secure Boot {}", secure_boot());

    let gpus = parse_gpu_drivers(&out("lspci", &["-k"]).unwrap_or_default());
    if gpus.is_empty() {
        println!("GPU:        none detected (is pciutils installed?)");
    }
    for (dev, drv) in gpus {
        println!("GPU:        {dev}\n            driver: {drv}  {}", advice(&dev, &drv));
    }
    println!("\nDisks:");
    let _ = std::process::Command::new("lsblk").args(["-d", "-e1,7,11", "-o", "NAME,SIZE,MODEL,TRAN,ROTA"]).status();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isa_level_is_highest_supported() {
        let t = "Subdirectories of glibc-hwcaps directories, in priority order:\n  x86-64-v4\n  x86-64-v3 (supported, searched)\n  x86-64-v2 (supported, searched)\n";
        assert_eq!(parse_x86_level(t).as_deref(), Some("x86-64-v3"));
        assert_eq!(parse_x86_level(""), None);
    }

    #[test]
    fn gpu_driver_follows_its_device() {
        let t = "00:01.0 Host bridge: Intel Corp\n\tKernel driver in use: foo\n00:02.0 VGA compatible controller: Intel Corporation Iris Xe\n\tSubsystem: X\n\tKernel driver in use: i915\n\tKernel modules: i915, xe\n01:00.0 3D controller: NVIDIA Corporation GA107M\n";
        let g = parse_gpu_drivers(t);
        assert_eq!(g, vec![
            ("Intel Corporation Iris Xe".to_string(), "i915".to_string()),
            ("NVIDIA Corporation GA107M".to_string(), "none".to_string()),
        ]);
    }
}
