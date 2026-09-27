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
RAM=4096 image/scripts/run-qemu.sh iso   # boots the ISO against a fresh blank 40G UEFI disk (GTK window; RAM=4096 recommended)
# install from the live desktop (Calamares opens automatically, or SUPER+I), reboot, then:
image/scripts/run-qemu.sh disk       # boot the installed system with no ISO attached
```

## The `torch` command

| command | what it does |
|---|---|
| `torch doctor` | health checks with plain-language fixes (exit 0 healthy, 1 degraded, 2 unsupported) |
| `torch status` / `hardware` / `gpu` / `diagnose` | host summary, CPU level + GPU drivers + firmware, JSON for scripts |
| `torch update [pkg...]` | full system upgrade (or install repo packages with one); automatic pre/post snapshots |
| `torch install <name or file>` | repo -> Flathub -> AUR (`--aur`, shows the PKGBUILD) -> Distrobox (`--distrobox`); files: `.pkg.tar.zst`, `.AppImage`, `.flatpakref`, `.exe/.msi`, `.deb`, `.rpm` |
| `torch remove <pkg...>` | remove packages (asks first) |
| `torch kernel list` / `add <name>` | kernels; `add linux-cachyos` enables the CachyOS kernel layer |
| `torch snapshot list` / `create "why"` / `rollback N` | checkpoints and whole-system rollback (keeps `/home`) |
| `torch service restart <unit>` | restart a service (asks first) |

Everything that needs root goes through `torchd`, which checks who is asking, asks for confirmation where it
matters, and logs every request to `/var/log/torchd/audit.jsonl`.

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
