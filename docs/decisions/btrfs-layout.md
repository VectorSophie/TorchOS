# Btrfs layout and what rollback covers

| subvolume | mount | rolled back with `/`? |
|---|---|---|
| `@` | `/` | yes: this is what a snapshot captures and what a rollback replaces |
| `@snapshots` | `/.snapshots` | no: separate on purpose, so swapping `@` never loses snapshots |
| `@home` | `/home` | **no**: personal data persists across rollback |
| `@log` | `/var/log` | no: logs survive so you can see why you rolled back |
| `@cache` | `/var/cache` | no: package cache is not worth snapshotting |

Mount options: `noatime,compress=zstd:1`. Swap: none; zram (`ram/2`, zstd). Snapshots are **not
backups**: they live on the same disk. `/home` is not snapshotted by default.

## Rollback mechanism (`torchd` `snapshot.rollback`)
`snapper rollback` assumes a SUSE-style default-subvolume layout and fails here (observed: exit failure
on the first ISO install). TorchOS boots `subvol=/@` explicitly, so torchd instead: mounts the
top-level (`subvolid=5`), snapshots `/.snapshots/N/snapshot` to `@.rollback-new`, renames `@` to
`@.pre-rollback-<UTC time>`, renames the new one to `@`, unmounts. The running system is untouched
until reboot; the old root is kept (delete it with `btrfs subvolume delete` once you are sure).
Steps are ordered so a failure leaves the original `@` in place.

## Kernels
`/boot` lives inside `@`, so kernels and initramfs roll back *with* the system and stay consistent.
GRUB and the ESP hold only the bootloader. Note for kernel files: GRUB's btrfs driver cannot read a
file whose tail is a hole, so kernel images are copied densely (`cp --sparse=never`) at install time.

Not yet tested: databases, containers, VM images under `/var/lib` (they roll back with `@`).
