#!/usr/bin/env bash
# shellcheck disable=SC2034
iso_name="torchos"
iso_label="TORCHOS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="TorchOS <https://github.com/VectorSophie/TorchOS>"
iso_application="TorchOS Live/Install"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# ponytail: zstd, not xz - ~3x faster to build, ~10% larger ISO. Switch to xz for release builds.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/sudoers.d/99-torch-live"]="0:0:440"
  ["/usr/local/bin/torch-live-setup"]="0:0:755"
  ["/usr/local/bin/calamares-launch"]="0:0:755"
)
