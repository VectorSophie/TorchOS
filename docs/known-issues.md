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
| `torch update` (full upgrade) against the signed `[torchos]` repo | VERIFIED (repo served locally; hosted repo verified separately) |
| booting a snapshot from the GRUB "TorchOS snapshots" submenu (temporary overlay) | VERIFIED |
| `torch kernel add linux-cachyos` + booting the CachyOS kernel | VERIFIED |
| `torch install`: repo, AUR (`--aur`), AppImage, Distrobox | VERIFIED |
| `torch install`: Flathub | name resolution VERIFIED, install UNVERIFIED |
| `torch install`: `.exe`/`.msi` (Wine), `.rpm` (Fedora box) | UNVERIFIED |
| BIOS install, LUKS, manual partitioning, dual boot, Secure Boot | unsupported / untested; the installer is designed to refuse the first four (not yet VM-verified, below) |
| real hardware, NVIDIA, suspend/resume | untested |
| hosted package repo (GitHub release `repo`) | PUBLISHED, pacman sync + signature VERIFIED |
| rollback crash safety, rollback from a booted snapshot, `grub.cfg` replacement, retention | **known defects, not reproduced yet**: `docs/decisions/0003-recovery-integrity.md` (R1-R8) |
| publishing gate (`publish-repo.sh` verifies the production key at origin/master; dry run by default) | merged (PR #3, 2026-11-08); container-tested with a mock backend; read-only check of the live repo OK; never published through |

## Installer: what it accepts

> **Status: merged to master 2026-11-06 (PR #1); VM-VERIFIED 2026-11-04, not yet released.** Built into an ISO from commit 65ca72b and run in
> QEMU/OVMF on native Linux: supported install, independent boot, rollback, six rejected configurations (BIOS, swap,
> ext4, replace, alongside, encryption: refused before any disk write), erase with a second data disk left
> byte-identical, fallback loader, injected required-step failure. Test-key builds, not published.
> Report: `docs/verification/2026-11-04-install-correctness-vm.md`. The Hyprland 0.57 defect below that blocked it was fixed by PR #2 (merged 2026-11-06).

The one path tested end to end before this change (earlier ISOs): **UEFI firmware, "Erase disk" on one whole disk, GPT, Btrfs (`@ @home @log @cache
@snapshots`), no encryption, no swap partition (zram instead).** The change is designed to refuse everything
else before any disk is written:
- `partition.conf` offers only that: manual partitioning off, encryption checkbox off, Btrfs the only file system,
  swap "none".
- The `torchpreflight` job runs first in the exec phase, before `partition`, and fails the installation, with
  "Nothing on any disk has been changed", on a BIOS boot, any choice other than erase (Calamares still offers
  "alongside"/"replace" on disks that hold an OS and has no option to hide them), a swap partition, an
  encryption passphrase, a non-Btrfs default file system, or any file system other than Btrfs offered on the "Erase disk" page (the user's pick there never reaches GlobalStorage, so the offer itself is checked). A failed job makes Calamares skip all later jobs.
- After partitioning, `torch-target-setup` re-checks the actual result (efivarfs, Btrfs root on `/@`, no dm-crypt,
  GPT, FAT ESP, `@snapshots` in fstab) before relying on it.

Install steps are REQUIRED (failure = no bootable, loggable-in, repo-trusting, recoverable system; the
installation fails and no boot entry is written) or OPTIONAL (recorded, warned, installation continues). The
classification and the reason for each is in `image/calamares/usr/lib/torchos/torch-target-setup`; results are
written to `/var/log/torchos-install-steps.tsv` on the installed system. `torch-target-verify` then checks the
boot chain the bootloader job wrote (grub.cfg parses and its default entry boots `linux` from this disk's `@` (root UUID + subvol), snapshot menu present, EFI
loaders present, GRUB's own btrfs driver reads every kernel and initramfs completely).

## Known defects (not fixed)
- *(fixed on `fix/torchos-hyprland-lua`, 2026-11-04)* Hyprland 0.57 ignored the hyprlang `hyprland.conf` (D1). The
  config is now Lua (`dotfiles/dot_config/hypr/hyprland.lua`), verified in QEMU (`docs/verification/2026-11-04-hyprland-lua-vm.md`).
  Accounts created before the change are not migrated automatically: `docs/upgrade-hyprland-lua.md`.
- *(fixed, 2026-11-06)* Clicking or scrolling waybar's workspace buttons did nothing on Hyprland 0.57: waybar 0.15.0
  sent hyprlang IPC (`dispatch workspace N`), which 0.57 evaluates as Lua. Fixed upstream in waybar 0.16.0 (PR #5013).
  Until Arch's `[extra]` has it, TorchOS ships Arch's unmodified 0.16.0-1 recipe from `packages/arch-pinned.txt`, and
  `torch-config` requires `waybar>=0.16.0`. Remove the pin once `[extra]` has 0.16.0. Verified in QEMU: see
  `docs/verification/2026-11-04-hyprland-lua-vm.md`, 2026-11-06 addendum.
- `hyprpaper` wallpaper does not render in the VM (DRM/GBM), see CLAUDE.md gotchas.
- Booted snapshot: `systemd-remount-fs.service` fails (fstab's btrfs options cannot apply to the overlay root).
  Harmless; `torch doctor` expects it and explains the snapshot boot instead.
- `torch install --aur` does not build AUR-only dependencies; install each one first (each gets its own review).
- Under virgl (WSL2 dev loop) the guest display comes up at 640x480.
