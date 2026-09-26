# Known issues / verification status

VERIFIED = observed working in a QEMU/OVMF VM on a blank disk. UNVERIFIED = written, not observed.
The authoritative summary is `docs/handoff.md`; this file is the per-item table.

| area | status |
|---|---|
| `torchd` + `torch` CLI (snapshot/update/service/rollback via socket, systemd unit) | VERIFIED |
| `torch doctor/diagnose/gpu` typed output + exit codes | VERIFIED (host, unit tests, installed VM: exit 0) |
| package manifests resolve against Arch repos | VERIFIED |
| TorchOS packages + wlogout + calamares build in an Arch container | VERIFIED |
| live ISO builds, boots (UEFI/OVMF), renders Hyprland + installer | VERIFIED |
| Calamares erase-disk Btrfs install on a blank disk, no manual patching | VERIFIED |
| installed system boots without the ISO; desktop; `doctor` all OK | VERIFIED |
| checkpoint -> change -> `torch snapshot rollback` -> reboot; `/home` kept | VERIFIED |
| pacman transactions through `torchd` get automatic pre/post snapshots (snap-pac) | VERIFIED |
| packaged `torchd.service` (CAP_SYS_PTRACE, no PrivateDevices) from a clean install | fix verified by drop-in; clean-install re-verification pending |
| booting a snapshot from the GRUB "TorchOS snapshots" submenu | UNVERIFIED (entry exists) |
| CachyOS kernel/repo | not included (decision 0001) |
| BIOS install, LUKS, manual partitioning, dual boot, Secure Boot | unsupported / untested |
| real hardware, NVIDIA, suspend/resume | untested |
| hosted package repo (installed systems cannot update `torch-*`) | not built |

## Known defects (not fixed)
- Live session: `systemd-loop@sr0.service` fails (cosmetic; `doctor` reports the live session degraded).
- `torch-welcome` does not wrap a long failed-services line.
- `hyprpaper` wallpaper does not render in the VM (DRM/GBM), see CLAUDE.md gotchas.
- `torch update` right after boot can fail if the network is not up yet.
- GRUB boots `linux-lts` by default (it sorts as newest); the regular `linux` kernel is under Advanced options.
