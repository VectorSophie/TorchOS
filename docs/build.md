# Building and testing

Requirements: Linux host (or WSL2 with nested KVM, see `docs/handoff.md` section 3) with Docker, QEMU/KVM, OVMF,
~15 GB free disk. Nothing here touches a host disk: all destructive tests use qcow2 files under `image/vm/`.

1. `scripts/check-manifests.sh` - every package in `packages/*.txt` must resolve in the Arch repos
   (or be listed in `aur.txt`).
2. `image/scripts/build-packages.sh` - builds `torch-cli torch-welcome torch-config torch-branding
   torch-release torch-installer-config torchos-keyring` from the working tree, plus the AUR recipes in
   `packages/aur.txt` (GPG-verified against the recipe's `validpgpkeys`), into `image/repo/` (a pacman repo).
   AUR builds are cached by name; delete the file in `image/repo/` to rebuild one.
3. `image/scripts/sign-repo.sh` - detached signatures for every package plus a signed repo database, using the
   GnuPG home `~/.torchos-signing` (override: `TORCHOS_GNUPGHOME`). Its public key ships in `torchos-keyring`.
   The ISO build trusts that key and **requires** valid signatures, so an unsigned or stale repo fails loudly.
4. `image/scripts/build-iso.sh` - mkarchiso in a privileged container -> `image/out/torchos-*.iso` + `.sha256`.
   `DEV_SSH_PUBKEY=key.pub` makes a development ISO (sshd + key + serial console): never distribute one.
5. `image/scripts/run-qemu.sh iso` - boot on a fresh blank disk `image/vm/torchos-test-blank-01.qcow2`.
   `run-qemu.sh blank-reset` recreates the blank disk for a repeat run. On WSL2 add `RENDER=virgl`.
6. `image/scripts/publish-repo.sh` - upload the signed repo to the rolling GitHub release `repo`, which installed
   systems use as `[torchos]`. Needs `gh auth login`. Outward-facing: run it deliberately.

**Reproducibility level:** *repeatable* (same commands rerun) but not bit-for-bit: package versions
float with Arch's rolling repos, and the AUR recipes are cloned at HEAD. Pinning is future work.

## Tests
- `cargo test -p torch -p torchd` on any host (the GTK crate needs gtk4 headers; build it in the container/VM).
- The VM checks used during development: `docs/handoff.md` section 1 lists the journey; the harness is
  `image/scripts/dev/` (read its README first).
