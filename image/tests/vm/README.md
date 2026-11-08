# Installer verification in QEMU (installation-correctness slice)

**Status (2026-11-04):** installation correctness verified in QEMU (`docs/verification/2026-11-04-install-correctness-vm.md`);
the Hyprland 0.57 Lua migration (D1) is verified in `docs/verification/2026-11-04-hyprland-lua-vm.md`. The live
session must start Calamares by itself: `wait_calamares` only watches for the window. Only `relaunch_calamares`
(after a test-only edit of the live Calamares config in `rejected.sh`/`failure.sh`) starts it by hand.

A harness failure is not a product failure, and production code should not be bent to suit the harness.

## How the scripts decide

- Every check is `assert`/`pass`/`fail` (`lib.sh`) and goes to `image/vm/evidence/results.tsv`. A scenario exits 0
  and prints `<scenario>: PASS` only if no check failed; `DEFECT` lines record known defects outside the scenario.
- Rejections (`rejected.sh`) are judged by Calamares' job log (the gate is the only job started, every later job is
  `Skipping non-emergency job`) and by the disk state seen from the live session (sfdisk table, wipefs signatures
  with offsets, blkid UUIDs), before vs after. `qemu-img compare` is informational.
- Boots are identified by `boot_id`, kernels by `/usr/lib/modules/$(uname -r)/pkgbase`, the fallback initramfs by
  the size the kernel reports in `Freeing initrd memory`.
- Safety: QEMU's SSH forward and VNC listen on 127.0.0.1 only (asserted on every launch); a scenario stops only the
  QEMU PID it started and refuses to start if ports 2222/5901 are taken.
- `drive_install.py`: exit 0 = Calamares succeeded, 1 = Calamares reported failure, 3 = no verdict (harness).
  `TORCH_PARTITION_ACTION` runs a live-session command on the partition page (B4-B6 click with `ydotool`, installed
  into the live session's RAM overlay: VNC/monitor pointer events never reach Hyprland).

| script | what |
|---|---|
| `iso-contents.sh` | every git-tracked file under `image/calamares/`, `dotfiles/dot_config/` (as `/etc/skel/.config`) and the live `usr/local/bin` scripts is byte-identical in the ISO, no legacy `hyprland.conf`; image type (DEV/release); trusted repo key |
| `supported.sh` | A: blank-disk install, independent boot, greetd login, installed user's TorchOS desktop (`assert_torch_desktop`), step record, doctor, repo trust (accept/refuse), Snapper + GRUB snapshot menu, linux-lts + fallback initramfs, rollback across a reboot, boot-chain check cost |
| `rejected.sh` | B1 BIOS, B2 swap, B3 ext4, B4 replace, B5 alongside, B6 encryption: all refused before any disk write |
| `existing.sh` | D: erase over an existing install with a second data disk that must stay byte-identical; boot the result |
| `failure.sh` | F: fallback loader with empty NVRAM; C: injected required-step failure stops the install (no rollback) |
| `desktop.sh` | E: live desktop on the Lua config: Calamares autostarts maximized with no harness help, TorchOS styling/binds/session programs (each once), keyboard shortcuts, config reload, SUPER+I |
| `rc-smoke.sh` | release ISO (no `DEV_SSH_PUBKEY`): boots, no SSH, doctor, installer reachable by keyboard |
| `f0-exchange.sh` | F0 (0003 §7): `renameat2(RENAME_EXCHANGE)` of `@` and a snapshot copy, with sync/no-sync power cuts, plus the old two-rename window (expected `grub rescue>`). Needs `A-installed.qcow2` + `A-installed.vars` (copy of `OVMF_VARS.fd` after `supported.sh`) |
| `recovery-ra.sh` | R-A: builds this tree's torchd (release + `fault-injection`), copies it onto overlays only, F1-F5, F12-F14: crash at each rollback step, pending refusal, rollback to a pre-R-A torchd. `SSH_PORT` selects another forwarded port if 2222 is taken |

## Confirmed in the VM (formerly assumptions)

- GlobalStorage on the supported path: `firmwareType='efi'`, `partitionChoices={'install': 'erase', 'swap': 'none'}`,
  `defaultFileSystemType='btrfs'`, no passphrase; BIOS gives `firmwareType='bios'`, and replace/alongside/encryption
  show up as `install: 'replace'|'alongside'` and a set `luksPassphrase`.
- A failed job makes Calamares skip every later non-emergency job; `umount` still runs as `EMERGENCY JOB`.
- Calamares 3.4.2 logs Python jobs by module name (`Starting job "torchpreflight" ( 1 / 30 )`), not `pretty_name()`,
  and on failure its last log line is `completion: failed`.
- Shellprocess output is only logged on failure; the target's `/var/log/torchos-install.log` (in the `@log` subvolume)
  always has it.

## Prerequisites (Linux host)

- KVM, QEMU, OVMF (`/usr/share/OVMF/OVMF_CODE_4M.fd`), docker, python3, ImageMagick (`vnc.py shot` is
  RFB-native, `qmon.py shot` needs `convert`), and about **25 GB free disk**: about 10 GB for the ISO build
  under `image/build/`, plus about 5 GB per installed qcow2 and overlays.
- Memory: 3 GiB per VM (`VMRAM`), one VM at a time, plus the build containers.
- A throwaway test password in `TORCH_TEST_PW` or `image/vm/.testpw`, and an SSH key pair for the dev ISO
  (`ssh-keygen -t ed25519 -N '' -f ~/.ssh/torchos_vm`).
- **The repo signing key** (GnuPG home `~/.torchos-signing`, fingerprint
  `FD561EDBA8080AA625A935E075870B90E4C34AC8`) is needed by `image/scripts/sign-repo.sh`, and the ISO build refuses
  an unsigned repo. It lives on the old Windows/WSL machine and isn't in git. Either transfer it securely, or, for
  local verification only, sign with a throwaway key (`TORCHOS_GNUPGHOME`) and, in the working tree only, put its
  public key in `pkg/torchos/keyring/torchos.gpg` and its fingerprint in `torchos-trusted` (`supported.sh` reads the
  trusted key from there). Never commit that swap. `publish-repo.sh` and `verify-release.sh` refuse a swapped
  working tree and any test-key-signed repo/ISO: restore with `git checkout -- pkg/torchos/keyring` afterwards.

```bash
image/tests/run.sh                                             # static + unit + 25 container scenarios
image/scripts/build-packages.sh && image/scripts/sign-repo.sh
DEV_SSH_PUBKEY=~/.ssh/torchos_vm.pub image/scripts/build-iso.sh   # dev ISO: never distribute
image/tests/vm/iso-contents.sh
image/tests/vm/supported.sh && image/tests/vm/rejected.sh && image/tests/vm/existing.sh && image/tests/vm/failure.sh
image/scripts/build-iso.sh && ISO=<that iso> image/tests/vm/rc-smoke.sh      # release ISO smoke
image/scripts/verify-release.sh iso <that iso>                 # release gate: refuses test keyring / dev SSH
```

## Cleanup boundaries

The scripts write only under `image/vm/` (qcow2 disks, `.vars`, `evidence/` including `qemu.log`).
`image/build/`, `image/out/` and `image/repo/` belong to the build scripts. All of these are gitignored and can be
deleted freely. Nothing here touches a host disk, the host bootloader, or the signing key's contents.
