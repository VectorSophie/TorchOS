# 2026-11-08: F0 (subvolume exchange) and R-A fault injection, in QEMU

Design: `docs/decisions/0003-recovery-integrity.md` (branch `docs/recovery-integrity-design`), §5 and §7.

## Setup

- Dev ISO built from `master` 9bc1f25 (`build-packages.sh`, `sign-repo.sh` with a **throwaway** test key in a
  separate worktree, `DEV_SSH_PUBKEY`). Never distributed; no production key involved.
- `supported.sh` on that ISO: **PASS** (95 checks; the only DEFECT is the known VM-only hyprpaper crash), which
  includes the old torchd's A4 rollback across a reboot. Its disk, `A-installed.qcow2`, is the base for every case
  below. Each case runs on a fresh qcow2 overlay; the host disk is never involved.
- Installed system: `linux 7.2.14.arch1-1`, `btrfs-progs 7.3-1`, `glibc 2.44`. Root is mounted by name:
  `rootflags=subvol=@` on the kernel command line, `subvol=/@` in fstab. The default subvolume stays 5.
- Power cut means QEMU monitor `quit`. This loses everything the guest has not written to the virtual disk. It
  does not simulate a drive that loses its own write cache.

## F0: `renameat2(RENAME_EXCHANGE)` of two Btrfs subvolume roots (`image/tests/vm/f0-exchange.sh`): PASS

Calls glibc `renameat2(AT_FDCWD, @.f0-new, AT_FDCWD, @, 2)` directly as root on the top-level mount. `@.f0-new` is
a writable snapshot copy. A probe file written after the snapshot tells the two trees apart.

| Case | Result |
|---|---|
| a: exchange, `syncfs`, clean reboot; then exchange back, reboot | rc 0; UUIDs move with the names (`@`=Un, `@.f0-new`=U0); the running system stays on U0 until the reboot; the swapped root boots by itself; the original stays reachable and intact under the other name; exchanging back boots U0 again |
| b: exchange, **no sync**, power cut | boots by itself; `@` is the booted root. On this run the exchange **was** committed before the cut (swapped root booted, original under `@.f0-new`) |
| c: exchange, `syncfs`, power cut | boots the swapped root by itself; the original is kept |
| ref: the **old** design's first rename (`@` → `@.f0-old`), `syncfs`, power cut | **R2 reproduced:** `error: fs/btrfs.c:find_path:2011:file '/@/boot/grub/x86_64-efi/normal.mod' not found. Entering rescue mode... grub rescue>`. No boot without manual help |

Every case also checked: `@home`, `@log`, `@snapshots` keep their UUIDs; the `/home` and `@log` probes survive;
snapper lists every snapshot.

## R-A fault injection (`image/tests/vm/recovery-ra.sh`): PASS, 157 checks, 0 failed

`torchd` is built from the R-A tree in a container, as a release build and a `fault-injection` build. The binary is
copied over `/usr/bin/torchd` on the overlay only. The release build was checked to contain no marker.

| Case | Injected | Observed after power-on (no manual help) |
|---|---|---|
| F1 | crash after `intent` (no sync) | old root; journal `recovered-not-applied`; no temporaries |
| F2 | crash after `created` (sync, so the copy is on disk) | old root; the copy was deleted by reconciliation; `recovered-not-applied` |
| F3 | crash after `exchanged` (sync) | new root; old root renamed to `@.torchd-<op>.prev` at startup; `recovered-prepared` → `verified` |
| F4 | crash after `exchanged` (no sync) | on this run the exchange was committed (new root); `recovered-prepared` → `verified`; no `.new` left |
| F5 | stale legacy `@.rollback-new` from another snapshot | rollback succeeds, root is the requested snapshot, no nested `/snapshot`; the legacy subvolume is left untouched |
| F12 | normal rollback + reboot | rc 0, "committed to disk"; `prepared` → `verified`; previous root kept; `torch doctor` rc 0 |
| F14 | rollback pending, then `torch update tree`, `remove`, `update`, `kernel add`, a second rollback | each refused: "a rollback is pending. Reboot to finish it first"; the package database and `@` are unchanged; `snapshot create` is still allowed |
| F13 | R-A rollback to a snapshot holding the **pre-R-A** torchd | boots by itself into the snapshot; the running torchd is the old binary (sha matches), and it serves `torch status`; the journal stays `prepared` until an R-A torchd starts again, which then records `verified` |
| F13b | as F13, but crash after `exchanged` (sync) | boots by itself into the old-torchd snapshot; `@.torchd-<op>.new` (the old root) is left alone by the old torchd; a later R-A torchd renames it to `.prev` and records `recovered-prepared` → `verified` |

All cases: `@home`, `@log`, `@snapshots` keep their UUIDs; the `/home` and `@log` probes are intact; the booted
root is the subvolume named `@`.

## Not observed / remaining crash states

- **An unsynced exchange that is lost at the cut.** F0-b and F4 both found the exchange already committed. The
  journal fdatasync (F4), or other activity, probably forced a commit; the cause was not traced. In that state
  `@` stays U0; the reconciliation for it (row 2) is covered by the F1/F2 VM cases and by unit tests, but not by
  this exact state.
- A crash *during* the transaction commit itself, and a disk that drops its write cache: not reproducible with
  QEMU `quit`.
- ENOSPC: the metadata floor and the per-step messages are unit-tested only. F9 (fill the disk) belongs to R-E.
- A snapshot boot (R1) still cannot roll back: R-B.
- `grub.cfg` replacement (R5): R-D. Pruning (R4): R-E. Raw `sudo pacman` while a rollback is pending is not blocked.
