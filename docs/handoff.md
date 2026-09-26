# TorchOS handoff (2026-09-27)

For a fresh Claude Code session, on this Linux machine **or on Windows**. Read `CLAUDE.md` first (rules and
locked decisions), then this file. Nothing has been pushed: `master` is ahead of `origin/master`.

## 1. Where things stand

The journey below was executed in QEMU/OVMF, on a freshly created blank virtual disk, with **no manual
patching inside the guest** (driven by `image/scripts/dev/drive_install.py`):

1. Build packages and a live ISO from the repo.
2. Boot the ISO (UEFI). Autologin, Hyprland + Waybar + `torch-welcome`, Calamares maximized.
3. Calamares erase-disk install: GPT, 512 MiB ESP, Btrfs with `@ @home @log @cache @snapshots`.
4. Detach the ISO. The disk boots by itself: GRUB (with a *TorchOS snapshots* submenu and a fallback
   kernel), login on tty1 starts Hyprland.
5. `torch doctor` exits 0, every check OK, no failed units.
6. `torch snapshot create` -> change a system file, install a package (`snap-pac` adds pre/post snapshots),
   write a file in `/home` -> `torch snapshot rollback N` -> reboot -> the system change and the package
   are gone, the `/home` file is kept, snapshots are intact.

| area | status |
|---|---|
| `torchd` broker, `torch` CLI, hardened unit | VERIFIED |
| package manifests + validator; split PKGBUILD; AUR recipes (`wlogout`, `calamares`) | VERIFIED |
| live ISO boots (UEFI/OVMF) and renders | VERIFIED |
| Calamares blank-disk erase install (btrfs, GRUB) | VERIFIED |
| installed system boots unattended, desktop, `doctor` green | VERIFIED |
| checkpoint + change + rollback across a reboot | VERIFIED |
| GRUB "TorchOS snapshots" submenu **content** (booting a read-only snapshot) | entry exists; **not booted** |
| booting the `linux-lts` fallback explicitly | the installed default already boots lts; the `linux` entry not separately booted |
| BIOS/legacy boot, LUKS, manual partitioning, dual boot, Secure Boot | **not tested / unsupported** |
| real hardware (any) | **not tested** |
| release-candidate artifacts (final checksum, install guide review) | partial: see section 5 |

## 2. Resume on Linux (the only place the VM tests run)

Needs: Docker (user in `docker` group), QEMU + KVM, OVMF (`/usr/share/OVMF`), ImageMagick `convert`, ~15 GB disk,
~4 GB free RAM for the VM.

```bash
scripts/check-manifests.sh                       # every package name resolves in Arch repos (or is in aur.txt)
image/scripts/build-packages.sh                  # -> image/repo/  (pacman repo: torchos.db + packages)
image/scripts/build-iso.sh                       # -> image/out/torchos-*.iso + .sha256
image/scripts/run-qemu.sh iso                    # boots ISO on a fresh blank disk (image/vm/torchos-test-blank-01.qcow2)
image/scripts/run-qemu.sh disk                   # boots the installed disk, no ISO
image/scripts/run-qemu.sh blank-reset            # new blank disk + fresh UEFI variables
```

Dev loop with SSH + serial console (never distribute that ISO):

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/torchos_vm
DEV_SSH_PUBKEY=~/.ssh/torchos_vm.pub image/scripts/build-iso.sh
DISPLAY_MODE=vnc RAM=3584 image/scripts/run-qemu.sh iso &
VM_USER=liveuser image/scripts/dev/vmssh.sh 'systemctl is-system-running'
TORCH_TEST_PW=<throwaway> VM_USER=liveuser image/scripts/dev/drive_install.py   # drive Calamares end to end
```

Read `image/scripts/dev/README.md` before touching the harness: it records the traps that cost hours.

## 3. Resume on Windows (border)

A Windows session **cannot** run the acceleration this project's VM tests need: there is no KVM, and the
scripts are bash. Split the work like this.

**Do on Windows, inside WSL2 (Ubuntu), with the repo cloned into the WSL filesystem (`~/`, not `/mnt/c`):**
- Rust work: `torch/` (`cargo test -p torch -p torchd`; the GTK crate needs `libgtk-4-dev`).
- Package manifests, PKGBUILD, docs, dotfiles, Calamares config, `packages/`.
- `scripts/check-manifests.sh`, `image/scripts/build-packages.sh`, `image/scripts/build-iso.sh` via
  **Docker Desktop with the WSL2 backend** (the ISO build needs `--privileged`, which Docker Desktop allows).
  Expect a 3 GB ISO and ~15 GB scratch; the first build downloads a lot.
- Code review, planning, the open work in section 4 that says "no VM needed".

**Do NOT do on Windows:** the boot/install/rollback verification. QEMU for Windows can run this guest only
with `-accel tcg` (no KVM, ~10-50x slower) or WHPX (untested here); a Calamares install would take hours and
GPU/`blob` rendering will not work. Do those on a Linux/KVM host (this machine, or a Linux VM with nested
virtualization). A Windows session should hand ISO artifacts to a Linux run rather than try to test them.

**Hazards specific to a Windows checkout** (a native Windows `git clone` will break the build):
- The ISO profile relies on **9 committed symlinks** (systemd unit enablement under
  `image/archiso/airootfs/etc/systemd/system/...`, including `systemd-firstboot.service -> /dev/null`).
  Without symlink support they become text files and the ISO silently loses those services. Use WSL2, or
  `git config core.symlinks true` plus Developer Mode. Check with `git ls-files -s | awk '$1==120000'`.
- Shell scripts, `PKGBUILD` and unit files must stay **LF**; `.gitattributes` enforces it. If you see `\r` in
  a script, the checkout is wrong.
- Path separators and `image/vm/*.sock` (Unix sockets) do not exist on native Windows.
- `docker` from WSL2 needs Docker Desktop's WSL integration enabled for that distro.

## 4. Open work, by priority

1. *(done 2026-09-27)* The packaged `torchd` unit (CAP_SYS_PTRACE added, PrivateDevices removed) was
   re-verified from a clean blank-disk install with no drop-ins: `torch update`, snap-pac snapshots,
   `torch snapshot rollback`, reboot, `/home` preserved.
2. **Boot a snapshot from the GRUB submenu** *(Linux/KVM)*: pick *TorchOS snapshots*, boot a read-only snapshot,
   note what happens to writes (grub-btrfs overlay). Update `docs/recovery.md` with the observed result.
3. **Hosted package repo** *(no VM needed)*. Installed systems only know Arch's repos; `torch-*` packages are in a
   build-time-only local repo, so they cannot update. Decide hosting, sign packages, add the repo to the
   installed `pacman.conf`.
4. **CachyOS layer** *(needs VM to verify)*: repo + keyring + kernel opt-in; `docs/decisions/0001`.
5. **Login**: tty1 autologin-to-Hyprland via `/etc/profile.d` works; a display manager (greetd) is the proper
   answer for multi-user and password-locked sessions.
6. **`hyprpaper` wallpaper** does not render in the VM (DRM/GBM permission, see CLAUDE.md gotchas); unknown on real hardware.
7. **Live session**: `systemd-loop@sr0.service` fails on the ISO (cosmetic but makes `doctor` red in the live
   session); the live `torch-welcome` failed-services line is unwrapped/truncated; the installer window rule is
   done by script (`calamares-launch`), not a Hyprland window rule.
8. **`torch update`** always does a full upgrade (`pacman -Syu`); a plain "install one package without upgrading" is
   deliberately not offered (Arch does not support partial upgrades). Failure right after boot can be the network
   not being up yet; the CLI should say so.
9. **Confirmation tokens**: `torchd` accepts any non-empty token (marked `ponytail:`); validate issued tokens
   before any non-interactive client (Phase 3 AI) exists.
10. **Not built yet**: LUKS test, BIOS install, dual boot, Secure Boot, GPU-specific driver selection at install time,
    suspend/resume, `torch kernel/scheduler/hardware` commands, Flatpak/AppImage/Distrobox resolver (Phase 4).
11. **Reproducibility**: builds are *repeatable*, not bit-for-bit. Pin package versions / snapshot the Arch repo
    (e.g. the Arch Linux Archive) to go further.
12. **AI (Phase 3)**: intentionally not started; out of scope until the base is on real hardware.

## 5. Release-candidate checklist (not complete)

- [x] one documented command sequence builds the ISO (`docs/build.md`)
- [x] no reusable plaintext credential committed (`image/vm/user_credentials.json` untracked; old value remains in
      git history: rewrite only with the owner's say-so)
- [x] VM disks and ISOs ignored by Git
- [ ] release ISO built **without** `DEV_SSH_PUBKEY`, checksum recorded, live boot smoke-tested
- [ ] `docs/known-issues.md` reconciled with section 1 above
- [ ] install and recovery guides walked through by someone who did not write them

## 6. Supported / unsupported (today)

Supported: UEFI, QEMU/KVM virtio, a single blank disk, automatic erase-disk install to Btrfs, GRUB.
Unsupported or untested: BIOS, LUKS, manual/dual-boot partitioning, Secure Boot, NVIDIA, real hardware,
non-English installs (Korean input packages are in the manifest but not exercised).

## 7. Things that are NOT in the repo (recreate them)

- `~/.ssh/torchos_vm` (dev SSH key) and `image/vm/.testpw` (throwaway test password): both local, both ignored.
- The ISO, package repo, VM disks: build/create them (`image/out`, `image/repo`, `image/vm` are gitignored).
- Session scratchpads. Anything worth keeping was moved to `image/scripts/dev/`.

## 8. Decision records

`docs/decisions/`: `0001-base-and-composition.md`, `btrfs-layout.md` (incl. the rollback mechanism),
`bootloader.md`. Specs and plans: `docs/superpowers/`. The torchd plan has a STATUS block listing every deviation.
