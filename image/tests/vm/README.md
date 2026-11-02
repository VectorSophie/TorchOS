# Installer verification in QEMU (installation-correctness slice)

**Status (2026-11-02): NOT READY.** The installation-correctness change (the `torchpreflight` gate, the
required/optional step classification in `torch-target-setup`, the boot-chain check `torch-target-verify`) has
passed only static, unit and simulated container tests. No ISO has been built from it, and nothing below has
been observed in a VM. The scripts in this directory were written for that verification and have **never been
executed**: the original Windows/WSL2 host ran out of disk during the ISO build (xorriso, about 73%), and its
WSL filesystem then went read-only. Expect harness fixes on the first run. A harness failure is not a product
failure, and production code should not be bent to suit an unreliable harness.

Not modified by this work: the original WSL worktree (`/root/torch-os`, which holds separate uncommitted LUKS
experiments) and the repo signing key. The build and tests ran in a separate clone. The key was only *used* there,
to sign packages locally; gpg may update its own housekeeping files (`random_seed`, trustdb) in that GnuPG home.
Nothing was published.

## Done, with evidence

| check | result | kind |
|---|---|---|
| `bash -n` on `torch-target-setup`, `torch-target-verify`, test scripts | pass | static |
| shellcheck 0.11.0 `-S warning` on the same | pass (only pre-existing SC2054 false positives in `run-qemu.sh`, QEMU option commas) | static |
| `python3 -m unittest discover -s image/tests -p 'test_*.py'`: 23 tests (gate logic incl. fake Calamares API, config ordering, packaging) | pass | unit |
| `image/tests/run.sh`: 25/25 container scenarios (real scripts against a fake target, stubbed disk/boot/systemd tools) | pass | simulated |
| `image/scripts/build-packages.sh` from this tree (2 CPUs, 3 GiB, `CARGO_BUILD_JOBS=2`): 7 TorchOS packages, repo signed | pass (239 s) | real build |
| ISO build | **did not finish**: host disk full, not a product failure | real build |

## Outstanding (all NOT TESTED)

Run in this order on a native Linux host. Each script prints its evidence and writes screenshots and Calamares
session logs to `image/vm/evidence/` (ignored by git).

1. **ISO contents:** `iso-contents.sh` proves the gate, step scripts and Calamares config inside the ISO are
   byte-identical to the tree.
2. **`supported.sh`, the supported install:**
   - erase install on a blank UEFI disk; record the **real** `torchpreflight` log line (the GlobalStorage values,
     below);
   - boot the disk alone; tuigreet login; `/var/log/torchos-install-steps.tsv` has no FAILED;
   - `torch doctor`; signed `[torchos]` repo; Snapper config; GRUB snapshot menu;
   - `linux-lts` and the `linux` fallback initramfs via `grub-reboot`;
   - checkpoint, change, rollback across a reboot (regression only; the separate snapshot-boot rollback defect
     is out of scope);
   - boot-chain verification cost, cold and warm.
3. **`rejected.sh`:** BIOS (SeaBIOS), plus erase+swap and erase+ext4 (re-enabled in the live config for the test
   only), plus a best-effort keyboard attempt at "Replace a partition". After each VM stops, `qemu-img compare`
   against the base disk shows whether anything was written.
4. **`existing.sh`:** "Erase disk" over an existing installation, with a second data disk that must not change;
   then boot the result.
5. **`failure.sh`:**
   - fallback loader: the installed disk boots with empty firmware variables, which is why a missing NVRAM entry
     is treated as optional;
   - a required-step failure injected in the live session: Calamares reports failure, grubcfg/bootloader don't
     run, and the disk isn't bootable. Nothing written before the failure is restored, and that is expected.
6. **Not part of any script:** build a release ISO without `DEV_SSH_PUBKEY`, run `iso-contents.sh` on it, and
   smoke-boot it.

## Assumptions the VM run must confirm

- The gate reads these GlobalStorage values, taken from the Calamares 3.4.2 source, not yet from a live run:
  - `firmwareType` = `"efi"`, and `/sys/firmware/efi` exists;
  - `partitionChoices` = `{"install": "erase", "swap": "none"}` (set by `Config::setInstallChoice` /
    `setSwapChoice` when `partition.conf` is loaded, so present even if the user never touches the page);
  - `luksPassphrase` = `""` when encryption wasn't chosen;
  - `defaultFileSystemType` = `"btrfs"`.

  If any of these is different on the real path, the gate rejects the supported install. `supported.sh` prints
  the logged values.
- `GlobalStorage["partitions"]` is only filled *after* partitioning (`FillGlobalStorageJob`), so the gate can't
  check the planned layout. `torch-target-setup` checks the actual layout instead.
- A failed job makes Calamares skip all later non-emergency jobs (`JobQueue.cpp`); `umount` is emergency and
  still runs.
- Shellprocess commands run through `/bin/sh -c`, and `${ROOT}` is the target mount point with `dontChroot: true`.
- ESP paths: `EFI/TorchOS/grubx64.efi` and `EFI/boot/bootx64.efi`. GRUB paths: `/@/boot/...`. Both were observed
  on a 2026-09-27 install.

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
  local verification only, sign with a throwaway key (`TORCHOS_GNUPGHOME`) and ship the matching public key in the
  test build's keyring. Never publish packages signed with a throwaway key.

```bash
image/tests/run.sh                                             # static + unit + 25 container scenarios
image/scripts/build-packages.sh && image/scripts/sign-repo.sh
DEV_SSH_PUBKEY=~/.ssh/torchos_vm.pub image/scripts/build-iso.sh   # dev ISO: never distribute
image/tests/vm/iso-contents.sh
image/tests/vm/supported.sh && image/tests/vm/rejected.sh && image/tests/vm/existing.sh && image/tests/vm/failure.sh
```

## Cleanup boundaries

The scripts write only under `image/vm/` (qcow2 disks, `.vars`, `evidence/`) and `/tmp/torch-qemu.log`.
`image/build/`, `image/out/` and `image/repo/` belong to the build scripts. All of these are gitignored and can be
deleted freely. Nothing here touches a host disk, the host bootloader, or the signing key's contents.
