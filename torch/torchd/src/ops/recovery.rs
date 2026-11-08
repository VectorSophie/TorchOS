//! Rollback state: what is on disk (observed by subvolume UUID), what the journal says, and how the two are
//! reconciled after a crash (docs/decisions/0003-recovery-integrity.md §5). The decision is the pure `reconcile`;
//! everything that touches the system is in the small functions around it.
use crate::journal;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::CString;
use std::os::unix::io::AsRawFd;
use std::process::Command;

pub const TOP_MOUNT: &str = "/run/torchd/top";
/// Any path on the root filesystem that is a real Btrfs mount in every boot mode (in a snapshot boot `/` is an
/// overlay, /.snapshots is not).
const FS_PATH: &str = "/.snapshots";
pub const PENDING_MSG: &str =
    "refused: a rollback is pending. Reboot to finish it first (nothing was changed)";

// ---------------------------------------------------------------------------------------------- observation

#[derive(Debug, Clone, PartialEq)]
pub struct Subvol {
    pub id: u64,
    pub uuid: String,
    pub parent_uuid: Option<String>,
}

/// Top-level subvolumes by name (`@`, `@home`, `@.torchd-….new`, …), from
/// `btrfs subvolume list -a -u -q <path>`: `ID 256 gen 9 top level 5 parent_uuid - uuid … path <FS_TREE>/@`.
pub type Obs = HashMap<String, Subvol>;

pub fn parse_subvol_list(out: &str) -> Obs {
    let mut m = Obs::new();
    for line in out.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        let after = |k: &str| t.iter().position(|w| *w == k).and_then(|i| t.get(i + 1)).copied();
        let (Some(id), Some(uuid)) = (after("ID").and_then(|s| s.parse().ok()), after("uuid")) else { continue };
        let Some(path) = line.split(" path ").nth(1) else { continue };
        let Some(name) = path.trim().strip_prefix("<FS_TREE>/") else { continue };
        if name.contains('/') {
            continue; // nested, not a top-level name
        }
        let parent_uuid = after("parent_uuid").filter(|p| *p != "-").map(str::to_string);
        m.insert(name.to_string(), Subvol { id, uuid: uuid.to_string(), parent_uuid });
    }
    m
}

pub fn observe() -> Result<Obs> {
    let out = Command::new("btrfs").args(["subvolume", "list", "-a", "-u", "-q", FS_PATH]).output()?;
    if !out.status.success() {
        bail!("btrfs subvolume list: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(parse_subvol_list(&String::from_utf8_lossy(&out.stdout)))
}

/// UUID of the subvolume a path lives on (`btrfs subvolume show`), None if it is not Btrfs (snapshot-boot overlay).
pub fn uuid_of(path: &str) -> Option<String> {
    let out = Command::new("btrfs").args(["subvolume", "show", path]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|l| l.trim().strip_prefix("UUID:").map(|u| u.trim().to_string()))
        .filter(|u| !u.is_empty() && u != "-")
}

pub fn booted_uuid() -> Option<String> {
    uuid_of("/")
}

pub fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id").unwrap_or_default().trim().to_string()
}

/// A rollback is pending when the running root is not the subvolume named `@` (the next boot would run
/// something else). Observed, not read from the journal: it also catches legacy and manual rollbacks.
/// A snapshot boot (no Btrfs root) is not pending.
pub fn pending(obs: &Obs, booted: Option<&str>) -> bool {
    match booted {
        None => false,
        Some(b) => obs.get("@").map(|s| s.uuid.as_str()) != Some(b),
    }
}

/// Free metadata space a new subvolume + renames can draw on, from `btrfs filesystem usage -b`:
/// unallocated space (halved: metadata is DUP on a single disk) plus the unused part of the metadata chunks.
pub fn metadata_headroom(usage: &str) -> Option<u64> {
    let num = |s: &str| s.trim().trim_end_matches(',').parse::<u64>().ok();
    let mut unalloc = None;
    let mut meta = None;
    for l in usage.lines() {
        let l = l.trim();
        if let Some(v) = l.strip_prefix("Device unallocated:") {
            unalloc = num(v);
        } else if l.starts_with("Metadata,") {
            let field = |k: &str| l.split(k).nth(1).and_then(|r| num(r.split_whitespace().next()?));
            if let (Some(size), Some(used)) = (field("Size:"), field("Used:")) {
                meta = Some(size.saturating_sub(used));
            }
        }
    }
    Some(unalloc? / 2 + meta?)
}

// ---------------------------------------------------------------------------------------------- syscalls

extern "C" {
    fn renameat2(olddirfd: i32, old: *const std::ffi::c_char, newdirfd: i32, new: *const std::ffi::c_char, flags: u32) -> i32;
    fn syncfs(fd: i32) -> i32;
}
const AT_FDCWD: i32 = -100;
const RENAME_NOREPLACE: u32 = 1;
const RENAME_EXCHANGE: u32 = 2;

fn rename2(a: &str, b: &str, flags: u32) -> std::io::Result<()> {
    let (a, b) = (CString::new(a)?, CString::new(b)?);
    // SAFETY: two valid NUL-terminated paths; renameat2 does not retain them.
    match unsafe { renameat2(AT_FDCWD, a.as_ptr(), AT_FDCWD, b.as_ptr(), flags) } {
        0 => Ok(()),
        _ => Err(std::io::Error::last_os_error()),
    }
}
/// Atomically swap two names (both must exist). Btrfs does it in one transaction (F0 verified on TorchOS).
pub fn exchange(a: &str, b: &str) -> std::io::Result<()> {
    rename2(a, b, RENAME_EXCHANGE)
}
/// rename that fails instead of replacing an existing destination.
pub fn rename_noreplace(a: &str, b: &str) -> std::io::Result<()> {
    rename2(a, b, RENAME_NOREPLACE)
}
/// Commit the filesystem holding `path` (a Btrfs transaction commit).
pub fn sync_fs(path: &str) -> std::io::Result<()> {
    let f = std::fs::File::open(path)?;
    // SAFETY: valid open fd for the duration of the call.
    match unsafe { syncfs(f.as_raw_fd()) } {
        0 => Ok(()),
        _ => Err(std::io::Error::last_os_error()),
    }
}

/// The top-level filesystem (subvolid=5) mounted at TOP_MOUNT for as long as this lives.
pub struct Top;
impl Top {
    pub fn mount() -> Result<Top> {
        let src = Command::new("findmnt").args(["-no", "SOURCE", FS_PATH]).output().context("findmnt")?;
        let src = String::from_utf8_lossy(&src.stdout);
        let dev = src.trim().split('[').next().unwrap_or("").to_string();
        if !dev.starts_with("/dev/") {
            bail!("cannot determine the Btrfs device (findmnt {FS_PATH}: {:?})", src.trim());
        }
        std::fs::create_dir_all(TOP_MOUNT)?;
        let _ = Command::new("umount").arg(TOP_MOUNT).output(); // stale mount from a killed torchd
        let st = Command::new("mount").args(["-o", "subvolid=5", &dev, TOP_MOUNT]).status()?;
        if !st.success() {
            bail!("mounting the top-level Btrfs filesystem of {dev} failed");
        }
        Ok(Top)
    }
    pub fn path(name: &str) -> String {
        format!("{TOP_MOUNT}/{name}")
    }
}
impl Drop for Top {
    fn drop(&mut self) {
        let _ = Command::new("umount").arg(TOP_MOUNT).status();
    }
}

// ---------------------------------------------------------------------------------------------- journal view

/// One rollback op as the journal describes it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct OpView {
    pub op_id: String,
    pub u0: String,
    pub src_uuid: String,
    pub new_name: String,
    pub prev_name: String,
    pub un: Option<String>,
    /// Last outcome result and the boot it was recorded in.
    pub outcome: Option<(String, String)>,
}

pub fn ops_from(records: &[Value]) -> Vec<OpView> {
    let mut ops: Vec<OpView> = Vec::new();
    let s = |v: &Value, k: &str| v[k].as_str().unwrap_or_default().to_string();
    for r in records {
        let id = s(r, "op_id");
        if r["kind"] == "intent" && r["op"] == "snapshot.rollback" {
            ops.push(OpView {
                op_id: id,
                u0: s(r, "root_uuid_before"),
                src_uuid: s(r, "src_uuid"),
                new_name: s(r, "new_name"),
                prev_name: s(r, "prev_name"),
                ..Default::default()
            });
            continue;
        }
        let Some(op) = ops.iter_mut().rev().find(|o| o.op_id == id) else { continue };
        match (r["kind"].as_str(), r["step"].as_str()) {
            (Some("step"), Some("created")) => op.un = Some(s(r, "new_uuid")).filter(|u| !u.is_empty()),
            (Some("outcome"), _) => op.outcome = Some((s(r, "result"), s(r, "boot_id"))),
            _ => {}
        }
    }
    ops
}

/// Results after which nothing more is ever done for an op. `failed` and `unknown` are not: a failed cleanup or
/// a failed syncfs can leave a copy or an unrenamed root that reconciliation must still handle.
fn terminal(result: &str) -> bool {
    !matches!(result, "prepared" | "recovered-prepared" | "failed" | "unknown")
}

pub fn open_ops(records: &[Value]) -> Vec<OpView> {
    ops_from(records).into_iter().filter(|o| o.outcome.as_ref().is_none_or(|(r, _)| !terminal(r))).collect()
}

// ---------------------------------------------------------------------------------------------- reconcile

#[derive(Debug, Default, PartialEq)]
pub struct Plan {
    /// Delete this subvolume (id, uuid): the op's own uncommitted copy, proven by UUID.
    pub delete: Option<(u64, String)>,
    /// rename(new_name -> prev_name): the exchange happened, the keep-name rename did not.
    pub rename_new_to_prev: bool,
    pub sync: bool,
    /// Outcome records to append, in order.
    pub record: Vec<&'static str>,
}

/// Decide what to do about one op, from observed facts only (§5.2). Deletes only the row-2 copy, renames only
/// in row 3, and records anything else without acting.
pub fn reconcile(op: &OpView, obs: &Obs, booted: Option<&str>, boot_id: &str) -> Plan {
    let mut p = Plan::default();
    let uuid = |n: &str| obs.get(n).map(|s| s.uuid.as_str());
    let at = uuid("@");
    let un = op.un.as_deref();
    match &op.outcome {
        Some((r, _)) if r == "failed" => {
            // Decide from observation like an open op, but say nothing if there is nothing left to do.
            let p = reconcile(&OpView { outcome: None, ..op.clone() }, obs, booted, boot_id);
            return if p.delete.is_none() && p.record == ["recovered-not-applied"] { Plan::default() } else { p };
        }
        Some((r, _)) if r == "unknown" => return reconcile(&OpView { outcome: None, ..op.clone() }, obs, booted, boot_id),
        None => {
            if at == Some(op.u0.as_str()) {
                match obs.get(&op.new_name) {
                    None => p.record.push("recovered-not-applied"),
                    Some(n) if n.parent_uuid.as_deref() == Some(op.src_uuid.as_str())
                        && n.uuid != op.u0
                        && Some(n.uuid.as_str()) != booted
                        && un.is_none_or(|u| u == n.uuid) =>
                    {
                        p.delete = Some((n.id, n.uuid.clone()));
                        p.record.push("recovered-not-applied");
                    }
                    Some(_) => p.record.push("ambiguous"),
                }
            } else if at.is_some() && at == un {
                if uuid(&op.new_name) == Some(op.u0.as_str()) && uuid(&op.prev_name).is_none() {
                    p.rename_new_to_prev = true;
                } else if uuid(&op.prev_name) != Some(op.u0.as_str()) {
                    p.record.push("ambiguous");
                    return p;
                }
                p.sync = true;
                p.record.push("recovered-prepared");
                if booted == un {
                    p.record.push("verified"); // the crash already rebooted into the new root
                }
            } else {
                p.record.push("superseded");
            }
        }
        Some((r, rec_boot)) if !terminal(r) => {
            // The keep-name rename failed when the rollback ran: finish it (row 3), whatever the boot.
            if at.is_some() && at == un && uuid(&op.new_name) == Some(op.u0.as_str()) && uuid(&op.prev_name).is_none() {
                p.rename_new_to_prev = true;
                p.sync = true;
            }
            if rec_boot == boot_id {
                return p; // still pending in the boot that prepared it
            }
            p.record.push(if booted.is_some() && booted == un {
                "verified"
            } else if at.is_some() && at == un {
                "not-applied"
            } else {
                "superseded"
            });
        }
        Some(_) => {}
    }
    p
}

/// Carry out a plan, re-checking the delete target's identity right before deleting it by id.
fn apply(op: &OpView, plan: &Plan) -> Result<()> {
    if plan.delete.is_none() && !plan.rename_new_to_prev && !plan.sync {
        return Ok(());
    }
    let _top = Top::mount()?;
    if let Some((id, uuid)) = &plan.delete {
        let now = observe()?;
        let n = now.get(&op.new_name).context("copy to delete vanished")?;
        if n.id != *id || &n.uuid != uuid || now.get("@").is_some_and(|a| &a.uuid == uuid) {
            bail!("refusing to delete {}: identity changed since it was checked", op.new_name);
        }
        let st = Command::new("btrfs")
            .args(["subvolume", "delete", "--subvolid", &id.to_string(), TOP_MOUNT])
            .output()?;
        if !st.status.success() {
            bail!("deleting {} failed: {}", op.new_name, String::from_utf8_lossy(&st.stderr).trim());
        }
    }
    if plan.rename_new_to_prev {
        rename_noreplace(&Top::path(&op.new_name), &Top::path(&op.prev_name))
            .with_context(|| format!("renaming {} to {}", op.new_name, op.prev_name))?;
    }
    if plan.sync || plan.delete.is_some() || plan.rename_new_to_prev {
        sync_fs(TOP_MOUNT).context("syncfs")?;
    }
    Ok(())
}

/// Reconcile every open rollback op. Run at torchd startup and before each rollback. Failures are reported,
/// never fatal: bootability never depends on this (§5.4).
pub fn reconcile_all() -> Result<Vec<String>> {
    let records = journal::read(journal::PATH);
    let ops = open_ops(&records);
    if ops.is_empty() {
        return Ok(vec![]);
    }
    let obs = observe()?;
    let booted = booted_uuid();
    let boot = boot_id();
    let mut notes = vec![];
    for op in ops {
        let plan = reconcile(&op, &obs, booted.as_deref(), &boot);
        if plan == Plan::default() {
            continue;
        }
        if let Err(e) = apply(&op, &plan) {
            notes.push(format!("{}: reconciliation failed: {e:#}", op.op_id));
            continue;
        }
        for r in &plan.record {
            let facts = json!({"op_id": op.op_id, "kind": "outcome", "result": r, "boot_id": boot,
                "booted_uuid": booted, "at_uuid": obs.get("@").map(|s| &s.uuid), "by": "reconcile",
                "torchd_version": crate::VERSION});
            journal::append(journal::PATH, &facts)?;
        }
        notes.push(format!("{}: {}", op.op_id, plan.record.join(" -> ")));
    }
    Ok(notes)
}

/// Refuse when a rollback is pending (owner decision 2). Fails closed if the state cannot be observed while the
/// root is Btrfs.
pub fn refuse_if_pending() -> Result<()> {
    let booted = booted_uuid();
    if booted.is_none() {
        // Only a snapshot boot (overlay root) may pass without a UUID; any other failure to read it refuses.
        let fs = Command::new("findmnt").args(["-no", "FSTYPE", "/"]).output().map(|o| o.stdout).unwrap_or_default();
        if String::from_utf8_lossy(&fs).trim() == "btrfs" || fs.is_empty() {
            bail!("refused: cannot read the running root's subvolume UUID to check for a pending rollback");
        }
        return Ok(()); // snapshot boot: nothing here changes what the next boot runs
    }
    let obs = observe().context("refused: cannot check for a pending rollback")?;
    if pending(&obs, booted.as_deref()) {
        bail!(PENDING_MSG);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sv(id: u64, uuid: &str, parent: Option<&str>) -> Subvol {
        Subvol { id, uuid: uuid.into(), parent_uuid: parent.map(Into::into) }
    }
    fn obs(entries: &[(&str, Subvol)]) -> Obs {
        entries.iter().cloned().map(|(n, s)| (n.to_string(), s)).collect()
    }
    fn op(un: Option<&str>, outcome: Option<(&str, &str)>) -> OpView {
        OpView {
            op_id: "r1".into(),
            u0: "U0".into(),
            src_uuid: "SRC".into(),
            new_name: "@.torchd-r1.new".into(),
            prev_name: "@.torchd-r1.prev".into(),
            un: un.map(Into::into),
            outcome: outcome.map(|(a, b)| (a.into(), b.into())),
        }
    }
    const N: &str = "@.torchd-r1.new";
    const P: &str = "@.torchd-r1.prev";

    #[test]
    fn parses_btrfs_subvolume_list() {
        let out = "ID 256 gen 120 top level 5 parent_uuid - uuid 0a-u0 path <FS_TREE>/@\n\
                   ID 257 gen 99 top level 5 parent_uuid - uuid 0b-home path <FS_TREE>/@home\n\
                   ID 260 gen 99 top level 256 parent_uuid - uuid 0c-nested path <FS_TREE>/@/var/lib/portables\n\
                   ID 270 gen 130 top level 5 parent_uuid 0d-src uuid 0e-new path <FS_TREE>/@.torchd-r1.new\n\
                   ID 271 gen 131 top level 259 parent_uuid 0a-u0 uuid 0f-snap path <FS_TREE>/@snapshots/3/snapshot\n";
        let m = parse_subvol_list(out);
        assert_eq!(m.len(), 3);
        assert_eq!(m["@"], sv(256, "0a-u0", None));
        assert_eq!(m["@.torchd-r1.new"], sv(270, "0e-new", Some("0d-src")));
        assert!(!m.contains_key("@/var/lib/portables"));
    }

    #[test]
    fn pending_is_observed_by_uuid() {
        let o = obs(&[("@", sv(1, "U0", None))]);
        assert!(!pending(&o, Some("U0")));
        assert!(pending(&o, Some("OLD")));
        assert!(!pending(&o, None), "a snapshot boot is not pending");
        assert!(pending(&obs(&[]), Some("U0")), "no @ at all fails closed");
    }

    #[test]
    fn metadata_headroom_from_usage() {
        let u = "Overall:\n    Device size:\t\t 21474836480\n    Device unallocated:\t\t 1073741824\n\
                 Data,single: Size:8388608000, Used:4000000000 (47.68%)\n\
                 Metadata,DUP: Size:268435456, Used:100000000 (37.25%)\n";
        assert_eq!(metadata_headroom(u), Some(1073741824 / 2 + 268435456 - 100000000));
        assert_eq!(metadata_headroom("garbage"), None);
    }

    // One test per row of the §5.2 table.
    #[test]
    fn row1_intent_only() {
        let p = reconcile(&op(None, None), &obs(&[("@", sv(1, "U0", None))]), Some("U0"), "b2");
        assert_eq!(p, Plan { record: vec!["recovered-not-applied"], ..Default::default() });
    }

    #[test]
    fn row2_copy_exists_is_deleted_only_when_proven() {
        let o = obs(&[("@", sv(1, "U0", None)), (N, sv(9, "UN", Some("SRC")))]);
        let p = reconcile(&op(Some("UN"), None), &o, Some("U0"), "b2");
        assert_eq!(p.delete, Some((9, "UN".into())));
        assert_eq!(p.record, vec!["recovered-not-applied"]);
        // created record lost (crash before it was durable): still a proven copy of src
        assert_eq!(reconcile(&op(None, None), &o, Some("U0"), "b2").delete, Some((9, "UN".into())));
        // wrong parent, or a UUID that differs from the recorded copy: never deleted
        let o2 = obs(&[("@", sv(1, "U0", None)), (N, sv(9, "UN", Some("OTHER")))]);
        assert_eq!(reconcile(&op(Some("UN"), None), &o2, Some("U0"), "b2"), Plan { record: vec!["ambiguous"], ..Default::default() });
        assert_eq!(reconcile(&op(Some("UX"), None), &o, Some("U0"), "b2").delete, None);
        // never the booted root
        assert_eq!(reconcile(&op(None, None), &o, Some("UN"), "b2").delete, None);
    }

    #[test]
    fn row3_exchanged_not_renamed() {
        let o = obs(&[("@", sv(9, "UN", Some("SRC"))), (N, sv(1, "U0", None))]);
        // after a power cut the machine already booted the new root
        let p = reconcile(&op(Some("UN"), None), &o, Some("UN"), "b2");
        assert_eq!(p, Plan { rename_new_to_prev: true, sync: true, record: vec!["recovered-prepared", "verified"], ..Default::default() });
        // torchd restarted in the same boot: rename, still pending
        let p = reconcile(&op(Some("UN"), None), &o, Some("U0"), "b1");
        assert_eq!(p.record, vec!["recovered-prepared"]);
        assert!(p.rename_new_to_prev);
    }

    #[test]
    fn row4_renamed_not_reported() {
        let o = obs(&[("@", sv(9, "UN", Some("SRC"))), (P, sv(1, "U0", None))]);
        let p = reconcile(&op(Some("UN"), None), &o, Some("UN"), "b2");
        assert_eq!(p, Plan { sync: true, record: vec!["recovered-prepared", "verified"], ..Default::default() });
    }

    #[test]
    fn row5_impossible_states_are_ambiguous_and_untouched() {
        let o = obs(&[("@", sv(9, "UN", None)), (P, sv(7, "ELSE", None))]);
        assert_eq!(reconcile(&op(Some("UN"), None), &o, Some("UN"), "b2"), Plan { record: vec!["ambiguous"], ..Default::default() });
        // rename target already taken: no rename over it
        let o = obs(&[("@", sv(9, "UN", None)), (N, sv(1, "U0", None)), (P, sv(7, "ELSE", None))]);
        assert_eq!(reconcile(&op(Some("UN"), None), &o, Some("UN"), "b2").record, vec!["ambiguous"]);
    }

    #[test]
    fn row6_someone_else_changed_at() {
        let o = obs(&[("@", sv(30, "OLDTORCHD", None)), (P, sv(1, "U0", None))]);
        let p = reconcile(&op(Some("UN"), None), &o, Some("OLDTORCHD"), "b3");
        assert_eq!(p, Plan { record: vec!["superseded"], ..Default::default() });
    }

    #[test]
    fn prepared_ops_are_verified_on_a_later_boot() {
        let o = obs(&[("@", sv(9, "UN", None)), (P, sv(1, "U0", None))]);
        let prepared = op(Some("UN"), Some(("prepared", "b1")));
        assert_eq!(reconcile(&prepared, &o, Some("U0"), "b1"), Plan::default(), "same boot: pending");
        assert_eq!(reconcile(&prepared, &o, Some("UN"), "b2").record, vec!["verified"]);
        assert_eq!(reconcile(&prepared, &o, None, "b2").record, vec!["not-applied"], "booted a snapshot instead");
        let moved = obs(&[("@", sv(30, "LATER", None))]);
        assert_eq!(reconcile(&prepared, &moved, Some("LATER"), "b5").record, vec!["superseded"]);
        for t in ["verified", "superseded", "ambiguous", "recovered-not-applied"] {
            assert_eq!(reconcile(&op(Some("UN"), Some((t, "b1"))), &o, Some("UN"), "b9"), Plan::default());
        }
    }

    #[test]
    fn failed_and_unknown_ops_are_reconciled_from_observation() {
        let left = obs(&[("@", sv(1, "U0", None)), (N, sv(9, "UN", Some("SRC")))]);
        let p = reconcile(&op(Some("UN"), Some(("failed", "b1"))), &left, Some("U0"), "b1");
        assert_eq!(p.delete, Some((9, "UN".into())), "a copy a failed cleanup left behind is removed");
        let clean = obs(&[("@", sv(1, "U0", None))]);
        assert_eq!(reconcile(&op(Some("UN"), Some(("failed", "b1"))), &clean, Some("U0"), "b1"), Plan::default());
        // syncfs failed, then power cut: whatever is on disk decides
        let swapped = obs(&[("@", sv(9, "UN", Some("SRC"))), (P, sv(1, "U0", None))]);
        assert_eq!(reconcile(&op(Some("UN"), Some(("unknown", "b1"))), &swapped, Some("UN"), "b2").record, vec!["recovered-prepared", "verified"]);
        assert_eq!(reconcile(&op(Some("UN"), Some(("unknown", "b1"))), &clean, Some("U0"), "b2").record, vec!["recovered-not-applied"]);
    }

    #[test]
    fn prepared_with_a_failed_keep_name_rename_is_finished() {
        let o = obs(&[("@", sv(9, "UN", None)), (N, sv(1, "U0", None))]);
        let p = reconcile(&op(Some("UN"), Some(("prepared", "b1"))), &o, Some("U0"), "b1");
        assert_eq!(p, Plan { rename_new_to_prev: true, sync: true, ..Default::default() });
        let p = reconcile(&op(Some("UN"), Some(("prepared", "b1"))), &o, Some("UN"), "b2");
        assert!(p.rename_new_to_prev);
        assert_eq!(p.record, vec!["verified"]);
    }

    #[test]
    fn journal_view_and_open_ops() {
        let recs = vec![
            json!({"op_id":"r1","kind":"intent","op":"snapshot.rollback","root_uuid_before":"U0","src_uuid":"SRC","new_name":N,"prev_name":P}),
            json!({"op_id":"r1","kind":"step","step":"created","new_uuid":"UN"}),
            json!({"op_id":"r1","kind":"step","step":"exchanged"}),
            json!({"op_id":"r1","kind":"outcome","result":"prepared","boot_id":"b1"}),
            json!({"op_id":"r2","kind":"intent","op":"snapshot.rollback","root_uuid_before":"UN","src_uuid":"S2","new_name":"x","prev_name":"y"}),
            json!({"op_id":"r2","kind":"outcome","result":"failed","boot_id":"b2"}),
        ];
        let ops = ops_from(&recs);
        assert_eq!(ops.len(), 2);
        assert_eq!(ops[0].un.as_deref(), Some("UN"));
        assert_eq!(ops[0].outcome, Some(("prepared".into(), "b1".into())));
        let open = open_ops(&recs);
        assert_eq!(open.len(), 2, "prepared and failed ops are both still looked at");
        assert_eq!(open[0].op_id, "r1");
    }
}
