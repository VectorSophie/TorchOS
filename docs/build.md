# Building and testing

Requirements: Linux host with Docker (user in the `docker` group), QEMU/KVM, OVMF, ~15 GB free disk.
Nothing here touches a host disk: all destructive tests use qcow2 files under `image/vm/`.

1. `scripts/check-manifests.sh` - every package in `packages/*.txt` must resolve in the Arch repos
   (or be listed in `aur.txt`).
2. `image/scripts/build-packages.sh` - builds `torch-cli torch-welcome torch-config torch-branding
   torch-release torch-installer-config` from the working tree, plus the AUR recipes in
   `packages/aur.txt` (GPG-verified against the recipe's `validpgpkeys`), into `image/repo/` (a pacman repo).
   AUR builds are cached by name; delete the file in `image/repo/` to rebuild one.
3. `image/scripts/build-iso.sh` - mkarchiso in a privileged container -> `image/out/torchos-*.iso` + `.sha256`.
4. `image/scripts/run-qemu.sh iso` - boot on a fresh blank disk `image/vm/torchos-test-blank-01.qcow2`.
   `run-qemu.sh blank-reset` recreates the blank disk for a repeat run.

**Reproducibility level:** *repeatable* (same commands rerun) but not bit-for-bit: package versions
float with Arch's rolling repos, and the AUR recipes are cloned at HEAD. Pinning is future work.

## Tests
- `cargo test -p torch -p torchd` on any host (the GTK crate needs gtk4 headers; build it in the container/VM).
- The VM checks used during development: see `docs/superpowers/plans/2026-09-10-torchd-phase2.md` (STATUS).
