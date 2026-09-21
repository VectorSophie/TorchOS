#!/usr/bin/env bash
# Build the TorchOS live ISO with mkarchiso inside a privileged Arch container.
# Prereq: image/scripts/build-packages.sh (creates image/repo/, the local `torchos` repo).
# Output: image/out/torchos-<version>-x86_64.iso + .sha256 + package manifest.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
[[ -f image/repo/torchos.db ]] || { echo "run image/scripts/build-packages.sh first" >&2; exit 1; }
P=$ROOT/image/build/profile
rm -rf "$P"; mkdir -p "$P" "$ROOT/image/out" "$ROOT/image/build/work"
cp -a image/archiso/. "$P/"

# Package list = manifests (live+base+desktop+hardware) + TorchOS packages + reviewed AUR recipes.
{
  for f in live base desktop hardware; do sed 's/#.*//' packages/$f.txt; done
  echo torch-cli torch-welcome torch-config torch-branding torch-release torch-installer-config
  sed 's/#.*//' packages/aur.txt
  echo qemu-guest-agent spice-vdagent terminus-font
} | tr -s ' \n' '\n' | grep -v '^$' | sort -u > "$P/packages.x86_64"

# Build-time pacman.conf: official repos + our local repo (unsigned, build-only; not shipped).
docker run --rm archlinux:base-devel cat /etc/pacman.conf > "$P/pacman.conf"
cat >> "$P/pacman.conf" <<'CONF'

[torchos]
SigLevel = Optional TrustAll
Server = file:///repo
CONF

docker run --rm --privileged \
  -v "$P:/profile" -v "$ROOT/image/repo:/repo:ro" -v "$ROOT/image/out:/out" -v "$ROOT/image/build/work:/work" \
  -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}" \
  archlinux:base-devel bash -euxc '
    pacman -Syu --noconfirm archiso >/dev/null
    R=/usr/share/archiso/configs/releng
    # Reuse releng boot menus, rebranded.
    cp -a $R/efiboot $R/syslinux /profile/
    sed -i "s/Arch Linux install medium/TorchOS Live/g; s/Arch Linux/TorchOS/g" \
      $(grep -rl "Arch Linux" /profile/efiboot /profile/syslinux --include=*.conf --include=*.cfg)
    rm -rf /work/*
    mkarchiso -v -w /work -o /out /profile
    cd /out && for f in *.iso; do sha256sum "$f" > "$f.sha256"; done
    pacman -Sp --print-format "%n %v" >/dev/null 2>&1 || true
  '
ls -la image/out
