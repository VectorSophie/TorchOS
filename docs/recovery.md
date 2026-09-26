# Recovery

1. **Checkpoint before you experiment:** `torch snapshot create "why"`. pacman transactions run through
   `torch update` are snapshotted automatically (`snap-pac` pre/post pairs, labelled with the command).
2. **See what changed:** `snapper -c root list`, `snapper -c root status <a>..<b>` (members of `wheel` can read).
3. **Make a rollback:** `torch snapshot rollback <id>` (asks for confirmation). It prepares the swap and you
   **reboot to complete it**. `torchd` builds a writable copy of the snapshot, renames the current `@` to
   `@.pre-rollback-<UTC time>` and installs the copy as `@`. `/home`, logs, caches and the snapshots
   themselves are not touched. If anything fails part-way the original `@` stays in place.
   *Verified across a real reboot:* a system file and an installed package reverted, a file in `/home` remained.
4. **Undo a rollback / reclaim space:** the previous root is kept as `@.pre-rollback-*` on the top-level
   filesystem. Delete it once you are sure: mount `subvolid=5`, `btrfs subvolume delete @.pre-rollback-...`.
5. **System will not boot:** in the GRUB menu, *Advanced options* offers the other kernel (`linux` and
   `linux-lts`, plus fallback initramfs images); *TorchOS snapshots* lists snapshots to boot read-only.
   *Not yet verified:* booting from the snapshots submenu.

Snapshots are **not backups**: they live on the same disk. Layout and rationale: `docs/decisions/btrfs-layout.md`.
