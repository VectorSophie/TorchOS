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
// filesystem. The running system keeps using the old subvolume until the next reboot.
// Crash safety (docs/decisions/0003-recovery-integrity.md §5): one atomic exchange, so every committed state has
// an `@`; a journal on @log names the subvolumes by UUID; reconciliation acts only on observed UUIDs.
// Layout rationale: docs/decisions/btrfs-layout.md.
use super::recovery::{self, Top};
use crate::journal;
use serde_json::json;

/// A rollback needs metadata space for a new subvolume and two renames; below this it is refused up front.
/// shortcut: a heuristic floor, not a guarantee (§5.5); tune with F9 when R-E adds the space tests.
const METADATA_FLOOR: u64 = 256 << 20;

/// Snapshot ids are plain integers; anything else never reaches a path.
pub fn parse_snapshot_id(id: &str) -> Result<u32> {
    id.parse::<u32>().ok().filter(|n| *n > 0).context("snapshot id must be a positive integer")
}

/// `findmnt -no SOURCE /` prints `/dev/vda2[/@]`; the device is what precedes the bracket.
pub fn device_from_findmnt(source: &str) -> Option<&str> {
    let dev = source.split('[').next()?.trim();
    dev.starts_with("/dev/").then_some(dev)
}

fn utc_compact() -> String {
    String::from_utf8_lossy(
        &Command::new("date").args(["-u", "+%Y%m%dT%H%M%SZ"]).output().map(|o| o.stdout).unwrap_or_default(),
    )
    .trim()
    .to_string()
}

/// Journal writer for one op: every record carries op_id and a sequence number.
struct Op {
    id: String,
    seq: u32,
}
impl Op {
    fn rec(&mut self, mut v: serde_json::Value) -> Result<()> {
        self.seq += 1;
        v["op_id"] = json!(self.id);
        v["seq"] = json!(self.seq);
        v["ts"] = json!(utc_compact());
        journal::append(journal::PATH, &v)
    }
    /// Record an outcome; on failure say so and return the error text (callers report it, never hide it).
    fn outcome(&mut self, result: &str, detail: &str) -> Option<String> {
        let r = json!({"kind": "outcome", "result": result, "detail": detail, "boot_id": recovery::boot_id()});
        let e = self.rec(r).err().map(|e| format!("{e:#}"));
        if let Some(e) = &e {
            eprintln!("journal: could not record outcome {result} for {}: {e}", self.id);
        }
        e
    }
}

pub fn rollback(args: &serde_json::Value) -> Result<String> {
    let args: RollbackArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.rollback")?;
    let id = parse_snapshot_id(&args.snapshot_id)?;
    let src = format!("/.snapshots/{id}/snapshot");
    if !std::path::Path::new(&src).is_dir() {
        bail!("snapshot {id} not found at {src}");
    }
    let root = Command::new("findmnt").args(["-no", "SOURCE", "/"]).output().context("findmnt")?;
    device_from_findmnt(String::from_utf8_lossy(&root.stdout).trim()).context("cannot determine the root device")?;

    // Finish or record whatever an interrupted earlier rollback left, then look at the disk as it is now.
    let rep = recovery::reconcile_all().context("refused: cannot read the state of earlier rollbacks")?;
    rep.notes.iter().for_each(|n| eprintln!("reconcile: {n}"));
    if !rep.errors.is_empty() {
        bail!("refused: an earlier rollback could not be reconciled: {}. Nothing was changed", rep.errors.join("; "));
    }
    let obs = recovery::observe()?;
    let booted = recovery::booted_uuid().context("cannot read the running root's subvolume UUID")?;
    if recovery::pending(&obs, Some(&booted)) {
        bail!("{} (another rollback cannot replace a pending one)", recovery::PENDING_MSG);
    }
    let u0 = obs.get("@").context("no @ subvolume on the top level")?.uuid.clone();
    let src_uuid = recovery::uuid_of(&src).context("cannot read the snapshot's UUID")?;
    recovery::metadata_preflight(
        Command::new("btrfs").args(["filesystem", "usage", "-b", "/.snapshots"]).output(),
        METADATA_FLOOR,
    )?;

    let op_id = format!("r-{}-{}", utc_compact(), &uuid::Uuid::new_v4().simple().to_string()[..6]);
    let (new_name, prev_name) = (format!("@.torchd-{op_id}.new"), format!("@.torchd-{op_id}.prev"));
    let mut op = Op { id: op_id.clone(), seq: 0 };
    let _top = Top::mount()?;
    let (new, cur, prev) = (Top::path(&new_name), Top::path("@"), Top::path(&prev_name));
    if std::path::Path::new(&new).exists() || std::path::Path::new(&prev).exists() {
        bail!("refused: {new_name} or {prev_name} already exists. Nothing was changed");
    }
    // Intent is durable before the first side effect; if it cannot be written, nothing happens.
    op.rec(json!({"kind": "intent", "op": "snapshot.rollback", "snapshot": id, "boot_id": recovery::boot_id(),
        "root_uuid_before": u0, "booted_uuid": booted, "src_uuid": src_uuid, "new_name": new_name,
        "prev_name": prev_name, "torchd_version": crate::VERSION}))
    .context("refused: cannot write the operation journal. Nothing was changed")?;
    fault("intent");

    // 1. The replacement: if this fails, nothing that boots has changed.
    if let Err(e) = run("btrfs", &["subvolume", "snapshot", &src, &new]) {
        op.outcome("failed", &format!("{e:#}"));
        bail!("could not copy snapshot {id}: {e:#}. The current system is unchanged");
    }
    let Some(un) = recovery::uuid_of(&new) else {
        let _ = run("btrfs", &["subvolume", "delete", &new]);
        op.outcome("failed", "cannot read the copy's UUID");
        bail!("could not read the new copy's UUID; nothing was changed");
    };
    if let Err(e) = op.rec(json!({"kind": "step", "step": "created", "new_uuid": un})) {
        // Without this record a crash later would leave less to go on: stop now, before anything boots differently.
        let cleanup = run("btrfs", &["subvolume", "delete", &new]).map(|_| "removed").unwrap_or("left for reconciliation");
        op.outcome("failed", &format!("journal: {e:#}"));
        bail!("could not journal the new copy ({e:#}); nothing was changed (the copy was {cleanup})");
    }
    fault("created");

    // 2. One atomic exchange: @ is the old or the new tree in every committed state, never missing.
    if let Err(e) = recovery::exchange(&new, &cur) {
        let cleanup = run("btrfs", &["subvolume", "delete", &new]).map(|_| "removed").unwrap_or("left for reconciliation");
        op.outcome("failed", &format!("exchange: {e}"));
        bail!("could not swap in the snapshot ({e}); nothing was changed (the copy was {cleanup})");
    }
    // From here @ is the new tree (in memory at least). Journal failures no longer stop anything: reconciliation
    // works from what is on disk. They are collected and reported, never hidden.
    let mut unjournaled = vec![];
    if let Err(e) = op.rec(json!({"kind": "step", "step": "exchanged"})) {
        unjournaled.push(format!("exchanged: {e:#}"));
    }
    fault("exchanged");

    // 3. Give the old root its keep-name. Failing here is harmless: @ is already the new root.
    let kept = match recovery::rename_noreplace(&new, &prev) {
        Ok(()) => {
            if let Err(e) = op.rec(json!({"kind": "step", "step": "renamed"})) {
                unjournaled.push(format!("renamed: {e:#}"));
            }
            prev_name.clone()
        }
        Err(e) => {
            eprintln!("rollback {op_id}: keep-name rename failed ({e}); reconciliation renames it later");
            new_name.clone()
        }
    };
    fault("renamed");

    // 4. Durable before it is reported. Without this a power cut could silently undo the swap.
    if let Err(e) = recovery::sync_fs(super::recovery::TOP_MOUNT) {
        let rec = op.outcome("unknown", &format!("syncfs: {e}")).map_or(String::new(), |j| format!(" (and the journal could not record this: {j})"));
        bail!(
            "the swap was made in memory but could not be committed to disk ({e}){rec}. Reboot: the system starts on \
             either the old or the new root, and torchd reconciles the state when it starts"
        );
    }
    if let Some(e) = op.outcome("prepared", "") {
        unjournaled.push(format!("prepared: {e}"));
    }
    fault("prepared");
    let journal = if unjournaled.is_empty() {
        "recorded in the journal".to_string()
    } else {
        format!(
            "NOT fully recorded in the journal ({}); torchd reconciles it from what is on disk when it next starts",
            unjournaled.join("; ")
        )
    };
    // Claims only what is known now: exchanged and committed. That the new root boots is checked after the reboot.
    Ok(format!(
        "rollback to snapshot {id} prepared: the swap is committed to disk and {journal}. Reboot to complete it; \
         torchd checks that the new root is running when it starts. Until then, package, upgrade and kernel \
         operations are refused. The previous system is kept as {kept}; /home, logs and caches are unchanged"
    ))
}

/// Development-only fault points (docs/decisions/0003-recovery-integrity.md §7.1). `/run/torchd/fault` holds
/// `after:<point>[:sync]`; at that point torchd optionally commits the filesystem, announces PAUSED, and blocks
/// so the test harness can cut the power.
#[cfg(feature = "fault-injection")]
pub(crate) fn fault(point: &str) {
    let spec = std::fs::read_to_string("/run/torchd/fault").unwrap_or_default();
    for line in spec.lines() {
        let Some(rest) = line.trim().strip_prefix("after:") else { continue };
        let (p, mode) = rest.split_once(':').unwrap_or((rest, "nosync"));
        if p != point {
            continue;
        }
        if mode == "sync" {
            let _ = recovery::sync_fs(recovery::TOP_MOUNT);
        }
        let msg = format!("{} PAUSED after:{point}:{mode}\n", crate::FAULT_MARKER);
        let _ = std::fs::write("/run/torchd/fault-paused", &msg);
        let _ = std::fs::OpenOptions::new().write(true).open("/dev/ttyS0").map(|mut t| std::io::Write::write_all(&mut t, msg.as_bytes()));
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    }
}
#[cfg(not(feature = "fault-injection"))]
pub(crate) fn fault(_point: &str) {}

/// Development-only: `/run/torchd/fault` line `journal-fail:<name>` makes the journal write of that record fail
/// (`intent`, a step such as `created`, or an outcome such as `prepared`).
#[cfg(feature = "fault-injection")]
pub fn journal_fault(record: &serde_json::Value) -> bool {
    let name = ["step", "result", "kind"].iter().find_map(|k| record[*k].as_str()).unwrap_or_default().to_string();
    std::fs::read_to_string("/run/torchd/fault")
        .unwrap_or_default()
        .lines()
        .any(|l| l.trim().strip_prefix("journal-fail:") == Some(name.as_str()))
}

fn run(cmd: &str, args: &[&str]) -> Result<()> {
    let out = Command::new(cmd).args(args).output().with_context(|| format!("running {cmd}"))?;
    if !out.status.success() {
        bail!("{cmd} {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
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
