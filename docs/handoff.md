# TorchOS handoff (2026-09-27, second session)

For a fresh Claude Code session, on the Linux machine **or on Windows (WSL2)**. Read `CLAUDE.md` first (rules and
locked decisions), then this file. Nothing has been pushed: `master` is ahead of `origin/master`, and the
package repository has not been published (section 4, item 1).

## 1. Where things stand

The journey below was executed in QEMU/OVMF, on a freshly created blank virtual disk, with **no manual
patching inside the guest** (driven by `image/scripts/dev/drive_install.py`):

1. Build packages, sign the repo, build a live ISO from the repo.
2. Boot the ISO (UEFI). Autologin, Hyprland + Waybar + `torch-welcome`, Calamares maximized. `torch doctor`
   in the live session: all OK, no failed units.
3. Calamares erase-disk install: GPT, 512 MiB ESP, Btrfs with `@ @home @log @cache @snapshots`.
4. Detach the ISO. The disk boots by itself: GRUB defaults to the `linux` kernel (LTS under Advanced options),
   greetd/tuigreet asks for the login, Hyprland starts.
5. `torch doctor` exits 0, every check OK (incl. login manager and the `[torchos]` repo), no failed units.
6. `torch update` upgrades through `torchd` against the **signed** `[torchos]` repo (served locally for the test).
7. `torch kernel add linux-cachyos` -> confirmation -> checkpoint -> CachyOS repo + key -> kernel -> GRUB regenerated;
   the CachyOS kernel boots (7.2.7-1-cachyos) and doctor stays green.
8. GRUB *TorchOS snapshots* -> a pre-change snapshot boots on a temporary overlay; writes work and are gone after
   the next normal boot. `torch doctor` says which snapshot is booted and how to keep it.
9. `torch install`: repo package, AUR (`--aur`, PKGBUILD review, base-devel pulled in on demand), AppImage (fuse2 on
   demand), Distrobox (Debian container, CLI exported to `~/.local/bin`).
10. `torch snapshot create` -> change -> `torch snapshot rollback N` -> reboot -> change gone, `/home` kept.

Final confirmation run (2026-09-28, last ISO of the session, no manual patching): install OK in ~5 min; the
installed disk boots `linux`, GRUB shows only *TorchOS Linux / Advanced options / TorchOS snapshots*, installer
packages gone, one clean "fresh install" snapshot, torchd unit without `ProtectKernelModules`, doctor all OK.

| area | status |
|---|---|
| `torchd` broker, `torch` CLI, hardened unit | VERIFIED |
| confirmation tokens: single use, bound to op + args + uid, 5 min TTL | VERIFIED (unit tests + live socket probe) |
| package manifests + validator; split PKGBUILD (7 packages incl. `torchos-keyring`); AUR recipes | VERIFIED |
| signed package repo (`sign-repo.sh`), ISO build requires valid signatures | VERIFIED |
| live ISO boots (UEFI/OVMF), renders, doctor green (systemd-loop@sr0 masked) | VERIFIED |
| Calamares blank-disk erase install (btrfs, GRUB) | VERIFIED |
| installed system: greetd login, GRUB default `linux`, doctor green | VERIFIED |
| `torch update` (full upgrade) against the signed `[torchos]` repo | VERIFIED (repo served from the dev host) |
| `torch kernel add linux-cachyos` (CachyOS layer) + booting it | VERIFIED |
| GRUB snapshot submenu: boot a read-only snapshot (overlay) | VERIFIED |
| `torch install`: pacman / AUR / AppImage / Distrobox | VERIFIED |
| `torch install`: Flathub | name resolution VERIFIED; a real Flatpak install not exercised (runtime download size) |
| `torch install`: `.exe/.msi` via Wine, `.rpm` via Fedora box | written, not exercised |
| checkpoint + change + rollback across a reboot | VERIFIED |
| hosted repo on GitHub Releases | scripts ready, **not published** (needs the owner's go) |
| BIOS/legacy boot, LUKS, manual partitioning, dual boot, Secure Boot | **not tested / unsupported** |
| real hardware (any) | **not tested** |

## 2. Resume on Linux

Needs: Docker (user in `docker` group), QEMU + KVM, OVMF (`/usr/share/OVMF`), ImageMagick `convert`, ~15 GB disk,
~4 GB free RAM for the VM.

```bash
scripts/check-manifests.sh                       # every package name resolves in Arch repos (or is in aur.txt)
image/scripts/build-packages.sh                  # -> image/repo/  (pacman repo: torchos.db + packages)
image/scripts/sign-repo.sh                       # sign packages + db with ~/.torchos-signing (see section 6)
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

## 3. Resume on Windows: WSL2 runs the whole loop

The earlier assumption ("no KVM on Windows") was wrong for this machine: WSL2 exposes **nested KVM** (`/dev/kvm`),
and Docker runs natively inside WSL. Everything in section 2 runs there, including the Calamares install (~5 min; ~18 min when Windows is short of RAM)
and reboots. This session's full verification was done this way.

Setup that exists on the owner's machine:
- `C:\Users\PC\.wslconfig`: `memory=10GB`, `processors=6` (was 4GB/3; the ISO build + a 3.5 GB VM do not fit in 4).
- The repo cloned **inside WSL** at `/root/torch-os` (remote `win` = the Windows checkout, `origin` = GitHub). Do not
  build from `/mnt/c`: a native Windows checkout loses the 10 committed symlinks (`core.symlinks=false`) and
  the ISO silently loses those services. Check with `git ls-files -s | awk '$1==120000'`.
- The WSL user is root, so no sudo prompts; the trust-boundary rules in CLAUDE.md still apply to the guest.

**Differences from the Linux host:**
- WSL's kernel has no `udmabuf`, so `RENDER=blob` does not work. Use **`RENDER=virgl`**: virgl 3D through WSLg's GL,
  `-display gtk,gl=on` (a QEMU window opens on the Windows desktop) plus VNC on :1 for scripted input. Hyprland
  renders (GL ES 3.2 on virgl/llvmpipe); `grim` inside the guest works. Plain std VGA does **not** work (no render node).
- The monitor's `screendump` fails with a GL display; use `image/scripts/dev/vnc.py shot out.png`.
- Background processes started from a `wsl.exe` call die when that call returns; keep long jobs (builds, QEMU) in one
  foreground `wsl.exe` invocation (Claude Code: `run_in_background`).
- Editing files under `\\wsl.localhost\...` from Windows tools drops the executable bit. `git diff --summary` shows it;
  `chmod +x` before building.
- Boots are slower (nested virt + software GL): ~1m45s to `graphical.target`, first boot after a kernel install longer.

## 4. Open work, by priority

1. **Publish the package repo** *(owner decision; outward-facing)*. `image/scripts/publish-repo.sh` uploads the signed
   repo to the rolling GitHub release `repo`; installed systems already point at
   `https://github.com/VectorSophie/TorchOS/releases/download/repo`. **Until it is published, `torch update` on an
   installed system fails** at "failed to retrieve some files" for `torchos`. Back up `~/.torchos-signing` (the private
   signing key, WSL only) before anything else happens to that machine.
2. **Release ISO**: rebuild without `DEV_SSH_PUBKEY` from the final tree, smoke-test live boot, record the checksum
   (section 5).
3. **Real hardware** (Phase 6): nothing has run outside QEMU. Intel iGPU first (i915 default), then suspend/resume.
4. **Flatpak and Wine paths of `torch install`**: exercise a real Flathub install and an `.exe` on a machine with the
   bandwidth for the runtimes.
5. **`hyprpaper` wallpaper** does not render in the VM (DRM/GBM permission, see CLAUDE.md gotchas); unknown on real hardware.
6. **VM resolution**: under virgl the guest picks 640x480 despite `xres/yres`; set a Hyprland `monitor=` rule for
   Virtual-1 if screenshots need more room (VM-only cosmetic).
7. **AUR dependencies**: `torch install --aur` installs repo dependencies but refuses AUR-only ones (each must be
   reviewed and installed first). A dependency named only by a `provides=` alias is also treated as AUR-only.
8. **Not built yet**: LUKS, BIOS install, dual boot, Secure Boot (sbctl), GPU-specific driver selection at install
   time, `torch kernel remove`, Calamares window rule (still done by `calamares-launch`).
9. **Reproducibility**: builds are *repeatable*, not bit-for-bit. Pin package versions / snapshot the Arch repo
   (e.g. the Arch Linux Archive) to go further.
10. **AI (Phase 3)**: intentionally not started. Token validation (a prerequisite for a non-interactive client) is done.

## 5. Release-candidate checklist (not complete)

- [x] one documented command sequence builds the ISO (`docs/build.md`)
- [x] no reusable plaintext credential committed (`image/vm/user_credentials.json` untracked; old value remains in
      git history: rewrite only with the owner's say-so). The signing key's private half is not in the repo.
- [x] VM disks and ISOs ignored by Git
- [x] `docs/known-issues.md` reconciled with section 1 above
- [ ] package repo published (section 4, item 1)
- [ ] release ISO rebuilt from the final tree without `DEV_SSH_PUBKEY`, smoke-tested, checksum recorded
      (the 2026-09-26 release ISO predates this session's fixes)
- [ ] install and recovery guides walked through by someone who did not write them

## 6. Supported / unsupported (today)

Supported: UEFI, QEMU/KVM virtio, a single blank disk, automatic erase-disk install to Btrfs, GRUB.
Unsupported or untested: BIOS, LUKS, manual/dual-boot partitioning, Secure Boot, NVIDIA, real hardware,
non-English installs (Korean input packages are in the manifest but not exercised).

## 7. Things that are NOT in the repo (recreate them)

- `~/.torchos-signing` (in WSL): GnuPG home with the **repo signing key** (ed25519, fingerprint
  `FD561EDBA8080AA625A935E075870B90E4C34AC8`, no passphrase). Its public half is `pkg/torchos/keyring/torchos.gpg`.
  Losing it means generating a new key, shipping a new `torchos-keyring`, and re-signing everything.
- `~/.ssh/torchos_vm` (dev SSH key) and `image/vm/.testpw` (throwaway test password): both local, both ignored.
- The ISO, package repo, VM disks: build/create them (`image/out`, `image/repo`, `image/vm` are gitignored).
  `image/vm/fresh-install.qcow2` (+ `.vars`) is a saved just-installed disk for quick re-tests.

## 8. Decision records

`docs/decisions/`: `0001-base-and-composition.md` (incl. the CachyOS kernel layer), `btrfs-layout.md` (incl. the
rollback mechanism), `bootloader.md`. Specs and plans: `docs/superpowers/`. The torchd plan has a STATUS block
listing every deviation.
