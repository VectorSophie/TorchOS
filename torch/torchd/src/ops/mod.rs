use anyhow::{bail, Result};

pub mod kernel;
pub mod package;
pub mod service;
pub mod snapshot;

// Trust boundary: every name/id below ends up as a CLI argument to a root
// process. Reject anything that could be parsed as an option or that has
// characters outside what package/unit names/snapshot ids actually use.
pub fn check_name(name: &str) -> Result<()> {
    let ok = !name.is_empty()
        && !name.starts_with('-')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "@._+-:".contains(c));
    if !ok {
        bail!("invalid name: {name:?}");
    }
    Ok(())
}

/// What a confirmation prompt shows the human: the concrete action, not just the op name.
pub fn describe(op: &str, args: &serde_json::Value) -> String {
    let s = |k: &str| args[k].as_str().unwrap_or("?").to_string();
    match op {
        "snapshot.rollback" => format!(
            "Roll the system back to snapshot {}? /home is kept; the current system is kept as @.pre-rollback-*. Takes effect on reboot.",
            s("snapshot_id")
        ),
        "service.restart" => format!("Restart the service {}?", s("name")),
        "package.remove" => format!("Remove packages: {}?", args["names"]),
        "package.install_file" => format!(
            "Install the local package file {} as root? Its install scripts run with full privileges.",
            s("path")
        ),
        "kernel.install" => format!(
            "Install the {} kernel? A checkpoint is taken first and GRUB is regenerated; the current kernels stay.",
            s("name")
        ),
        other => format!("{other} requires confirmation"),
    }
}

#[cfg(test)]
mod tests {
    use super::check_name;

    #[test]
    fn rejects_option_injection_and_junk() {
        for bad in ["", "--root=/x", "-S", "a b", "a;b", "$(x)", "a/b"] {
            assert!(check_name(bad).is_err(), "{bad:?} should be rejected");
        }
        for good in ["tree", "lib32-mesa", "sshd.service", "getty@tty1.service", "12", "g++"] {
            assert!(check_name(good).is_ok(), "{good:?} should pass");
        }
    }
}
