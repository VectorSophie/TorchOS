# Installation-correctness verification in QEMU (2026-11-04)

Branch `feat/torchos-install-correctness`, **source commit `65ca72bb2e8d4dfcaf14e3e39e037b8f3e8c3f6d`**, plus the
harness-only changes committed on top of it (no file under `image/calamares/`, `image/archiso/`, `torch/`, `pkg/` or
`packages/` differs from 65ca72b). Host: native Linux (Mint 22.2, kernel 6.17, QEMU 8.2.2, OVMF 4M, 8 CPUs, 7.4 GiB RAM), one VM at a
time (3 GiB, 2 vCPU, KVM, virtio-blk, virtio-gpu blob), SSH/VNC on 127.0.0.1 only.

**Recommendation: NOT READY**: the installer slice passed every VM check, but the ISO it ships in has a release-blocking
defect, D1 below.

## Real VM results vs. simulated tests

| kind | what | result |
|---|---|---|
| static | `bash -n` (product + tests), shellcheck 0.11.0 `-S warning` on product scripts and the VM harness | pass (only SC2054 false positives in QEMU argument arrays); re-run on the final tree |
| unit | `python3 -m unittest`: 23 tests (gate logic, config order, packaging) | pass |
| **simulated** | `image/tests/run.sh`: 25/25 container scenarios (real scripts, fake target, stubbed disk/boot tools) | pass (38 s) |
| **real QEMU** | the four scenarios below, on the ISO built from this commit | 155 PASS, 0 FAIL |

## Build provenance

| artifact | value |
|---|---|
| packages | `image/scripts/build-packages.sh` from the tree at 65ca72b, 199 s; `calamares 3.4.2-2` and `wlogout 1.2.2-0` reused, not rebuilt: the published copies were downloaded and verified against the production key (`VALIDSIG FD561EDBA8080AA625A935E075870B90E4C34AC8`), and their AUR recipes are unchanged |
| signing | **isolated TEST key** `1177FDE39B0750367B3490001C063799ED85A4EC` (ed25519, 30-day expiry, GnuPG home outside the repo). The production key is not on this host and was not needed. For the test builds only, `pkg/torchos/keyring/torchos.gpg` and `torchos-trusted` were swapped to the test key in the working tree; the swap was not committed. All 10 packages and the database: `VALIDSIG` by the test key |
| dev ISO | `torchos-DEV-2026.11.04-x86_64.iso`, sha256 `4f9725147f30661534bda07625f0b7bcf68955e95b2ebc36ba0e46fc81acf0ef`, 683 s, disposable SSH key `SHA256:tKdNVerOfoYAKtQ/RYb04I8l0K+mjd4cDQClOrZVQpM`. Never distribute |
| RC ISO | `torchos-RC-TESTKEY-2026.11.04-x86_64.iso`, built **without** `DEV_SSH_PUBKEY`, sha256 `fc92f3a49c7294cc17a1f20b21480c4ce35ca4d97062b67ecb9bc1bb60664816`, 645 s. Same test-signed repo, so it is **not a publishable release**; it exists to detect dependencies on development access |
| ISO contents | `image/tests/vm/iso-contents.sh`: **all 17 git-tracked files under `image/calamares/` are byte-identical in the ISO** (gate module, `torch-target-setup`, `torch-target-verify`, all Calamares config). Image type DEV; keyring trusts only the test key |
| upstream drift | Arch is rolling. This ISO has Hyprland 0.57.1, aquamarine 0.16.0, kernels `linux 7.2.14-arch1-1` and `linux-lts 6.18.60-1-lts`, Mesa 26.2.6 |

Published repo (separate from the test builds): all 11 signatures in the GitHub release `repo` verify with the
production key, and a clean `archlinux:base-devel` container that trusts only that key syncs `[torchos]` and
downloads and verifies `torch-cli` (`pacman -Sy`, `pacman -Sw`: rc 0).

## Scenario matrix (real QEMU)

Commands: `ISO=image/out/torchos-DEV-2026.11.04-x86_64.iso TORCH_VM_KEY=<disposable key> image/tests/vm/<scenario>.sh`.
Every check is an assertion written to `image/vm/evidence/results.tsv` (gitignored); a scenario passes only if all
of them pass. Results are from the last, clean run of each scenario. Earlier runs failed only on harness bugs; they
are listed further down and their evidence is archived.

| scenario | result | checks | wall time |
|---|---|---|---|
| `supported.sh` | **PASS** | 63/63 | 738 s (install 166 s) |
| `rejected.sh` | **PASS** | 53/53 | 646 s |
| `existing.sh` | **PASS** | 20/20 | 375 s |
| `failure.sh` | **PASS** | 19/19 | 554 s |
| `rc-smoke.sh` (RC ISO) | **PASS** | 3/3 + screenshots | 204 s |

### A. Supported installation (`supported.sh`): PASS

- Blank 40 GiB qcow2 (`wipefs` empty), live session in UEFI mode. Calamares erase install: **rc 0 in 166 s** (176 s on run 1).
- **The real GlobalStorage values the gate saw**, which confirm every assumption in the README:
  `/sys/firmware/efi=True firmwareType='efi' partitionChoices={'install': 'erase', 'swap': 'none'} defaultFileSystemType='btrfs' encryption=no`,
  then "supported configuration".
- Job order: `torchpreflight` is job 1/30, before `Clear mounts…` and `Creating new gpt partition table…` (2-9/30). No job skipped.
- Booted from the disk alone (no ISO, no `archiso` on the command line): root `btrfs subvol=/@`, booted kernel `pkgbase` = `linux`.
- Login: tuigreet "Welcome to TorchOS" on tty1, VNC keyboard login. `loginctl` shows `Service=greetd Type=wayland TTY=tty1 Remote=no`, and `Hyprland` runs as the test user.
- Step record: all 9 required steps `ok` (target-layout, remove-live-session, kernel-images, initramfs-config, initramfs, package-trust, login, core-services, snapshots), no required/verify `FAILED`, at least 8 `verify:` checks `ok`, and the install log ends with `boot chain verified`.
- `torch doctor` exit 0 (also after each kernel path and after rollback).
- Repository trust:
  - the installed keyring holds the ISO's repo key;
  - the local test repo (served on host loopback) is accepted: signed db + `torch-cli` download, rc 0;
  - the same repo with `torch-cli`'s signature swapped for another package's is **refused** (`signature … is invalid`, rc 1);
  - the hosted `[torchos]` repo (production key) is **refused** by this test-key build (`key "FD561EDB…" is unknown`, `invalid or corrupted database (PGP signature)`). Trust is enforced, not bypassed. A production-signed build would trust it; that path is covered by the clean-container check above, not by this VM.
- Snapper: config `root`, "TorchOS fresh install" snapshot (important=yes), `/.snapshots` is `[/@snapshots]`. GRUB: `grub.cfg` loads `grub-btrfs.cfg`, which has a submenu with an `@snapshots/1/snapshot` entry.
- Kernel paths via `grub-reboot` (each a new `boot_id`):
  - "with Linux linux-lts" booted `6.18.60-1-lts` (`pkgbase` linux-lts);
  - "linux (fallback initramfs)" booted `linux`, and the kernel freed a 219 632 K initrd, at least the 219 628 K fallback image; the default boot freed 14 428 K;
  - doctor 0 on both.
- Rollback: checkpoint 2 created through `torchd` → `/etc` probe written, random token in `~/home-probe` → `torch snapshot rollback 2` rc 0 → reboot. The probe is gone, the token is unchanged, the root subvolume UUID changed (`986490d3…` → `951e9671…`), both snapshots are still listed, the kernel is still `linux`, and doctor exits 0.
- Boot-chain verification cost:
  - during the install, the `torch-target-verify` job took about 3 s (`torch-target-setup` about 53 s);
  - on the installed system, cold cache: 2.4 s runtime, 2.3 s CPU. The "memory peak" of 1 GiB is page cache from reading 508 MB of kernels and initramfs images, not resident memory;
  - warm cache: 1.6 s, 34 MB;
  - host memory with the VM running: 2.5 GB available.

### B. Unsupported configurations (`rejected.sh`): PASS

All on an overlay of the installed disk, i.e. a disk that holds an OS. Evidence per case:

1. Calamares' job log: **the gate is the only job that started**, with exactly one reason, and every later non-emergency job was skipped (`Skipping non-emergency job "Clear mounts…"`, `"Creating new gpt partition table…"`, … then only `Starting EMERGENCY JOB "Unmounting file systems…"`).
2. The disk as the live session sees it is **identical before and after**: `sfdisk -d` geometry and table, every `wipefs` signature with its offset, every `blkid` UUID and label.

`qemu-img compare` was also identical for all cases, recorded as information only.

| case | how it was produced | gate reason seen |
|---|---|---|
| B1 BIOS | SeaBIOS boot (`firmwareType='bios'`, no `/sys/firmware/efi`) | "started in BIOS/legacy mode" |
| B2 swap | live `partition.conf` re-offers swap, initial choice `small` | "Swap choice 'small'" |
| B3 ext4 | live `partition.conf` offers only ext4 | "File system 'ext4'" |
| B4 replace | "Replace a partition", vda2 clicked (offered by stock config) | "Partitioning choice 'replace'" |
| B5 alongside | "Install alongside", vda2 clicked (offered by stock config) | "Partitioning choice 'alongside'" |
| B6 encryption | live config enables LUKS, "Encrypt system" ticked, passphrase typed | "Disk encryption is not supported" (`encryption=yes`) |

Not driven: manual partitioning (still disabled in config; the gate rejects any choice other than `erase`, which unit tests cover).

### C. Existing-data installation (`existing.sh`): PASS

- Overlay of the installed disk (with `~/home-probe`) plus a separate 1 GiB data disk: ext4 `TORCHDATA` with a marker file, verified before the install.
- Gate accepted. Partition jobs name `/dev/vda` only, and no job mentions `/dev/vdb`.
- vda erased as intended: PTUUID `9933e84a…` → `4e0213dd…`, file-system UUID `686731e4…` → `8e189e5f…`, and the old `home-probe` is absent from the new `@home`.
- vdb **byte-identical** (sha256 of the whole device, `0ae10d0e…`) after the install and again after the first boot of the new system; the marker is readable.
- Independent boot with the ISO detached: root `/dev/vda2[/@]`, kernel `linux`, no required step FAILED, doctor exits 0.

### D. Failure and fallback (`failure.sh`): PASS

- **Fallback loader**: the installed disk with fresh, empty OVMF variables boots through `Boot0001 "UEFI Misc Device"` (auto-created, removable-media path). There is no TorchOS entry, and the kernel is `linux`. This confirms that a missing NVRAM entry is rightly classed OPTIONAL.
- **Required-step failure**: `pacman-key` made non-executable in the target through the live `shellprocess_setup.conf` (test only).
  - Calamares reports failure (rc 1). The gate accepted, then the target's install log says `TORCHOS INSTALL FAILED: required step 'package-trust'`, and the step record shows `required package-trust FAILED` with no later step (`login`) recorded.
  - `grubcfg`, `bootloader` and the verify shellprocess were **skipped, not started**.
  - The ESP holds no GRUB loader and the firmware has no TorchOS entry. The partitions and unpacked files remain: **this is a stop, not a transaction rollback**.
  - Booting that disk without the ISO: QEMU stays up, and nothing boots or answers within 2 min.

## Release-candidate smoke test

`iso-contents.sh` on the RC ISO: **image type release** (no `/etc/torch-dev-build`, no `dev_authorized_keys`), the
same 17 files byte-identical, and the keyring trusts the test key.

`ISO=image/out/torchos-RC-TESTKEY-2026.11.04-x86_64.iso image/tests/vm/rc-smoke.sh` (keyboard and screen only):
- boots, and **nothing answers SSH** (asserted);
- with SUPER+Q (Hyprland's stock binding, because of D1) a terminal shows `torch doctor` all OK and rc 0 (`live ISO: install-only checks skipped`, `torchd active`, `none failed`), `sshd` `inactive`, and no `/etc/torch-dev-build`;
- `calamares-launch` opens the "Welcome to the Calamares installer for TorchOS 0.2" page. The launcher's `hyprctl dispatch` maximize calls fail with Lua syntax errors (D1);
- no dependency on development access was found.

Not done on the RC ISO: a full install, since the release image has no SSH to drive and verify one. The installer
files are byte-identical to the dev ISO's.

## Product defects found

**D1 (release-blocking, outside the installer slice): Hyprland 0.57 ignores TorchOS's whole desktop config.**
Hyprland deprecated the hyprlang `.conf` format in 0.55/0.56 and removed it in 0.57 in favour of `hyprland.lua`.
Arch now ships 0.57.1. Hyprland auto-generates a stock `~/.config/hypr/hyprland.lua` and even an explicit
`-c hyprland.conf` is parsed as Lua. Effects on any ISO built today:
- the live session no longer starts Calamares (`conf.d/live.conf`), waybar, mako, hypridle, hyprpaper or torch-welcome;
- the installed desktop is stock Hyprland: upstream wallpaper, no TorchOS keybinds or bar, and no idle lock (hypridle → hyprlock), which matters for security;
- `calamares-launch`'s `hyprctl dispatch fullscreen 1` uses pre-Lua dispatch syntax.

The September ISOs worked because they predate 0.57. In every scenario the harness records D1 as a `DEFECT` line
and starts `calamares-launch` over SSH, the same command `live.conf` would run, so that the installer itself could
still be verified. **No fix was made**: porting `dotfiles/` and the live config to Lua, or pinning Hyprland, is
desktop-layer work outside this slice's scope and needs an owner decision. Sources:
[Hyprland wiki](https://wiki.hypr.land/Configuring/Start/),
[migration notes](https://github.com/FrancisUsher/nixos-config/issues/10),
[forum](https://forum.hypr.land/t/hyprland-issues-since-lua-configuration/2060).

Observations (not defects in this slice):
- Calamares 3.4.2 logs and shows Python jobs by module name (`torchpreflight`), not their `pretty_name()`, so the user never sees "Checking that this installation is supported" as a progress label. Cosmetic.
- GRUB cannot write `grubenv` on btrfs, so a `grub-reboot` choice is never cleared by GRUB itself and stays in effect until cleared from Linux (`grub-editenv … unset next_entry`). The product does not use `grub-reboot`; the harness clears it.

## Harness changes and harness bugs (not product failures)

Before running, the drafted harness was hardened:
- VNC and the SSH forward bind to 127.0.0.1, in both `run-qemu.sh` and `lib.sh`, and every launch asserts it;
- QEMU is stopped only by the PID the scenario started (re-checked to be `qemu-system-x86`), never by `pkill -f`, and a scenario refuses to start if 2222/5901 are already taken;
- all checks are assertions;
- rejected installs are judged by job order plus partition, signature and UUID state;
- `drive_install.py` exits 3 on timeout, distinct from Calamares' failure (1);
- `iso-contents.sh` compares every tracked file and reports the image type and trusted key.

Bugs found while running, each fixed in the harness and the scenario re-run from the start:
1. `iso-contents.sh` compared an untracked `__pycache__` file; it now uses tracked files only.
2. The gate's job was matched by `pretty_name()`; Calamares logs `"torchpreflight"`.
3. The pattern for the hosted-repo refusal missed `key … is unknown`.
4. `awk '/^\s*UUID:/'` returned nothing under the host's `mawk`; it is now POSIX.
5. `drive_install.py` only recognised success; Calamares 3.4.2's last failure line is `completion: failed`. This caused one 20-minute timeout.
6. The B5 click offset was wrong for the alongside layout.
7. `existing.sh` used `sgdisk`, which is not on the ISO, and listed 0700 home directories without root. The run-1 "home-probe gone" PASS was vacuous; it is now non-vacuous and run 2 passed.
8. `failure.sh` passed a 2 MB log as one `sh -c` argument (128 KiB argv limit) and would have read `/var/log` from `@` rather than `@log`.
9. Pointer input: VNC and monitor pointer events never reach Hyprland, so B4-B6 install `ydotool` into the live session's RAM overlay (test only) and click through uinput.

## Limitations

- QEMU only (virtio, OVMF, SeaBIOS). No real hardware, no Secure Boot, no NVIDIA.
- Test-key builds: the installed system trusts the test key, so its contact with the hosted repo is a verified refusal; the production-key path is covered only by the clean-container check.
- One run per scenario counted (plus the earlier runs that failed on harness bugs). No soak or repeat statistics.
- Manual partitioning was not driven in the UI.
- D1 workaround: Calamares was started by the harness, not by the live session.
- Package versions float with Arch (repeatable, not reproducible builds).

## Commands, in order

```
git worktree add ../TorchOS-verify 65ca72bb2e8d4dfcaf14e3e39e037b8f3e8c3f6d
PATH=<shellcheck 0.11.0 wrapper>:$PATH image/tests/run.sh
image/scripts/build-packages.sh
TORCHOS_GNUPGHOME=<test key home> image/scripts/sign-repo.sh
DEV_SSH_PUBKEY=<disposable key>.pub image/scripts/build-iso.sh      # renamed torchos-DEV-…
image/tests/vm/iso-contents.sh image/out/torchos-DEV-2026.11.04-x86_64.iso
image/tests/vm/supported.sh; image/tests/vm/rejected.sh; image/tests/vm/existing.sh; image/tests/vm/failure.sh
env -u DEV_SSH_PUBKEY image/scripts/build-iso.sh                     # renamed torchos-RC-TESTKEY-…
image/tests/vm/iso-contents.sh image/out/torchos-RC-TESTKEY-2026.11.04-x86_64.iso
ISO=image/out/torchos-RC-TESTKEY-2026.11.04-x86_64.iso image/tests/vm/rc-smoke.sh
```
