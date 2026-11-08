# Recovery

1. **Checkpoint before you experiment:** `torch snapshot create "why"`. pacman transactions run through
   `torch update` are snapshotted automatically (`snap-pac` pre/post pairs, labelled with the command).
2. **See what changed:** `snapper -c root list`, `snapper -c root status <a>..<b>` (members of `wheel` can read).
3. **Make a rollback:** `torch snapshot rollback <id>` (asks for confirmation). It prepares the swap and you
   **reboot to complete it**. `torchd` builds a writable copy of the snapshot and swaps it with the current `@`
   in **one atomic exchange**, so the disk always has a complete `@` (old or new), even after a power cut at any
   point. It then commits the change to disk before it reports success. The current system is kept as
   `@.torchd-<op>.prev`. `/home`, logs, caches and the snapshots themselves are not touched. Every step is
   recorded in `/var/log/torchd/journal.jsonl`; after a crash, `torchd` finishes or undoes the interrupted step
   when it next starts, and records whether the rebooted system is the intended one (`verified`).
   **Until you reboot, `torchd` refuses installs, removals, upgrades, kernel installs and another rollback**:
   they would land in the system being replaced. A full disk can still make a rollback fail (it is refused
   up front when Btrfs metadata space is low); it then reports exactly what state it left.
   *Verified across a real reboot and injected power cuts:* `docs/decisions/0003-recovery-integrity.md` §7.
4. **Undo a rollback / reclaim space:** the previous root is kept as `@.torchd-<op>.prev` (or `@.pre-rollback-*`
   from older versions) on the top-level filesystem. Delete it once you are sure: mount `subvolid=5`,
   `btrfs subvolume delete <name>`. Automatic pruning (keep the two newest) is planned (R-E).
5. **System will not boot:** in the GRUB menu, *Advanced options* offers the other kernels (`linux-lts`, any
   kernel added with `torch kernel add`, plus fallback initramfs images). *TorchOS snapshots* (last entry) lists
   every snapshot; pick one, then a kernel. The snapshot boots on a **temporary overlay**: the desktop works and
   you can write files, but every change vanishes at the next reboot. `torch doctor` says which snapshot you are
   in. To keep that state, run `torch snapshot rollback <N>` from inside it and reboot.
   *Verified:* a pre-change snapshot booted, the later change was absent, writes were gone after a normal reboot.

Snapshots are **not backups**: they live on the same disk. Layout and rationale: `docs/decisions/btrfs-layout.md`.
