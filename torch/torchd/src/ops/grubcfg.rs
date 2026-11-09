//! Safe GRUB configuration (docs/decisions/0003-recovery-integrity.md R5, R-D).
//!
//! Upstream grub-mkconfig (2.16) replaces the live grub.cfg with `cat grub.cfg.new > grub.cfg`: truncate and rewrite
//! in place, no fsync. A committed truncated file stops GRUB at a bare `grub>` prompt (VM case H1d). And its only
//! check is grub-script-check, which passes a parseable but unbootable menu (H4). Here the candidate is generated
//! beside the live file, validated against the files GRUB will load, made durable, and swapped in with one rename;
//! the replaced file is kept as grub.cfg.prev. On any failure the live file is not touched.
use super::recovery::sync_fs;
use super::snapshot::fault;
use anyhow::{bail, Context, Result};
use std::process::Command;

pub const DIR: &str = "/boot/grub";
pub const LIVE: &str = "/boot/grub/grub.cfg";
pub const PREV: &str = "/boot/grub/grub.cfg.prev";
const CAND: &str = "/boot/grub/grub.cfg.torchd-new";
const REJECTED: &str = "/boot/grub/grub.cfg.torchd-rejected";
const PREV_TMP: &str = "/boot/grub/grub.cfg.prev.torchd-tmp";
const SNAP_MENU: &str = "/boot/grub/grub-btrfs.cfg";
const SNAP_MENU_GEN: &str = "/etc/grub.d/41_snapshots-btrfs";

/// Problems with a candidate grub.cfg, judged against this system (`file_ok` says whether a /boot path exists and is
/// non-empty). Empty = acceptable. The rules are the install-time verifier's (torch-target-verify), applied to every
/// boot entry: GRUB will load exactly these files from this filesystem.
pub fn check(cfg: &str, fs_uuid: &str, file_ok: &dyn Fn(&str) -> bool) -> Vec<String> {
    let mut bad = Vec::new();
    if fs_uuid.is_empty() {
        bad.push("cannot read the root filesystem's UUID".to_string());
    }
    let searches: Vec<&str> = cfg.lines().filter(|l| l.contains("search") && l.contains("--fs-uuid")).collect();
    if searches.is_empty() {
        bad.push("no `search --fs-uuid` line: GRUB would not find this filesystem".into());
    }
    for s in searches {
        if s.split_whitespace().last() != Some(fs_uuid) {
            bad.push(format!("searches another filesystem: {}", s.trim()));
        }
    }
    if !cfg.contains("grub-btrfs.cfg") {
        bad.push("does not include the snapshot menu (grub-btrfs.cfg)".into());
    }
    // (title, linux line, initrd lines) for each menuentry; grub-mkconfig puts the closing brace on its own line.
    let mut entries: Vec<(String, Option<String>, Vec<String>)> = Vec::new();
    let mut open = false;
    for l in cfg.lines().map(str::trim) {
        if l.starts_with("menuentry ") {
            let title = l.split(['\'', '"']).nth(1).unwrap_or("?").to_string();
            entries.push((title, None, Vec::new()));
            open = true;
        } else if open && l == "}" {
            open = false;
        } else if open {
            let e = entries.last_mut().expect("open entry");
            match l.split_whitespace().next() {
                Some("linux") => e.1 = Some(l.to_string()),
                Some("initrd") => e.2.push(l.to_string()),
                _ => {}
            }
        }
    }
    let boot_path = |p: &str| p.strip_prefix("/@/boot/").map(|r| format!("/boot/{r}"));
    match entries.first() {
        None => bad.push("no boot entries".into()),
        Some((t, linux, _)) => {
            if linux.as_deref().and_then(|l| l.split_whitespace().nth(1)) != Some("/@/boot/vmlinuz-linux") {
                bad.push(format!("the default entry '{t}' does not boot /@/boot/vmlinuz-linux"));
            }
        }
    }
    for (t, linux, initrds) in &entries {
        let Some(linux) = linux else { continue }; // firmware setup and the like
        let mut w = linux.split_whitespace().skip(1);
        let kernel = w.next().unwrap_or("");
        let args: Vec<&str> = w.collect();
        match boot_path(kernel) {
            Some(p) if file_ok(&p) => {}
            _ => bad.push(format!("'{t}': kernel {kernel} is not a file in /boot")),
        }
        if !args.contains(&format!("root=UUID={fs_uuid}").as_str()) {
            bad.push(format!("'{t}': does not mount root=UUID={fs_uuid}"));
        }
        let subvol_at = |a: &&str| {
            a.strip_prefix("rootflags=").is_some_and(|f| f.split(',').any(|o| o == "subvol=@" || o == "subvol=/@"))
        };
        if !args.iter().any(subvol_at) {
            bad.push(format!("'{t}': does not mount rootflags=subvol=@"));
        }
        if initrds.is_empty() {
            bad.push(format!("'{t}': has no initrd (its initramfs is missing?)"));
        }
        for i in initrds.iter().flat_map(|l| l.split_whitespace().skip(1)) {
            if !boot_path(i).is_some_and(|p| file_ok(&p)) {
                bad.push(format!("'{t}': initrd {i} is not a file in /boot"));
            }
        }
    }
    bad
}

/// The default entry's kernel and initrds, as /boot paths.
fn default_files(cfg: &str) -> Vec<String> {
    let lines = cfg.lines().map(str::trim).skip_while(|l| !l.starts_with("menuentry ")).skip(1);
    let mut out = Vec::new();
    for l in lines.take_while(|l| *l != "}") {
        let mut w = l.split_whitespace();
        let (Some("linux" | "initrd"), rest) = (w.next(), w) else { continue };
        let n = if l.starts_with("linux") { 1 } else { usize::MAX }; // linux <kernel> <args>; initrd <files>
        out.extend(rest.take(n).filter_map(|p| p.strip_prefix("/@/boot/").map(|r| format!("/boot/{r}"))));
    }
    out
}

fn run(cmd: &str, args: &[&str]) -> Result<()> {
    let o = Command::new(cmd).args(args).output().with_context(|| format!("running {cmd}"))?;
    if !o.status.success() {
        bail!("{cmd} failed: {}", String::from_utf8_lossy(&o.stderr).trim());
    }
    Ok(())
}

/// The root filesystem's device and UUID (`findmnt -no SOURCE,UUID /`), e.g. ("/dev/vda2", "e180…").
fn root_fs() -> Result<(String, String)> {
    let o = Command::new("findmnt").args(["-no", "SOURCE,UUID,FSTYPE", "/"]).output().context("findmnt")?;
    let s = String::from_utf8_lossy(&o.stdout);
    let w: Vec<&str> = s.split_whitespace().collect();
    match w[..] {
        [src, uuid, "btrfs"] => Ok((src.split('[').next().unwrap_or(src).to_string(), uuid.to_string())),
        _ => bail!("the running root is not the installed Btrfs root ({}); GRUB is not regenerated here", s.trim()),
    }
}

fn file_ok(p: &str) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.len() > 0)
}

/// Regenerate grub.cfg safely. Err = the live grub.cfg was not changed (the message says why).
pub fn regenerate() -> Result<()> {
    let (dev, uuid) = root_fs()?;
    for f in [CAND, &format!("{CAND}.new"), PREV_TMP] {
        let _ = std::fs::remove_file(f); // leftovers of an interrupted run; never the live file
    }
    // grub-mkconfig writes CAND.new, checks its syntax, then copies it to CAND: the live file is never opened.
    if let Err(e) = run("grub-mkconfig", &["-o", CAND]) {
        let _ = std::fs::remove_file(CAND);
        bail!("{e:#}; the boot menu is unchanged");
    }
    sync_fs(DIR).context("syncfs before validation")?; // grub-fstest below reads the disk, not the page cache
    let cfg = std::fs::read_to_string(CAND).context("reading the new grub.cfg")?;
    let mut bad = check(&cfg, &uuid, &file_ok);
    if let Err(e) = run("grub-script-check", &[CAND]) {
        bad.push(format!("{e:#}"));
    }
    // GRUB's own btrfs driver must read the default entry's files completely (the kernel-hole defect of 2026-09).
    for f in default_files(&cfg) {
        let inner = f.replacen("/boot/", "/@/boot/", 1);
        if run("grub-fstest", &[&dev, "cmp", &inner, &f]).is_err() {
            bad.push(format!("GRUB cannot read {f} completely from {dev}"));
        }
    }
    if !bad.is_empty() {
        let _ = std::fs::rename(CAND, REJECTED);
        bail!("the new GRUB configuration was rejected ({}); the boot menu is unchanged (rejected file: {REJECTED})", bad.join("; "));
    }
    fault("grub-validated");
    // Keep the configuration being replaced. A hard link: no copy, and grub.cfg.prev is replaced in one rename.
    if std::path::Path::new(LIVE).exists() {
        std::fs::hard_link(LIVE, PREV_TMP).context("linking grub.cfg.prev")?;
        std::fs::rename(PREV_TMP, PREV).context("keeping grub.cfg.prev")?;
        // rename(2) does nothing when both names are already the same file (after an interrupted run or a restore)
        let _ = std::fs::remove_file(PREV_TMP);
    }
    fault("grub-prev");
    std::fs::rename(CAND, LIVE).context("installing the new grub.cfg")?;
    fault("grub-renamed");
    sync_fs(DIR).context("the new grub.cfg is installed but could not be committed to disk")?;
    Ok(())
}

fn script_ok(p: &str) -> bool {
    file_ok(p) && run("grub-script-check", &[p]).is_ok()
}

/// At torchd startup (never fatal; notes for the log). Repairs what an interrupted writer left behind:
/// - grub.cfg missing, empty or unparseable while grub.cfg.prev is fine: put grub.cfg.prev back (atomically).
///   Only reachable when something other than `regenerate` wrote grub.cfg (an older torchd, a hand-run grub-mkconfig).
/// - the snapshot menu missing, unparseable, or left as grub-btrfs.cfg.bkp by an interrupted grub-btrfs run
///   (grub-btrfsd does not regenerate at start; VM case H3): run grub-btrfs's generator once.
pub fn startup_check() -> Vec<String> {
    let mut notes = Vec::new();
    if root_fs().is_err() {
        return notes; // snapshot boot (overlay root): /boot is not the installed one, and nothing here would persist
    }
    if !script_ok(LIVE) {
        if script_ok(PREV) {
            let r = std::fs::hard_link(PREV, PREV_TMP)
                .and_then(|_| std::fs::rename(PREV_TMP, LIVE))
                .and_then(|_| std::fs::remove_file(PREV_TMP).or(Ok(())))
                .and_then(|_| sync_fs(DIR));
            notes.push(match r {
                Ok(()) => format!("{LIVE} was missing or damaged: restored it from {PREV}"),
                Err(e) => format!("error: {LIVE} is missing or damaged and restoring {PREV} failed: {e}"),
            });
        } else {
            notes.push(format!("error: {LIVE} is missing or damaged and there is no usable {PREV}"));
        }
    }
    let interrupted = std::path::Path::new(&format!("{SNAP_MENU}.bkp")).exists();
    if (interrupted || !script_ok(SNAP_MENU)) && std::path::Path::new(SNAP_MENU_GEN).exists() {
        let r = run(SNAP_MENU_GEN, &[]).and_then(|_| sync_fs(DIR).map_err(Into::into));
        notes.push(match r {
            Ok(()) if script_ok(SNAP_MENU) => format!("snapshot menu was missing or incomplete: regenerated {SNAP_MENU}"),
            Ok(()) => format!("error: regenerating {SNAP_MENU} did not produce a usable menu"),
            Err(e) => format!("error: regenerating {SNAP_MENU} failed: {e:#}"),
        });
    }
    notes
}

#[cfg(test)]
mod tests {
    use super::*;

    const U: &str = "e180fd0a-be53-4ab6-b919-61df55abf1a0";
    fn cfg(default_linux: &str, initrd: &str) -> String {
        format!(
            "insmod btrfs\nsearch --no-floppy --fs-uuid --set=root {U}\n\
             menuentry 'TorchOS Linux' --class torchos $menuentry_id_option 'gnulinux-simple-{U}' {{\n\
             \tload_video\n\tlinux\t{default_linux} rw rootflags=subvol=@ quiet\n{initrd}}}\n\
             submenu 'Advanced options for TorchOS Linux' {{\n\
             \tmenuentry 'TorchOS Linux, with Linux linux-lts' {{\n\
             \t\tlinux\t/@/boot/vmlinuz-linux-lts root=UUID={U} rw rootflags=subvol=@\n\
             \t\tinitrd\t/@/boot/initramfs-linux-lts.img\n\t}}\n}}\n\
             menuentry 'UEFI Firmware Settings' $menuentry_id_option 'uefi-firmware' {{\n\tfwsetup\n}}\n\
             if [ ! -e \"${{prefix}}/grub-btrfs.cfg\" ]; then\necho \"\"\nelse\nsubmenu 'TorchOS snapshots' {{\n\
             configfile \"${{prefix}}/grub-btrfs.cfg\"\n}}\nfi\n"
        )
    }
    fn good() -> String {
        cfg(&format!("/@/boot/vmlinuz-linux root=UUID={U}"), "\tinitrd\t/@/boot/initramfs-linux.img\n")
    }
    const ALL: &dyn Fn(&str) -> bool = &|_| true;

    #[test]
    fn a_normal_configuration_passes() {
        assert_eq!(check(&good(), U, ALL), Vec::<String>::new());
        assert_eq!(default_files(&good()), ["/boot/vmlinuz-linux", "/boot/initramfs-linux.img"]);
        assert!(default_files("menuentry 'x' {\nlinux\n}\n").is_empty(), "no panic on a bare linux line");
    }

    #[test]
    fn reproduced_h4_a_parseable_but_unbootable_default_is_rejected() {
        // VM case H4: grub-mkconfig and grub-script-check accepted this, and the system did not boot.
        let bad = format!(
            "search --no-floppy --fs-uuid --set=root {U}\nmenuentry \"TorchOS Linux\" {{\n  linux /@/boot/vmlinuz-missing \
             root=UUID=00000000-0000-0000-0000-000000000000 rw rootflags=subvol=@\n}}\n{}",
            good()
        );
        let missing = |p: &str| p != "/boot/vmlinuz-missing";
        let e = check(&bad, U, &missing).join("\n");
        assert!(e.contains("does not boot /@/boot/vmlinuz-linux"), "{e}");
        assert!(e.contains("kernel /@/boot/vmlinuz-missing is not a file"), "{e}");
        assert!(e.contains("does not mount root=UUID="), "{e}");
        assert!(e.contains("has no initrd"), "{e}");
    }

    #[test]
    fn reproduced_h5_missing_initramfs_is_rejected() {
        // VM case H5: with initramfs-linux.img gone, 10_linux drops the initrd line and switches to root=/dev/vda2.
        let c = cfg("/@/boot/vmlinuz-linux root=/dev/vda2", "");
        let e = check(&c, U, ALL).join("\n");
        assert!(e.contains("'TorchOS Linux': has no initrd"), "{e}");
        assert!(e.contains("'TorchOS Linux': does not mount root=UUID="), "{e}");
        // and an initrd line naming a file that is not there
        let gone = |p: &str| p != "/boot/initramfs-linux-lts.img";
        assert!(check(&good(), U, &gone).join("\n").contains("initrd /@/boot/initramfs-linux-lts.img is not a file"));
    }

    #[test]
    fn other_filesystems_and_missing_pieces_are_rejected() {
        let other = good().replace(&format!("--set=root {U}"), "--set=root 11111111-2222-3333-4444-555555555555");
        assert!(check(&other, U, ALL).join("\n").contains("searches another filesystem"));
        let no_menu = good().replace("grub-btrfs.cfg", "x.cfg");
        assert!(check(&no_menu, U, ALL).join("\n").contains("snapshot menu"));
        assert!(!check("", U, ALL).is_empty());
        assert!(!check(&good(), "", ALL).is_empty(), "unknown root UUID");
        let wrong_subvol = good().replace("rootflags=subvol=@ quiet", "rootflags=subvol=@home quiet");
        assert!(check(&wrong_subvol, U, ALL).join("\n").contains("'TorchOS Linux': does not mount rootflags=subvol=@"));
        let flags = good().replace("rootflags=subvol=@ quiet", "rootflags=compress=zstd,subvol=/@ quiet");
        assert_eq!(check(&flags, U, ALL), Vec::<String>::new());
    }
}
