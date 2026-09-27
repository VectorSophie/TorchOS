# Known issues / verification status

VERIFIED = observed working in a QEMU/OVMF VM on a blank disk. UNVERIFIED = written, not observed.
The authoritative summary is `docs/handoff.md`; this file is the per-item table.

| area | status |
|---|---|
| `torchd` + `torch` CLI (snapshot/update/service/rollback via socket, systemd unit) | VERIFIED |
| confirmation tokens (single use, bound to op + args + caller, 5 min) | VERIFIED |
| `torch doctor/diagnose/gpu/hardware` typed output + exit codes | VERIFIED (host, unit tests, installed VM: exit 0) |
| package manifests resolve against Arch repos | VERIFIED |
| TorchOS packages + wlogout + calamares build in an Arch container; repo signed | VERIFIED |
| live ISO builds, boots (UEFI/OVMF), renders Hyprland + installer; live doctor green | VERIFIED |
| Calamares erase-disk Btrfs install on a blank disk, no manual patching | VERIFIED |
| installed system boots without the ISO; greetd login; desktop; `doctor` all OK | VERIFIED |
| GRUB defaults to `linux`; `linux-lts` under Advanced options | VERIFIED |
| checkpoint -> change -> `torch snapshot rollback` -> reboot; `/home` kept | VERIFIED |
| pacman transactions through `torchd` get automatic pre/post snapshots (snap-pac) | VERIFIED |
| `torch update` (full upgrade) against the signed `[torchos]` repo | VERIFIED (repo served locally; not yet hosted) |
| booting a snapshot from the GRUB "TorchOS snapshots" submenu (temporary overlay) | VERIFIED |
| `torch kernel add linux-cachyos` + booting the CachyOS kernel | VERIFIED |
| `torch install`: repo, AUR (`--aur`), AppImage, Distrobox | VERIFIED |
| `torch install`: Flathub | name resolution VERIFIED, install UNVERIFIED |
| `torch install`: `.exe`/`.msi` (Wine), `.rpm` (Fedora box) | UNVERIFIED |
| BIOS install, LUKS, manual partitioning, dual boot, Secure Boot | unsupported / untested |
| real hardware, NVIDIA, suspend/resume | untested |
| hosted package repo | scripts ready, not published: **`torch update` fails on installed systems until it is** |

## Known defects (not fixed)
- `hyprpaper` wallpaper does not render in the VM (DRM/GBM), see CLAUDE.md gotchas.
- Booted snapshot: `systemd-remount-fs.service` fails (fstab's btrfs options cannot apply to the overlay root).
  Harmless; `torch doctor` expects it and explains the snapshot boot instead.
- `torch install --aur` does not build AUR-only dependencies; install each one first (each gets its own review).
- Under virgl (WSL2 dev loop) the guest display comes up at 640x480.
