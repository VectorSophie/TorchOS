# 2026-11-09: R-D (safe GRUB configuration): reproductions and fault injection, in QEMU

Design: `docs/decisions/0003-recovery-integrity.md` R5 and §7 (F6, F6b, F7). Base disk: `A-installed.qcow2` from
the 2026-11-08 run (test-key dev ISO, never distributed; see `2026-11-08-recovery-ra-vm.md`). Every case runs on a
fresh qcow2 overlay; the host disk is never involved. Power cut = QEMU monitor `quit`.

Installed: `grub 2:2.16-1`, `grub-btrfs 4.14-1`, `linux 7.2.14.arch1-1`. The ESP image's prefix is
`(,gpt2)/@/boot/grub`. No pacman hook regenerates `grub.cfg`; only the installer and torchd's `kernel.install` do.
`grub-btrfsd.service` runs `/etc/grub.d/41_snapshots-btrfs` on snapshot events.

## Upstream behaviour (read on the VM)

- `grub-mkconfig` (lines 290-342): writes `grub.cfg.new`, runs `grub-script-check` on it, then
  `cat grub.cfg.new > grub.cfg` (truncate and rewrite in place, no fsync).
- `41_snapshots-btrfs`: `mv grub-btrfs.cfg grub-btrfs.cfg.bkp` (line 612), builds `grub-btrfs.new` (0.38 s on this
  VM), then `cat .new > grub-btrfs.cfg` (line 648). No `grub-btrfs.cfg` exists in between.
- `grub.cfg` only offers the snapshot submenu `if [ -e "${prefix}/grub-btrfs.cfg" ]`.

## Reproductions on the old code (`image/tests/vm/grub-rd-repro.sh`)

| Case | What | Result | Verdict |
|---|---|---|---|
| H1a | real `grub-mkconfig` (changed timeout), power cut, no commit | GRUB reads the old 6908-byte file; boots; md5 unchanged | old file survives (Btrfs transaction not committed) |
| H1b | as H1a plus a subvolume create meant to force a commit | the subvolume was not committed either; old file | inconclusive (no commit happened) |
| H1c | real `grub-mkconfig`, 35 s idle (periodic commit), cut | the new file, complete | no damage |
| H1d | the state `cat` passes through (truncating open), committed with `sync`, cut | GRUB reads 0 bytes; bare `grub>` prompt, no menu, no snapshot entries (screenshot `image/vm/evidence/rd-H1d.png`) | **effect confirmed; reaching it by a real cut not reproduced** |
| H2 | `/etc/grub.d/99_rdfail` exits 1; then emits `if true` (syntax error) | `grub-mkconfig` rc=1 both times; live md5 unchanged (`grub.cfg.new` left behind) | **disproved**: a failed generation does not alter the live file |
| H3 | pause `41_snapshots-btrfs` after its `mv`, commit, cut | `grub-btrfs.cfg` absent (only `.bkp` and an empty `.new`); main entry boots; grub-btrfsd starts and only watches: menu still missing | **confirmed** (optional menu) |
| H4 | `/etc/grub.d/05_rdbad` emits a default entry with a missing kernel and another root UUID | `grub-mkconfig` rc=0, `grub-script-check` passes, it is the default; VM did not come up (screenshot `rd-H4.png`: the menu, the real entry second) | **confirmed** (default unbootable; manual pick works) |
| H5 | `initramfs-linux.img` moved away, `grub-mkconfig` | rc=0, script-check passes; default entry has **no `initrd`** and `root=/dev/vda2` instead of `root=UUID=`; this VM still booted it | **confirmed as a degraded entry**; unbootable only where the kernel needs its initramfs |

Missing kernels or a wrong root UUID from the upstream generators alone: hypothetical (10_linux lists only existing
kernels; the UUID comes from grub-probe). `package.remove` of a kernel does not regenerate `grub.cfg`: untested.

**Bootability vs optional entries.** An empty `grub.cfg` (H1d) and a bad default entry (H4) make the disk not boot
by itself. A missing snapshot menu (H3) and stale Advanced entries remove optional recovery entries only. H5 is
bootable on this VM, not in general.

## R-D implementation (`torch/torchd/src/ops/grubcfg.rs`)

`kernel.install` calls `grubcfg::regenerate()`: `grub-mkconfig -o grub.cfg.torchd-new` (the live file is never
opened), `syncfs`, validation (`grub-script-check`; default entry first and `/@/boot/vmlinuz-linux`; every entry's
kernel and initrds exist, `root=UUID=<this fs>`, `rootflags=subvol=@`, an initrd present; every `search --fs-uuid` is
this filesystem; snapshot menu included; `grub-fstest cmp` of the default entry's kernel and initrds through GRUB's own
btrfs driver), then a hard link of the live file to `grub.cfg.prev`, `rename(candidate, grub.cfg)`, `syncfs`. A
rejected candidate is kept as `grub.cfg.torchd-rejected`; the error says the boot menu is unchanged. At startup,
torchd restores `grub.cfg.prev` if `grub.cfg` is missing, empty or unparseable, and runs `41_snapshots-btrfs` if the
snapshot menu is missing, unparseable or a `.bkp` is left. Nothing runs `grub-install` or touches the ESP. Snapshot
boots (overlay root) are skipped.

Unit tests: 4 new (H4 and H5 configurations rejected, other filesystem / missing menu / wrong subvolume rejected, a
normal configuration accepted); `cargo test -p torchd` 40/40 with and without `fault-injection`, clippy clean.

## Fault injection (`image/tests/vm/recovery-rd.sh`)

The development-only `torchd grub-regenerate` (fault-injection builds only) runs the code `kernel.install` runs,
without installing a kernel over the network.

| Case | What | Expected and observed |
|---|---|---|
| G0 | regeneration on the installed system | accepted (no false rejection); `grub.cfg.prev` = the replaced file; no temporaries; new file survives an immediate power cut (no extra sync) and boots |
| F6 | `/etc/grub.d` script fails | refused, "boot menu is unchanged", byte-identical, boots |
| F6v | H4's generator | refused, names `vmlinuz-missing`, byte-identical, rejected file kept, boots |
| F6i | H5 (no initramfs) | refused ("has no initrd"), byte-identical, boots |
| F6b-validated / -prev / -renamed | pause at the point, commit, power cut | boots; `grub.cfg` old (before the rename) or new (after), always parses; a later run cleans up |
| F7 | H3's interrupted grub-btrfs run, cut | boots; torchd's startup regenerated the snapshot menu (journal line), lists a snapshot, parses, no `.bkp` |
| F7b | `grub.cfg` emptied by something else, torchd restarted | restored from `grub.cfg.prev`, logged, boots |

Found by F6b-prev and fixed: after a cut between the `.prev` link and the rename, `grub.cfg` and `grub.cfg.prev` are
the same file; the next run's `rename(tmp, grub.cfg.prev)` then does nothing (rename(2) on two links to one inode),
leaving `grub.cfg.prev.torchd-tmp`. The temporary is now removed after the rename.

Results: first full run 63 passed, 4 failed. All 4 came from one harness bug: `< /dev/null` took sudo's stdin
(password), so F6b never started; `F6b-renamed: new one live` failed for the same reason. After that fix, F6b
re-run found the leftover above. **Final code, full suite (all cases G0-F7b, host-built fault-injection torchd because the Arch mirror timed out from containers): PASS, 67 checks, 0 failed.**

## Not covered

- A real power cut landing inside `grub-mkconfig`'s `cat` (H1 by a real cut): not reproduced; R-D removes the in-place
  write from torchd's path, so it only remains for hand-run `grub-mkconfig`.
- ENOSPC during generation (R-E's space tests); `package.remove` of a kernel leaving stale entries.
- Typing `configfile /@/boot/grub/grub.cfg.prev` at a `grub>` prompt (documented in `docs/recovery.md`, untested).
- After a rollback, `grub-btrfs.cfg` is the old root's (stale list) until the next snapshot event: optional entries.
- Snapshot boots skip all of this (R-B).
