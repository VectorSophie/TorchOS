# Btrfs layout and what rollback covers

| subvolume | mount | rolled back with `/`? |
|---|---|---|
| `@` | `/` | yes (this is what snapshots capture) |
| `@home` | `/home` | **no** - personal data persists across rollback |
| `@log` | `/var/log` | no - logs survive so you can see why you rolled back |
| `@cache` | `/var/cache` | no - package cache is not worth snapshotting |
| `@/.snapshots` | `/.snapshots` | created by Snapper, nested in `@` (the layout verified in the Phase 1 VM) |

Mount options: `noatime,compress=zstd:1`. Swap: none; zram (`ram/2`, zstd). Snapshots are **not
backups**: they live on the same disk. `/home` is not snapshotted by default.
Not yet tested: databases, containers, VM images under `/var/lib` (they roll back with `@`).
