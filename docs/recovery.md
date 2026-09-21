# Recovery

1. **Checkpoint before you experiment:** `torch snapshot create "why"`. pacman transactions are also
   snapshotted automatically by `snap-pac` (pre/post pairs).
2. **See what changed:** `snapper -c root list`, `snapper -c root status <a>..<b>`.
3. **System won't boot properly:** in the GRUB menu open *Btrfs snapshots* (grub-btrfs) and boot a
   read-only snapshot, or pick the **linux-lts** entry (fallback kernel).
4. **Make a rollback permanent:** from a working session, `torch snapshot rollback <id>` (asks for
   confirmation, takes effect on next reboot). `/home`, logs and caches are not rolled back.

Status: steps 1-2 verified on the Phase 1 VM. Steps 3-4 across a real reboot of an ISO-installed
system are **not yet verified** - see known-issues.
