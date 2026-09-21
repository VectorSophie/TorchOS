# TorchOS

A convenient personal Linux desktop built on Arch: Hyprland session, Btrfs + Snapper checkpoints, a
graphical installer, and a small CLI (`torch`) that explains the machine's state.

> Experimentation is invited because important changes are visible, checkpointed, and recoverable.

**Status: pre-release.** See [docs/known-issues.md](docs/known-issues.md) for exactly what is and is
not verified. No AI functionality is included.

## Try it in a VM

```bash
image/scripts/build-packages.sh      # TorchOS packages + reviewed AUR recipes -> image/repo/
image/scripts/build-iso.sh           # live ISO -> image/out/  (needs docker)
image/scripts/run-qemu.sh iso        # boots the ISO against a fresh blank 40G UEFI disk
# install from the live desktop (Calamares opens automatically, or SUPER+I), reboot, then:
image/scripts/run-qemu.sh disk       # boot the installed system with no ISO attached
```

More: [docs/build.md](docs/build.md) · [docs/recovery.md](docs/recovery.md) · [docs/decisions/](docs/decisions/)

## Layout

| path | what |
|---|---|
| `torch/` | Rust workspace: `torch` CLI, `torchd` privileged broker, `torch-welcome` |
| `pkg/torchos/` | PKGBUILD (split package) for everything TorchOS-owned |
| `packages/` | validated package manifests; see its README |
| `image/archiso/`, `image/calamares/` | live ISO profile and installer configuration |
| `dotfiles/` | Hyprland/Waybar/Wofi defaults (chezmoi-shaped; shipped via `torch-config`) |
| `assets/branding/` | logo, icons, wallpapers |
| `docs/superpowers/` | specs and plans (source of truth for design intent) |
| `legacy/v1/` | the previous distro, kept for reference only |
