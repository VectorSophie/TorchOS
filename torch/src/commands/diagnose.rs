use super::doctor::{self, collect, out, parse_failed_units};
use serde_json::json;

/// GPUs from `lspci -mm` (machine-readable, quoted fields: slot "class" "vendor" "device" ...).
pub fn parse_lspci_mm(text: &str) -> Vec<serde_json::Value> {
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('"').collect(); // [slot, ' ', class, ' ', vendor, ' ', device, ...]
            let class = f.get(1)?;
            let (vendor, device) = (f.get(3)?, f.get(5)?);
            (class.contains("VGA") || class.contains("3D") || class.contains("Display"))
                .then(|| json!({"slot": f[0].trim(), "class": class, "vendor": vendor, "device": device}))
        })
        .collect()
}

pub fn run() -> anyhow::Result<u8> {
    let checks = collect();
    let mem_kb: Option<u64> = std::fs::read_to_string("/proc/meminfo").ok().and_then(|t| {
        t.lines().find(|l| l.starts_with("MemAvailable:"))?.split_whitespace().nth(1)?.parse().ok()
    });
    let doc = json!({
        "schema": 1,
        "os": {
            "id": doctor::os_release_field("ID"),
            "name": doctor::os_release_field("PRETTY_NAME"),
        },
        "kernel": out("uname", &["-r"]),
        "kernels_installed": doctor::installed_kernels(),
        "hostname": std::fs::read_to_string("/etc/hostname").ok().map(|s| s.trim().to_string()),
        "boot_mode": if std::path::Path::new("/sys/firmware/efi").exists() { "uefi" } else { "bios" },
        "root_fstype": out("findmnt", &["-no", "FSTYPE", "/"]),
        "gpus": parse_lspci_mm(&out("lspci", &["-mm"]).unwrap_or_default()),
        "failed_units": parse_failed_units(&out("systemctl", &["list-units", "--failed", "--no-legend", "--plain"]).unwrap_or_default()),
        "mem_available_kb": mem_kb,
        "checks": checks,
    });
    println!("{}", serde_json::to_string_pretty(&doc)?);
    Ok(doctor::exit_code(&checks))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lspci_mm_finds_gpu_only() {
        let t = "00:00.0 \"Host bridge\" \"Intel\" \"440FX\" -p00 \"RH\" \"QEMU\"\n\
                 00:02.0 \"VGA compatible controller\" \"Red Hat, Inc.\" \"Virtio 1.0 GPU\" -r01 \"RH\" \"QEMU\"\n";
        let g = parse_lspci_mm(t);
        assert_eq!(g.len(), 1);
        assert_eq!(g[0]["vendor"], "Red Hat, Inc.");
    }
}
