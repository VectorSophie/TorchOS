# 0003: Recovery integrity (rollback, GRUB configuration, retention, operation state)

Status: **approved with required revisions** (owner review 2026-11-08); this revision incorporates them (§0).
Nothing here is implemented yet; F0 (§7) gates R-A. Based on `master` at `9bc1f25`.
It refines `docs/superpowers/specs/2026-11-02-torchos-direction.md` §3 gaps 4-9 and §4.3-4.4, and corrects one of
its assumptions (R3 below). Layout unchanged: `@ @home @log @cache @snapshots`, `/boot` inside `@`, GRUB +
grub-btrfs, Snapper. `/home` is never touched by anything in this document.

## 0. Owner decisions (2026-11-08) and what they changed

1. **Automatic pruning of previous roots, keep the newest two**, only after a verified boot. Never automatically
   delete the booted root, a root referenced by an open operation, a root not yet verified, or a legacy root of
   uncertain ownership (`@.pre-rollback-*`, `@.rollback-new`). Pruning is serialized with rollback and re-checks
   identity just before deletion (§6).
2. **Refuse** (not warn) `package.install`, `package.remove`, `system.upgrade` and `kernel.install` while a rollback
   is pending reboot, **in R-A**. A second rollback does not silently supersede a pending one: R-A refuses it too.
   A designed "replace the pending rollback" transition is future work with its own tests (§5.3).
3. **Fault injection is development-only.** The cargo feature is off by default; the official PKGBUILD refuses to
   package a binary that contains it; `verify-release.sh repo` and `iso` refuse a `torchd` that contains it (§7.1).

Required revisions, and where they are addressed: rollback to a snapshot with a pre-R-A `torchd` (§5.4, F13);
atomicity vs filesystem durability vs journal durability vs post-boot verification (§2.1); ENOSPC and metadata
allocation (R6, §5.5); prune serialization and identity re-check (§6); the R-A/R-C split (§8); `docs/recovery.md`'s
"original stays in place" claim (corrected in that file).

## 1. Evidence base

Code read at `9bc1f25`:
- `torch/torchd/src/ops/snapshot.rs` (create, rollback, `swap_in`)
- `ops/kernel.rs`, `ops/mod.rs`
- `torchd/src/main.rs` (sequential accept loop; one audit line written *after* each op)
- `torchd/src/audit.rs`, `torchd.service`
- `torch/src/commands/{snapshot,doctor}.rs`
- `image/calamares/usr/lib/torchos/torch-target-setup` §10-11 (Snapper/grub-btrfs setup)
- `image/tests/vm/supported.sh` A4 (the one rollback test)

Upstream behaviour, read from the packages current Arch ships (`archlinux:base-devel`, 2026-11-08):
- **grub 2:2.16-1** `grub-mkconfig` writes `grub.cfg.new` and runs `grub-script-check` on it. It then replaces the
  live file with `cat grub.cfg.new > grub.cfg` (lines 327-341): truncate and rewrite *in place*, with no fsync.
- **grub-btrfs 4.14-1** `41_snapshots-btrfs` first `mv`s the live `grub-btrfs.cfg` to `.bkp` (line 612), builds
  `.new`, then `cat .new > grub-btrfs.cfg` (line 648). While it runs, no `grub-btrfs.cfg` exists.
- **btrfs-progs 7.3-1** `btrfs subvolume snapshot <subvol> <subdir>`: "When only `<subdir>` is given, the subvolume
  will be named the basename of `<subvolume>`." If the destination exists, the snapshot is created *inside* it,
  and the command succeeds.
- **snapper 0.13.2-1** default template: `NUMBER_LIMIT=50`, `NUMBER_LIMIT_IMPORTANT=10`, `NUMBER_MIN_AGE=3600`,
  `FREE_LIMIT=0.2`, `SPACE_LIMIT=0.5`. TorchOS overrides the first two to 10 and 6.
- **coreutils 9.12** `mv --exchange` (`renameat2(RENAME_EXCHANGE)`).

Verified behaviour so far: the happy-path rollback across a reboot (A4, 2026-11-04 and 2026-11-06), and booting a
snapshot from the GRUB menu (2026-09). **None of the failure classes below has been reproduced.** Each has a VM
reproduction in §7. "Confirmed" below means confirmed by code or upstream source, not by a run.

## 2. Current rollback, step by step

`snapshot.rollback(N)`, run by root `torchd`; the client blocks until it returns:

| # | Action | Durable? |
|---|---|---|
| 1 | `findmnt -no SOURCE /` → device (`/dev/vda2[/@]` → `/dev/vda2`) | - |
| 2 | `mount -o subvolid=5 <dev> /run/torchd/top` | - |
| 3 | `btrfs subvolume snapshot /.snapshots/N/snapshot top/@.rollback-new` | next transaction commit (≤30 s) |
| 4 | `rename(top/@, top/@.pre-rollback-<UTC second>)` | next commit |
| 5 | `rename(top/@.rollback-new, top/@)` | next commit |
| 6 | `umount`; return "prepared: reboot to complete it" | **no sync** |

On failure at 4, it deletes `@.rollback-new`. On failure at 5, it tries `rename(old, @)`, *ignores that result*,
and reports "original restored". One audit line is appended after the op returns. There is no record before it.

GRUB finds its configuration through the prefix embedded in the ESP image, `/@/boot/grub`. `/boot`, `grub.cfg`
and `grub-btrfs.cfg` all live inside `@`. The kernel command line and fstab refer to the root by **name**
(`rootflags=subvol=/@`, `subvol=/@`), never by subvolume id, so whatever tree is named `@` at boot is the root,
with its own kernel, modules, `grub.cfg` and `torchd`. F0 checks this on the installed system.

### 2.1 Four different guarantees (not to be conflated)

| Property | What provides it | What it does **not** give |
|---|---|---|
| **Atomicity** of the swap | one `renameat2(RENAME_EXCHANGE)`: Btrfs performs it in one transaction handle, so any committed state has either the old or the new tree at `@`, never neither | it says nothing about *when* the change reaches disk |
| **Filesystem durability** | `syncfs` on the top-level mount (commits the transaction). Without it the exchange is lost on power cut until the next periodic commit (≤ 30 s), which is the safe direction (old root boots) | a successful `syncfs` does not prove the next boot will pick that root (firmware/GRUB choice, user picks a snapshot) |
| **Journal durability** | `write` + `fdatasync` of a journal record on `@log`. On Btrfs an fsync goes through the log tree and can survive a crash in which a not-yet-committed rename is lost | a durable record "exchanged" does not mean the exchange is durable. Records are written *after* their step returns, and reconciliation trusts **observed subvolume UUIDs** over records |
| **Post-boot verification** | after reboot, the UUID of the subvolume mounted at `/` equals the `Un` recorded for the op | it is an observation, recorded later; until then the op is only `prepared` |

"Prepared" is reported only after the exchange, the rename and `syncfs` all returned. "Verified" is recorded only
by a later boot that observes it. Bootability never depends on the journal or on any `torchd` running at all (§5.4).

## 3. Failure classes

Severity: **S1** = machine can be left without a bootable root, or silently boots the wrong root. **S2** = a
recovery path the docs promise does not work, or reported state is false. **S3** = slow degradation (space).

### R1. Rollback from a GRUB-booted snapshot (overlay root): S2

- *Trace:* in a snapshot boot `/` is the grub-btrfs-overlayfs overlay, so step 1 yields `overlay`.
  `device_from_findmnt` returns `None`; its own unit test asserts exactly that. The op fails with "cannot determine
  the root device" before any change.
- *Left behind:* nothing; it fails safe. But `torch doctor` in that state tells the user `Keep this state: torch
  snapshot rollback N`, and `docs/recovery.md` §5 repeats it. The documented recovery path does not work.
- *Extra constraint, found here:* a snapshot boot runs the **snapshot's own** `torchd`. A fix only helps snapshots
  taken after the fixed `torchd` is installed. Older snapshots need a documented manual or live-ISO procedure.
- *Reproduced?* No (direction spec gap 6 is from code reading).
- *Correction:* take the device from the filesystem that holds the source snapshot (`findmnt -no SOURCE
  /.snapshots` → `/dev/vda2[/@snapshots]`). Check that it is the same filesystem UUID as the kernel's `root=UUID=`.
  The rollback then proceeds with the R2 state machine, because `@` is not the running root in a snapshot boot. What
  gets installed is the read-only snapshot N, *not* the overlay's changes. The confirmation text says so.
- *Test:* VM boot snapshot N from GRUB → `torch snapshot rollback N` → before the fix: exits non-zero with "cannot
  determine the root device". After the fix: exits 0, reboot boots N's content (probe file from after N is absent),
  `/home` probe kept, and doctor no longer warns about a snapshot session.

### R2. Power loss between the two renames: S1

- *Trace:* steps 4 and 5 are two `rename(2)` calls. Btrfs makes each durable at a transaction commit (default every
  30 s, or on sync). Nothing makes them one transaction. If a commit lands between them and power is lost, the
  disk has `@.pre-rollback-T` and `@.rollback-new` but **no `@`**.
- *Left behind:* GRUB's prefix `/@/boot/grub` does not resolve, so it drops to `grub rescue>`. The snapshot submenu
  is unreachable too, because it is in `@/boot/grub/`. `torchd` never runs, so nothing at boot can repair it.
  Manual recovery is possible: `set prefix=(hdX,gptY)/@.pre-rollback-T/boot/grub; insmod normal; normal`, then rename
  from the booted system. Or use the live ISO. A user will not know either.
- *Reproduced?* No. The window is microseconds, so reproducing it needs either a fault point or the state built
  by hand (§7 F2).
- *Correction (the core of this design):* never let `@` be absent. Replace the two renames with **one
  `renameat2(new, @, RENAME_EXCHANGE)`**. Btrfs supports exchange since Linux 4.7. Per the kernel source,
  `btrfs_rename_exchange` handles subvolume roots under `subvol_sem` in a single transaction handle, so any
  committed state has either the old or the new tree at `@` (atomicity, §2.1; durability is a separate `syncfs`).
  Then rename the exchanged-out old root to its keep-name, then `syncfs`. **Gate:** F0 (§7) proves on the shipped
  kernel and layout that the exchange works between subvolume roots and that sync and unsynced crash states never
  lack `@`. If it fails, R-A stops and the evidence goes back for review; it does **not** fall back to two renames
  silently (the §5 fallback needs its own approval).
- *Test:* F2/F3/F4 in §7. Every injected crash state boots by itself to either the old or the new root, and is
  reported.

### R3. Stale `@.rollback-new` after an interrupted operation: S1 (corrects the direction spec)

- *Trace:* a crash after step 3, or a failure in step 4 whose delete also failed, leaves `@.rollback-new`. On the
  next rollback, step 3 runs `btrfs subvolume snapshot … top/@.rollback-new` with the destination existing. Per
  btrfs-progs it creates `@.rollback-new/snapshot` **inside** the stale subvolume and succeeds. Steps 4-5 then
  install the **stale tree** as `@`, plus a nested `snapshot` subvolume. That tree may be a different snapshot
  number from an earlier attempt.
- *Left behind:* a bootable root with the wrong content, and a success message. The direction spec said this makes
  the next rollback *fail*; it does worse.
- *Reproduced?* No. Upstream CLI semantics only.
- *Correction:* a per-operation name, `@.torchd-<op-id>.new`, and an explicit refusal when the destination
  exists. A legacy `@.rollback-new` is never reused. Startup reconciliation (§5) reports it and removes it only if
  it can be proven not to be any root (its `Parent UUID` is a snapshot's, and its UUID is neither `@`'s nor the
  booted root's). Otherwise doctor reports it for the user.
- *Test:* F5: create `@.rollback-new` from snapshot A by hand, then roll back to B. Before: reports success, and
  after reboot the root is A's content with a nested `/snapshot`. After: it refuses, or reconciles first, and the
  root is B's content.

### R4. Unbounded previous roots (`@.pre-rollback-*`): S3

- *Trace:* every rollback keeps the old root. Nothing lists it (`torch snapshot list` shows Snapper only), and
  nothing deletes it. Each pins a whole root's diverging extents. Same-second names collide (`rename` → EEXIST),
  which fails safely today.
- *Correction:* the keep-name carries the op id (`@.torchd-<op-id>.prev`), plus the legacy names. `torch snapshot
  list` shows previous roots. The retention rules are in §6.
- *Test:* F8: three rollbacks give exactly two kept previous roots after the third verified boot. The booted root
  is never deleted.

### R5. Incomplete or corrupted `grub.cfg`: S1 for `grub.cfg`, S2 for `grub-btrfs.cfg`

- *Trace:* `kernel.install` runs `grub-mkconfig -o /boot/grub/grub.cfg`. Upstream validates the candidate but
  installs it with `cat … >`. A crash mid-copy, or before the data reaches disk, can leave `grub.cfg` truncated or
  empty. GRUB then gives a `grub>` prompt, with no snapshot menu because that is sourced from `grub.cfg`.
  Separately, grub-btrfsd regenerates `grub-btrfs.cfg` on every snapshot event, with no live file during
  regeneration, and every pacman transaction creates two snapshots. Power loss there loses the snapshot submenu
  for the next boot. The main entries are unaffected.
- *Also noted:* `/boot/grub/x86_64-efi` (GRUB modules) is written only by `grub-install` at install time, so every
  snapshot shares the ESP core's module set. **Nothing may ever run `grub-install` after installation** without
  solving module/core skew across snapshots. That is a constraint, not a defect today.
- *Reproduced?* No.
- *Correction:* `torchd` regenerates through one helper:
  1. `grub-mkconfig -o /boot/grub/grub.cfg.candidate`. Upstream's `cat` then targets the candidate, not the live file.
  2. Validate: `grub-script-check`; every `linux`/`initrd` path in a menuentry exists under `/boot`; a menuentry for
     the `linux` kernel exists; `root=UUID=` equals the running filesystem's UUID.
  3. `fsync` the candidate.
  4. Hard-link or copy the current file to `grub.cfg.prev` and `fsync` it.
  5. `rename(candidate, grub.cfg)` and `fsync /boot/grub`.
  On failure the live file is untouched and the op reports failure. For `grub-btrfs.cfg`: `torchd` at startup
  regenerates it if it is missing or fails `grub-script-check`. Doctor reports the state. Upstream grub-btrfs is
  not patched.
- *Test:* F6 (corrupt the candidate generator via a broken `/etc/grub.d/` script: the live file stays
  byte-identical, the op fails), F7 (cut power while the snapshot menu regenerates: the main entry boots and
  `torchd` restores the menu).

### R6. Snapshot retention and free space: S3

- *Trace:* `torch snapshot create` and `kernel.install` call `snapper create -u important=yes` with no
  `--cleanup-algorithm`. Snapper cleanup ignores snapshots without an algorithm, so these accumulate forever. snap-pac
  pairs use `number`: limit 10, plus `NUMBER_MIN_AGE=3600`. `SPACE_LIMIT` needs quotas, which are off. `FREE_LIMIT`
  is the template's 0.2, and whether it takes effect without quotas must be checked in the VM.
  `snapper-cleanup.timer` is *optional* at install. Doctor's space check is `df --output=pcent /`, which is
  approximate on Btrfs and wrong in a snapshot boot (tmpfs/overlay).
- *Failure:* Btrfs ENOSPC, especially **metadata**, makes `pacman`, snapshot creation, the journal write and even
  `rename` fail. A rollback writes no file data but does need metadata: the new subvolume's root item and refs,
  directory entries for the exchange and rename, and the journal records. **No rollback is guaranteed to succeed on
  a full filesystem.** What the design does guarantee is narrower (§5.5): every step either completes or leaves the
  previous state, `@` is never absent in a committed state, and the user is told which. One case is worse than an
  error return: if Btrfs hits ENOSPC *inside* a running transaction it aborts the transaction and forces the
  filesystem read-only. The on-disk state is then the last committed one (still a valid `@`), the running system
  can no longer write, and the next boot starts from that committed state.
- *Correction:* §6.
- *Test:* F9: fill the disk to below the threshold. `torch update` and `kernel.install` refuse with the free figure.
  A rollback still works, because it adds no data, and cleanup reclaims space.

### R7. Lost or ambiguous operation state after a crash: S2

- *Trace:* the only record is one audit line written after the op returns. After a crash mid-rollback there is no
  record that it ran, which snapshot it targeted, or which subvolume is which. Recovery has to guess from names,
  and R3 shows names lie.
- *Correction:* the operation journal in §4: intent before the first side effect, a record per step, and an
  outcome. Each is fsynced, on `@log` so it survives the rollback itself, and keyed by subvolume **UUIDs**.
  Startup reconciliation runs on it (§5).
- *Test:* each F-case asserts the journal ends in the right terminal state after reboot.

### R8. Inaccurate success reporting: S2

Confirmed by code:
1. "prepared: reboot to complete it" is returned with **no sync**. Power loss within about 30 s can undo the whole
   swap: the safe direction, but reported to nobody.
2. The step-5 failure path reports "original restored" without checking the restoring rename. If that fails, it
   is R2's no-`@` state, reported as safe.
3. Doctor in a snapshot boot recommends the broken R1 command.
4. Nothing ever checks that the *rebooted* system is the intended root. A4 checks it in the test harness, but the
   product doesn't.
5. After a rollback, before reboot, the running system is the old root. `torch update`, `torch install` or
   `kernel.install` then succeed against a root that is discarded at reboot. A silent lost update.
6. Doctor's disk-space check (R6).

- *Correction:*
  - success means "durable and reconciled": sync, then report;
  - a pending-rollback state (§5.3: the booted root's UUID ≠ the UUID of the subvolume named `@`) makes `torchd`
    refuse package, upgrade and kernel ops **and another rollback** with "reboot to finish the rollback first"
    (R-A), and doctor warns (R-C);
  - after reboot, `torchd` records `verified` or `not-applied` by comparing the booted root's UUID with the
    journal's;
  - doctor reports pending, verified and failed rollbacks, previous roots, stale temporaries, the snapshot-menu
    state, and the Btrfs free estimate.

## 4. Operation journal (rollback first)

`/var/log/torchd/journal.jsonl` (on `@log`, so it survives rollbacks). The torchd unit already owns
`LogsDirectory=torchd`. Each record is one line: `write`, then `fdatasync`. The `intent` record is durable
**before the first side effect**; if it cannot be written (ENOSPC, EIO) the op is refused with nothing changed.
Every `step` record is written **after** its step returned, so a record never claims a step that did not run;
the reverse (a step ran, its record was lost) is handled by reconciling against observed UUIDs (§2.1).
`op_id` is generated by `torchd`, not the client, and recorded together with the client's request id. Each record
also carries `torchd_version`. A torn last line (crash mid-write) is ignored by the reader.

```
{"op_id":"r-20261108T120000Z-3f2a","seq":1,"kind":"intent","op":"snapshot.rollback","snapshot":7,
 "boot_id":"…","fs_uuid":"…","root_uuid_before":"<UUID of @>","src_uuid":"<UUID of /.snapshots/7/snapshot>",
 "booted_uuid":"<UUID of the running root, or the snapshot's in a snapshot boot>"}
{"op_id":…,"seq":2,"kind":"step","step":"created","new_uuid":"<UUID of @.torchd-<op>.new>"}
{"op_id":…,"seq":3,"kind":"step","step":"exchanged"}
{"op_id":…,"seq":4,"kind":"step","step":"renamed","prev_name":"@.torchd-<op>.prev"}
{"op_id":…,"seq":5,"kind":"outcome","result":"prepared"}          # after syncfs
{"op_id":…,"seq":6,"kind":"outcome","result":"verified","boot_id":"…"}   # next boot, booted UUID == new_uuid
```

Terminal results: `prepared` → `verified` | `not-applied`, or `failed` (no change) | `recovered` (reconciled
after a crash; the record says to which side). The existing audit line stays as is. The journal is the recovery
source of truth. Rotation: when the file exceeds 1 MiB, start a new file once no op is open (follow-up).

## 5. Rollback state machine

### 5.1 States

Names: `@` (live), `N` = `@.torchd-<op>.new`, `P` = `@.torchd-<op>.prev`. UUIDs: `U0` = `@` before, `Un` = new copy.

```
            intent fsynced
 S0 ──────────────────────────► S1 ──snapshot(src→N)──► S2 ──exchange(N,@)──► S3 ──rename(N→P)──► S4 ──syncfs──► S5 prepared
 (nothing)                     (intent only)           (N exists, @=U0)     (@=Un, N holds U0)    (@=Un, P=U0)                │
                                                                                                                       reboot
                                                                                                                         ▼
                                                                                         S6 verified (booted UUID == Un) / S6' not-applied
```

**Invariant:** in every state `@` exists and is a complete root, either `U0` or `Un`. `/home`, `@log` and
`@snapshots` are never renamed.

### 5.2 Reconciliation

Reconciliation runs **once at `torchd` startup** before it accepts requests, and again before any new rollback. It
looks at the last open op (intent without outcome) and at the actual subvolumes on the top level, identified by
UUID. Durability caveat: without a sync, an on-disk state can be *older* than the journal says (the journal is
fsynced, the renames are not). So reconciliation trusts observed UUIDs over journal steps, and uses the journal
only to name them.

| Observed after the crash | Means | Action | Outcome |
|---|---|---|---|
| intent only; no `N`; `@`=U0 | crashed before or during snapshot creation (creation is atomic) | nothing to undo | `recovered: not applied` |
| `N` exists (UUID Un, parent = src); `@`=U0 | crashed before the exchange | delete `N` (proven a copy: parent UUID = src, UUID ≠ U0 and ≠ booted) | `recovered: not applied` |
| `@`=Un; `N` holds U0 | exchanged, not renamed | rename `N`→`P`, syncfs | `recovered: prepared` (reboot to verify) |
| `@`=Un; `P`=U0 | renamed, not synced or reported | syncfs | `recovered: prepared` |
| `@`=U0 and `P`=Un (or any UUID mismatch the table doesn't name) | impossible by construction | change nothing; doctor shows a FAIL with the UUID facts | `ambiguous` (user decision) |
| `@` is neither U0 nor Un | something else changed `@` since (an older `torchd` after rolling back to an old snapshot, a manual fix) | change nothing, delete nothing | `superseded` (facts recorded) |
| outcome `prepared`, new boot, booted UUID = Un | rollback took effect | none | `verified` |
| outcome `prepared`, new boot, booted UUID ≠ Un | user booted something else (e.g. a snapshot) | none | `not-applied` (doctor explains) |

Reconciliation only ever **deletes** a subvolume in row 2 (a copy proven by UUID, parent UUID and the open op), and
only **renames** in row 3. Any other observation is recorded, never acted on.

### 5.3 Pending rollback and refused operations (R-A)

*Pending* is defined by observation, not by the journal: the UUID of the subvolume mounted at `/` (read with
`btrfs subvolume show /`) differs from the UUID of the subvolume named `@` on the top level. This also detects
pending rollbacks made by an older `torchd` (legacy names) or by hand, and survives a lost journal.

While pending, `torchd` refuses `package.install`, `package.remove`, `system.upgrade`, `kernel.install` and
`snapshot.rollback` with "a rollback is pending: reboot to finish it first". Service ops and `snapshot.create` stay
allowed: they do not change what the next boot runs. A snapshot boot (overlay root) is not "pending"; R-B handles it.
Raw `sudo pacman` outside `torchd` is not blocked by this (follow-up: a libalpm `PreTransaction` hook with
`AbortOnFail` that runs the same check).

Superseding a pending rollback is **not** allowed in R-A. If it is wanted later, it needs an explicit, journaled
transition (exchange the pending `@` back with `P`, verify, then start the new op) and its own F-cases.

### 5.4 Rolling back to a snapshot that contains a pre-R-A `torchd`

After the exchange, `@` *is* the old snapshot's tree, with its own kernel, `grub.cfg`, fstab and **its own older
`torchd`**, which knows nothing about the journal or the new names. Design rules that follow:
- **Bootability needs no `torchd`.** Every committed state has a complete `@`; GRUB, the kernel command line and
  fstab find it by name (§2). Reconciliation is housekeeping only: it may run much later or never.
- Leftovers an old `torchd` will not clean up are harmless to boot: `@.torchd-<op>.new` (row 2/3 states) and
  `@.torchd-<op>.prev`. Their names never collide with the old `torchd`'s own `@.rollback-new` /
  `@.pre-rollback-*`.
- The old `torchd` may itself roll back again (two-rename code) before a new `torchd` ever runs. The journal is then
  stale. A later R-A `torchd` sees `@` ≠ U0 and ≠ Un → `superseded`, and changes nothing.
- Post-boot verification is recorded by the first R-A `torchd` that starts. If an old `torchd` booted in between,
  the result is labelled with the boot it observed, not claimed for the first boot after the rollback.
- Pending-state protection in the old root works, because the root that runs before the reboot is the one that
  ran the R-A rollback. After reboot nothing is pending.
- The old `torchd` still has R1-R8 (e.g. its own two-rename rollback). That cannot be fixed retroactively; doctor
  in a new root, and the release notes, say so.

Test: F13 (§7).

### 5.5 ENOSPC and metadata allocation failures

Before the intent record, `torchd` reads `btrfs filesystem usage -b` and refuses a rollback when the metadata free
space plus unallocated space is below a floor (initial value 256 MiB, tuned in F9), naming the figure and pointing
at cleanup. This is a heuristic that lowers the odds; it is not a guarantee. On ENOSPC at each step:

| Step fails | State | Reported |
|---|---|---|
| intent write | nothing changed | `refused: cannot write the operation journal (<errno>)` |
| snapshot create | nothing changed (or a half-created `N` that is not referenced by `@`) | `failed`; reconciliation deletes `N` only by the row-2 rule |
| exchange | no change (the call is all-or-nothing) | `failed: nothing changed` |
| rename `N`→`P` | `@`=Un, old root still named `N` | `prepared` with a warning; the next start renames it |
| `syncfs` / the transaction aborts (filesystem read-only) | last committed state, either side, `@` present | `outcome unknown: reboot; the state is reconciled at the next start`, never "prepared" or "restored" |

### 5.6 Recovery for each interrupted state

Every row above. The common rule: the machine boots by itself whatever the last committed state is, and the only
thing a user may ever need to do by hand is answer an `ambiguous` doctor report.

### 5.7 Fallback if subvolume exchange is not supported

Only with separate owner approval after an F0 failure (never automatic): keep two renames, but make the no-`@` state
bootable. Rename the *new* copy into place first under a second name GRUB can find, and keep a static fallback
`configfile` on the ESP that tries `/@/boot/grub/grub.cfg`, then the newest `@.torchd-*.prev`. This is more
moving parts. Use it only if F0 forces it.

## 6. Retention rules

- **Snapper checkpoints** (`torch snapshot create`, the `kernel.install` pre-checkpoint): pass `--cleanup-algorithm
  number` with `important=yes`. That makes them bounded by `NUMBER_LIMIT_IMPORTANT=6`. The "TorchOS fresh install"
  snapshot (#1) keeps no algorithm on purpose: it is the permanent baseline. snap-pac pairs: unchanged
  (`NUMBER_LIMIT=10`).
- **`snapper-cleanup.timer`** becomes a *required* install step. Without it nothing is bounded. Doctor checks it
  is enabled.
- **Free space:** check in the VM whether `FREE_LIMIT=0.2` acts without quotas (F9). If it does not, `torchd` runs
  `snapper cleanup number` before mutating ops when the estimate is below 20%.
- **Previous roots (owner decision: automatic, keep two):** when a rollback reaches `verified`, `torchd` deletes
  `@.torchd-*.prev` roots beyond the two newest (by the journal's `prepared` time). A candidate is skipped if it
  is: the booted root; `@`; referenced by any journal op that is not terminal; the `P` of an op not yet `verified`;
  not recorded in the journal at all; or a legacy name. The rollback confirmation text says "previous roots beyond
  the two newest are deleted after the next verified boot". Manual `torch snapshot prune` (confirmation, lists
  what goes) is follow-up.
- **Serialization and identity re-check before every deletion:** pruning runs inside `torchd`'s single request
  thread (the same one that runs rollbacks and reconciliation), under an exclusive `flock` on
  `/run/torchd/subvol.lock` that the rollback also takes, so no rollback can run between choosing and deleting.
  Immediately before deleting, `torchd` re-reads the candidate (`btrfs subvolume show` on the top-level path), checks
  that its UUID equals the journal's, that it is not the booted root's or `@`'s UUID, and that it is not the
  default subvolume, then deletes **by subvolume id** (`btrfs subvolume delete --subvolid <id> <top>`) so a rename
  between check and delete cannot redirect it. Remaining window: another root process renaming or deleting on the
  top level during those milliseconds; deletion by id makes that fail, never hit a different tree.
- **Legacy names** `@.pre-rollback-*` and `@.rollback-new` from older versions: ownership is uncertain, so they are
  never deleted automatically. Listed by doctor and `torch snapshot list`; removed only with the user's confirmation.
- **Space thresholds for mutating ops:** use the `btrfs filesystem usage -b` "Free (estimated)" of the filesystem,
  read through `/.snapshots`, which is valid in a snapshot boot too. Refuse `system.upgrade`, `package.*` and
  `kernel.install` below `max(2 GiB, 5%)` with the figure. A rollback is allowed, since it adds no data.

## 7. VM fault-injection test matrix

Fault points: compile `torchd` with a cargo feature `fault-injection`, **never in release packages**.
The release gates in §7.1 refuse any binary containing it. In that build `torchd`
reads `/run/torchd/fault` (tmpfs, root-only), e.g. `after:exchanged:sync`. At that point it does `syncfs` (or not,
for `:nosync`), writes `PAUSED` to the serial console, and blocks. The harness waits for `PAUSED` on the serial log,
then cuts power with QEMU monitor `quit`, the same as a power loss. It relaunches on the same disk with
`start_disk`. Each case runs on a fresh qcow2 overlay of the `supported.sh` result (`overlay()` in `lib.sh`), so it
costs one boot and never a reinstall. The host disk is never involved.

| ID | Inject | Expect after power-on (no manual help) | Distinguishes broken vs fixed |
|---|---|---|---|
| F0 | *(capability, `image/tests/vm/f0-exchange.sh`)* on the installed system, `renameat2(RENAME_EXCHANGE)` of `@` with a writable copy of a snapshot; (a) syncfs + reboot, (b) power-cut with no sync, (c) syncfs + power-cut | exchange succeeds; UUIDs move with the names; the swapped root boots unaided; the original root stays reachable under the other name; no crash state lacks `@`; `/home`, `@log`, `@snapshots` intact | gate for the R2 design |
| F1 | crash after `intent` (sync / nosync) | boots old root; journal `recovered: not applied`; no temporaries | - |
| F2 | crash after `created` | boots old root; `N` deleted; `not applied` | old code: stale `@.rollback-new` left |
| F3 | crash after `exchanged` (sync) | boots **new** root; `N`→`P` renamed at startup; `prepared`→`verified` on the next boot | old code: the equivalent state (after first rename) gives `grub rescue>`. Reproduce on old code by hand: `mv top/@ top/@.pre-rollback-x; sync`, power-cut |
| F4 | crash after `exchanged` (nosync) | boots old **or** new root; journal reconciled to what was observed; never a rescue prompt | - |
| F5 | legacy `@.rollback-new` from snapshot A present, roll back to B | refuses or reconciles first; final root = B, no nested `/snapshot` | old code: root = A + nested `/snapshot`, rc 0 |
| F6 | broken `/etc/grub.d/99_broken` → `kernel.install` | op fails; `grub.cfg` byte-identical; system boots | old code: upstream refuses too, but the step-1 truncation case is F6b |
| F6b | crash during the `grub.cfg` replacement (fault after candidate fsync / after the prev copy) | boots with the old or new `grub.cfg`, never an empty one | old code: crash mid-`cat` → `grub>` (reproduce by truncating `grub.cfg` + power-cut) |
| F7 | power-cut while grub-btrfsd regenerates (pause the hook) | main entry boots; `torchd` regenerates `grub-btrfs.cfg`; doctor OK | old code: snapshot submenu missing until the next snapshot event |
| F8 | three rollbacks with reboots | two previous roots kept; booted root never pruned; `torch snapshot list` shows them | old code: three `@.pre-rollback-*`, invisible |
| F9 | fill to below 2 GiB free | upgrade/install refused with the figure; rollback works; cleanup reclaims | old code: pacman fails mid-transaction |
| F10 | boot snapshot N from GRUB, `torch snapshot rollback N`, reboot | rollback succeeds; N's content booted; `/home` kept | old code: "cannot determine the root device" |
| F11 | *(superseded by F14, now part of R-A)* | | |
| F12 | normal rollback, reboot (A4) | as today, plus journal `verified` and doctor reports it | regression guard |
| F13 | base install has the pre-R-A `torchd`; checkpoint S; install the R-A `torchd`; roll back to S (and F13b: crash after `exchanged`, nosync and sync) | boots unaided into S with the **old** `torchd`; old `torchd` serves `torch status`; leftovers harmless; re-installing R-A `torchd` reconciles to `verified`/`superseded` without deleting anything outside row 2 | bootability does not depend on new code |
| F14 | rollback prepared, then `install`/`remove`/`update`/`kernel add`/second rollback before reboot | each refused, nothing changed (package db and `@` UUID unchanged) | old code: applied to the discarded root, rc 0 |

Every case also asserts: `/home` probe unchanged; `@snapshots` intact (`snapper list` count); doctor exit code
matches the state.

### 7.1 Keeping fault injection out of official artifacts (owner decision 3)

- The cargo feature `fault-injection` is off by default. When on, the binary contains the marker string
  `TORCHD-FAULT-INJECTION-BUILD` (a `static` used at startup, so it is not optimized away), and `torchd` prints a
  warning with it on every start.
- `pkg/torchos/PKGBUILD` builds without the feature, and its `package()` fails if the built `torchd` contains the
  marker (covers an env-var or config override such as `CARGO_FEATURES`/`.cargo/config.toml`).
- `verify-release.sh repo` extracts `usr/bin/torchd` from the `torch-cli` package and refuses on the marker;
  `verify-release.sh iso` extracts `usr/bin/torchd` from `airootfs.sfs` and refuses on the marker (or if it is
  missing). Scenario tests cover both.
- VM fault tests never go through a package: the harness builds the feature binary in a container and copies it
  over `/usr/bin/torchd` on a disposable overlay disk.

Unit tests (no VM): the reconciliation table as a pure function `reconcile(journal_tail, observed_subvols) ->
Action`, with one test per row including the "ambiguous" row; journal serialization; the `grub.cfg` validator
against fixture configs (missing kernel file, wrong root UUID, truncated file).

## 8. Incremental implementation plan (separate reviewable PRs)

Each PR is small, keeps `torchd`'s structure (one op module, the sequential loop, the policy table), and lands with
its F-cases. **The split is chosen so that no intermediate release can lose package changes after a pending
rollback:** the refusal of package/kernel ops while pending (owner decision 2) is in R-A, the same PR that changes
the rollback, not in R-C.

1. **R-A: crash-safe rollback core + pending protection** (R2, R3, R7, R8.1-2, R8.5).
   - F0 first; R-A starts only if it passes.
   - `ops/snapshot.rs`: per-op names, refusal when a destination exists, exchange, keep-name rename, `syncfs`,
     honest errors (§5.5), the metadata floor.
   - `torchd/src/journal.rs` (append + fdatasync, torn-line tolerant reader) and a pure `reconcile()` run at startup
     and before each rollback. R-A records `verified`/`not-applied` too (it is one comparison at startup), so the
     journal never stays open across releases.
   - Pending detection by UUID (§5.3) and refusal of package/upgrade/kernel ops and a second rollback.
   - The `fault-injection` feature, with the §7.1 build and release guards.
   - Tests: unit tests for reconcile, journal, pending detection; VM cases F0-F5, F12, F13, F14.
2. **R-B: rollback from a snapshot boot** (R1, R8.3).
   - Device from `/.snapshots`, with a filesystem-UUID check.
   - Doctor wording; `docs/recovery.md` §5, plus a manual procedure for snapshots older than the fix.
   - Tests: F10.
3. **R-C: reporting** (R8.4, R8.6). Doctor shows pending/verified/not-applied/superseded rollbacks, previous roots
   and leftover temporaries; the optional libalpm hook that applies the pending check to raw `pacman`. Tests: doctor
   output in F12-F14, F12 extended.
4. **R-D: safe GRUB configuration** (R5). The candidate → validate → prev → rename → fsync helper used by
   `kernel.install`, and the startup check and regeneration of `grub-btrfs.cfg`. Tests: F6, F6b, F7, validator unit
   tests.
5. **R-E: retention and space** (R4, R6).
   - Cleanup algorithm on checkpoints; automatic previous-root pruning (§6, owner decision 1) with the
     serialization and identity re-check; `snapper-cleanup.timer` required; Btrfs free-space gate; doctor space check.
   - Tests: F8, F9.

Out of scope here: journaling of the other ops (package/kernel/service), journal rotation, and known-good snapshot
marking (direction spec §4.4). They reuse `journal.rs` later.

## 9. Decided questions

1. Pruning: automatic after a verified boot, keep two, with the exclusions in §6 (owner, 2026-11-08).
2. Pending rollback: refuse package/upgrade/kernel ops and a second rollback, in R-A (owner, 2026-11-08).
3. Fault injection: development-only; package build and both release gates refuse it (owner, 2026-11-08; §7.1).
