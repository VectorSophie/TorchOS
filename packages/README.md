# Package manifests

One package per line, `#` comments allowed. `scripts/check-manifests.sh` resolves every
name against the official Arch repos inside an Arch container and **fails** on anything
unresolved unless it is listed in `aur.txt` (reviewed AUR recipes, never installed by the
live image) or `flatpak.txt`. A typo therefore breaks the build, not the install.

| file | goes into |
|---|---|
| live.txt | live ISO only (installer, diagnostics) |
| base.txt | every install: kernels, boot, btrfs/snapper, network, audio |
| desktop.txt | Hyprland session, portals, file manager, fonts, theming |
| hardware.txt | firmware/microcode/GPU userspace (installer picks by detection) |
| personal.txt | owner's daily-driver profile (optional at install) |
| development.txt | dev tooling (optional) |
| creative.txt | drawing/media/office (optional) |
| compatibility.txt | Wine/Bottles/Distrobox/Flatpak layer (optional) |
| aur.txt | reviewed AUR packages, installed post-install only |
