use serde::Serialize;
use std::path::Path;
use std::process::Command;

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    Warn,
    Fail,
}

#[derive(Serialize, Clone, Debug)]
pub struct Check {
    pub name: &'static str,
    pub level: Level,
    pub detail: String,
}

fn check(name: &'static str, level: Level, detail: impl Into<String>) -> Check {
    Check { name, level, detail: detail.into() }
}

/// Run a command with a C locale so output is parseable regardless of user language.
pub fn out(cmd: &str, args: &[&str]) -> Option<String> {
    let o = Command::new(cmd).args(args).env("LC_ALL", "C").output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

pub fn unit_active(name: &str) -> bool {
    Command::new("systemctl").args(["is-active", "--quiet", name]).status().is_ok_and(|s| s.success())
}

pub fn unit_enabled(name: &str) -> bool {
    Command::new("systemctl").args(["is-enabled", "--quiet", name]).status().is_ok_and(|s| s.success())
}

/// Names of failed systemd units (`--plain --no-legend` lines start with the unit name).
pub fn parse_failed_units(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| l.trim_start_matches(['●', '*', ' ']).split_whitespace().next())
        .map(String::from)
        .collect()
}

/// `KEY=value` / `KEY="value"` pairs from os-release.
pub fn parse_os_release(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_string(), v.trim().trim_matches('"').to_string()))
        .collect()
}

pub fn os_release_field(key: &str) -> Option<String> {
    let text = std::fs::read_to_string("/etc/os-release").ok()?;
    parse_os_release(&text).into_iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// Installed kernel package names (pkgbase), e.g. ["linux", "linux-lts"].
pub fn installed_kernels() -> Vec<String> {
    let Ok(dir) = std::fs::read_dir("/usr/lib/modules") else { return vec![] };
    let mut v: Vec<String> = dir
        .flatten()
        .filter_map(|e| std::fs::read_to_string(e.path().join("pkgbase")).ok())
        .map(|s| s.trim().to_string())
        .collect();
    v.sort();
    v.dedup();
    v
}

pub fn supported() -> bool {
    Path::new("/run/systemd/system").exists()
}

pub fn collect() -> Vec<Check> {
    let mut c = Vec::new();

    let id = os_release_field("ID").unwrap_or_default();
    c.push(if id == "torchos" {
        check("os-release", Level::Ok, "ID=torchos")
    } else {
        check("os-release", Level::Warn, format!("ID={id:?}, not a TorchOS install"))
    });

    let fstype = out("findmnt", &["-no", "FSTYPE", "/"]).unwrap_or_default();
    c.push(if fstype == "btrfs" {
        check("root filesystem", Level::Ok, "btrfs")
    } else {
        check("root filesystem", Level::Warn, format!("{fstype:?}: no snapshot-based recovery"))
    });

    c.push(if Path::new("/etc/snapper/configs/root").exists() {
        check("snapper", Level::Ok, "root config present")
    } else {
        check("snapper", Level::Warn, "no root config")
    });

    c.push(if unit_enabled("grub-btrfs.path") {
        check("boot-menu snapshots", Level::Ok, "grub-btrfs.path enabled")
    } else {
        check("boot-menu snapshots", Level::Warn, "grub-btrfs.path not enabled")
    });

    let kernels = installed_kernels();
    c.push(if kernels.len() >= 2 {
        check("fallback kernel", Level::Ok, kernels.join(", "))
    } else {
        check("fallback kernel", Level::Warn, format!("only {kernels:?} installed"))
    });

    c.push(if unit_active("NetworkManager") {
        check("network", Level::Ok, "NetworkManager active")
    } else {
        check("network", Level::Fail, "NetworkManager not active")
    });

    c.push(if unit_active("torchd") {
        check("torchd", Level::Ok, "active")
    } else {
        check("torchd", Level::Warn, "not active: torch update/snapshot/service will not work")
    });

    let failed = parse_failed_units(&out("systemctl", &["list-units", "--failed", "--no-legend", "--plain"]).unwrap_or_default());
    c.push(if failed.is_empty() {
        check("systemd units", Level::Ok, "none failed")
    } else {
        check("systemd units", Level::Fail, format!("failed: {}", failed.join(", ")))
    });

    if let Some(df) = out("df", &["--output=pcent", "/"]) {
        let pct: u32 = df.lines().nth(1).and_then(|l| l.trim().trim_end_matches('%').parse().ok()).unwrap_or(0);
        c.push(if pct < 90 {
            check("disk space", Level::Ok, format!("{pct}% used"))
        } else {
            check("disk space", Level::Warn, format!("{pct}% used: snapshots need headroom"))
        });
    }
    c
}

pub fn exit_code(checks: &[Check]) -> u8 {
    u8::from(checks.iter().any(|c| c.level != Level::Ok))
}

pub fn run(json: bool) -> anyhow::Result<u8> {
    if !supported() {
        eprintln!("torch doctor: this environment has no systemd; unsupported");
        return Ok(2);
    }
    let checks = collect();
    if json {
        println!("{}", serde_json::to_string_pretty(&checks)?);
    } else {
        println!("TorchOS doctor\n");
        for ch in &checks {
            let mark = match ch.level {
                Level::Ok => "OK  ",
                Level::Warn => "WARN",
                Level::Fail => "FAIL",
            };
            println!("[{mark}] {:<20} {}", ch.name, ch.detail);
        }
    }
    Ok(exit_code(&checks))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_units_parse_names_only() {
        let t = "● foo.service loaded failed failed Foo\n  bar.mount loaded failed failed Bar\n";
        assert_eq!(parse_failed_units(t), ["foo.service", "bar.mount"]);
        assert!(parse_failed_units("").is_empty());
    }

    #[test]
    fn os_release_strips_quotes() {
        let kv = parse_os_release("ID=torchos\nNAME=\"Torch OS\"\n# c\n");
        assert!(kv.contains(&("ID".into(), "torchos".into())));
        assert!(kv.contains(&("NAME".into(), "Torch OS".into())));
    }

    #[test]
    fn any_warn_or_fail_is_nonzero_exit() {
        let ok = check("a", Level::Ok, "");
        let warn = check("b", Level::Warn, "");
        assert_eq!(exit_code(&[ok.clone()]), 0);
        assert_eq!(exit_code(&[ok, warn]), 1);
    }
}
