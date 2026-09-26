use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct CreateArgs {
    description: String,
}

#[derive(Deserialize)]
struct RollbackArgs {
    snapshot_id: String,
}

pub fn create(args: &serde_json::Value) -> Result<String> {
    let args: CreateArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.create")?;
    let status = Command::new("snapper")
        .args(["-c", "root", "create", "-d", &args.description, "-u", "important=yes"])
        .status()
        .context("running snapper create")?;
    if !status.success() {
        bail!("snapper create failed");
    }
    Ok(format!("snapshot created: {}", args.description))
}

// `snapper rollback` only understands SUSE-style layouts (default-subvolume switching). TorchOS mounts
// subvol=/@ explicitly and keeps snapshots in a *separate* @snapshots subvolume (mounted at /.snapshots),
// so a rollback is: build a writable copy of the chosen snapshot, then swap it in as `@` on the top-level
// filesystem. The running system keeps using the old (renamed) subvolume until the next reboot.
// Layout rationale: docs/decisions/btrfs-layout.md.
const TOP_MOUNT: &str = "/run/torchd/top";

/// Snapshot ids are plain integers; anything else never reaches a path.
pub fn parse_snapshot_id(id: &str) -> Result<u32> {
    id.parse::<u32>().ok().filter(|n| *n > 0).context("snapshot id must be a positive integer")
}

/// `findmnt -no SOURCE /` prints `/dev/vda2[/@]`; the device is what precedes the bracket.
pub fn device_from_findmnt(source: &str) -> Option<&str> {
    let dev = source.split('[').next()?.trim();
    dev.starts_with("/dev/").then_some(dev)
}

fn run(cmd: &str, args: &[&str]) -> Result<()> {
    let out = Command::new(cmd).args(args).output().with_context(|| format!("running {cmd}"))?;
    if !out.status.success() {
        bail!("{cmd} {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

pub fn rollback(args: &serde_json::Value) -> Result<String> {
    let args: RollbackArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.rollback")?;
    let id = parse_snapshot_id(&args.snapshot_id)?;
    let src = format!("/.snapshots/{id}/snapshot");
    if !std::path::Path::new(&src).is_dir() {
        bail!("snapshot {id} not found at {src}");
    }
    let root = Command::new("findmnt").args(["-no", "SOURCE", "/"]).output().context("findmnt")?;
    let root = String::from_utf8_lossy(&root.stdout);
    let dev = device_from_findmnt(root.trim()).context("cannot determine the root device")?.to_string();

    std::fs::create_dir_all(TOP_MOUNT)?;
    run("mount", &["-o", "subvolid=5", &dev, TOP_MOUNT])?;
    let result = swap_in(&src, id);
    let _ = run("umount", &[TOP_MOUNT]);
    result
}

fn swap_in(src: &str, id: u32) -> Result<String> {
    let ts = String::from_utf8_lossy(&Command::new("date").args(["-u", "+%Y%m%dT%H%M%SZ"]).output()?.stdout)
        .trim()
        .to_string();
    let (new, cur, old) = (
        format!("{TOP_MOUNT}/@.rollback-new"),
        format!("{TOP_MOUNT}/@"),
        format!("{TOP_MOUNT}/@.pre-rollback-{ts}"),
    );
    // 1. Build the replacement first: if this fails, nothing has changed.
    run("btrfs", &["subvolume", "snapshot", src, &new])?;
    // 2. Swap. If the second rename fails, put the original back.
    if let Err(e) = std::fs::rename(&cur, &old) {
        let _ = run("btrfs", &["subvolume", "delete", &new]);
        bail!("could not move the current root aside: {e}");
    }
    if let Err(e) = std::fs::rename(&new, &cur) {
        let _ = std::fs::rename(&old, &cur);
        bail!("could not install the snapshot as @ (original restored): {e}");
    }
    Ok(format!(
        "rollback to snapshot {id} prepared: reboot to complete it. The previous system is kept as @.pre-rollback-{ts}; /home, logs and caches are unchanged"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_ids_are_positive_integers_only() {
        assert_eq!(parse_snapshot_id("12").unwrap(), 12);
        for bad in ["0", "-1", "1/../..", "abc", "", "1 2", "../@"] {
            assert!(parse_snapshot_id(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn device_is_taken_from_findmnt_source() {
        assert_eq!(device_from_findmnt("/dev/vda2[/@]"), Some("/dev/vda2"));
        assert_eq!(device_from_findmnt("/dev/nvme0n1p2"), Some("/dev/nvme0n1p2"));
        assert_eq!(device_from_findmnt("overlay"), None);
    }
}
