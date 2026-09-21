# Bootloader: GRUB (installed) / syslinux+systemd-boot (live)

Installed: **GRUB + grub-btrfs**, because booting a read-only snapshot from the menu is the one
recovery path that needs no working userspace. systemd-boot/UKI is cleaner but has no snapshot
menu without extra machinery; Limine is not chosen (the Phase 1 VM reproduced a Limine BIOS install
failure, see CLAUDE.md). Live medium: archiso's syslinux (BIOS) and systemd-boot (UEFI), rebranded.
Secure Boot: not supported yet. Encrypted root: offered by Calamares, not yet tested.
