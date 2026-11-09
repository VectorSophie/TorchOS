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

## Follow-up review (2026-11-09): journal damage, preflight, reporting, real packages

Each defect was reproduced first against `4d09a3d` (unit tests on the old code, `cargo test`: 3 of 4 repro tests
failed, the fourth passing *is* the defect):

| Defect | Minimal reproduction on `4d09a3d` |
|---|---|
| A torn last line swallowed the next record | append `{"op_id":"a"}`, write `{"op_id":"b","ki` with no newline, append intent `c`: `read` returns only `a`; intent `c` is gone |
| One invalid UTF-8 byte emptied the journal | a journal with one line containing `\xc3`: `read` returns `[]`, every open op disappears |
| An unreadable journal read as empty | journal path is a directory (stands in for EIO/EACCES): `read` returns `[]`, no error |
| The space preflight failed open | `metadata_headroom("")` (usage failed or unparseable) is `None`; `room.is_some_and(< floor)` is false, so the rollback proceeded |
| Reconcile errors did not stop a rollback | `apply` failures went to notes and `Ok`; a journal append failure aborted the loop for every later op |
| A failed `created` record left the copy behind | the rollback returned an error without removing the copy it had just made |

`btrfs filesystem usage -b /.snapshots` on the installed VM (btrfs-progs v7.3) prints `Device unallocated`,
`Metadata ratio: 2.00`, `Global reserve: 12189696 (used: 0)` and `Metadata,DUP: Size:268435456, Used:145915904`. It
exits 1 with `ERROR: cannot access` on a bad path. The parser and its unit fixture use that exact text.

VM (`recovery-ra.sh`, all cases re-run after the journal/reconciliation changes): **PASS, 252 checks, 0 failed.**
F1-F5, F12, F14, F13 and F13b gave the same results as before (F4: the exchange was again committed before the cut).
New cases:

| Case | Injected | Observed |
|---|---|---|
| J1 | torn last journal line, then a crash after `intent` | old root; the new intent survived (`recovered-not-applied`); `repair` record after the torn line; no startup error |
| J2 | `created` record write fails | refused, "nothing was changed (the copy was removed)"; `@`=U0; no `@.torchd-*`; outcome `failed` |
| J3 | `exchanged` and `prepared` record writes fail | rc 0, "committed to disk and NOT fully recorded in the journal (exchanged: …; prepared: …)"; pending refusal still holds; after reboot `recovered-prepared` → `verified`, `.prev`=U0 |
| J4 | `intent` write fails | refused, nothing changed, no `@.torchd-*` |
| J5 | corrupt middle line | torchd starts and serves; startup logs the line number; rollback refused (`@` unchanged); after the operator moves the journal aside, rollback works and is verified |
| J6 | journal unreadable (a directory) | torchd starts and serves; startup logs the error; rollback refused, nothing changed |

Real packages (`image/tests/package-guard-scenario.sh`, disposable container, throwaway key, nothing published):
**10/10**. makepkg builds the normal split package, and its torchd has no marker. The same PKGBUILD with
`--features torchd/fault-injection` fails in `package_torch-cli()` ("refusing to package it"), producing no
torch-cli. `verify-release.sh repo` accepts the signed normal repo, and refuses it once torch-cli's torchd is
replaced by the fault build ("torchd is a fault-injection (development) build"). The ISO check against a real ISO
was not re-run; it is covered by the synthetic ISO cases in `release-integrity-scenario.sh` (44/44).

## Independent review (2026-11-09, after PR #5 merged)

Results above this section are from earlier commits (4d09a3d, ba9b408) and are kept as recorded.

| Finding | Severity | Minimal reproduction (before the fix) | Fix |
|---|---|---|---|
| A repair marker excused whatever line preceded it | Low on TorchOS (needs damage that Btrfs data checksums would turn into EIO), but it silently dropped a confirmed record | journal: `intent`, `created`, torn tail; append repairs it; the `created` record's newline is damaged so it merges into the torn line. The reader returned `corrupt: []`, and `created` disappeared | the repair record carries `torn_bytes`; the reader excuses only a preceding line of exactly that length (`journal.rs`) |
| `docs/recovery.md` step 4 allowed deleting the previous root while a rollback was pending, and did not warn about `.new` | Medium (operator instructions; could remove the only fallback) | "Delete it once you are sure" named `@.torchd-<op>.prev`, which is the running system until the reboot | only after the new system boots; check its UUID is not the running root's; never delete `.new` by hand |

Checked and not a defect: a corrupt record elsewhere stays corrupt when a later torn tail is repaired (test). A
second short write that gets out only the repair's leading newline leaves the torn line unmarked; it is reported
as corrupt (fail closed, operator review), not dropped (test). Journal file creation and the parent directory: no
directory fsync, but not material. The first change on disk after the intent is `btrfs subvolume snapshot`, which
commits a whole transaction on the same filesystem, including the journal's directory entry. A cut before it loses
at most an intent with no effect on disk, and `syncfs` runs again before "prepared".

On the final commit: `cargo test -p torchd` 36/36 with and without `fault-injection`, clippy clean in both; VM
cases J1 and J5 re-run (journal format changed): **PASS, 37 checks, 0 failed** (incl. the release/fault build-marker checks). On the real VM, J1's repair record matched its torn line (no startup error).

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
