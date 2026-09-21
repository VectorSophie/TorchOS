#!/usr/bin/env bash
# Build the TorchOS live ISO with mkarchiso inside a privileged Arch container.
# Prereq: image/scripts/build-packages.sh (creates image/repo/, the local `torchos` repo).
# Output: image/out/torchos-<version>-x86_64.iso + .sha256 + package manifest.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
[[ -f image/repo/torchos.db ]] || { echo "run image/scripts/build-packages.sh first" >&2; exit 1; }
P=$ROOT/image/build/profile
mkdir -p "$ROOT/image/build"
# Previous runs may have left root-owned files; clean as root.
docker run --rm -v "$ROOT/image/build:/b" archlinux:base-devel bash -c "rm -rf /b/profile /b/work"
mkdir -p "$P" "$ROOT/image/out" "$ROOT/image/build/work"
cp -a image/archiso/. "$P/"

# Development-only: bake an SSH key + sshd into the ISO (DEV_SSH_PUBKEY=/path/to/key.pub). Never for releases.
if [[ -n "${DEV_SSH_PUBKEY:-}" ]]; then
  echo ">>> DEV BUILD: sshd enabled, key from $DEV_SSH_PUBKEY baked in - do not distribute this ISO" >&2
  mkdir -p "$P/airootfs/etc/ssh/sshd_config.d" "$P/airootfs/etc/systemd/system/multi-user.target.wants"
  cp "$DEV_SSH_PUBKEY" "$P/airootfs/etc/ssh/dev_authorized_keys"
  echo 'AuthorizedKeysFile /etc/ssh/dev_authorized_keys' > "$P/airootfs/etc/ssh/sshd_config.d/10-dev.conf"
  ln -sf /usr/lib/systemd/system/sshd.service "$P/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"
  touch "$P/airootfs/etc/torch-dev-build"
fi

# Package list = manifests (live+base+desktop+hardware) + TorchOS packages + reviewed AUR recipes.
{
  for f in live base desktop hardware; do sed 's/#.*//' packages/$f.txt; done
  echo torch-cli torch-welcome torch-config torch-branding torch-release torch-installer-config
  sed 's/#.*//' packages/aur.txt
  echo qemu-guest-agent spice-vdagent terminus-font
} | tr -s ' \n' '\n' | grep -v '^$' | sort -u > "$P/packages.x86_64"

# Build-time pacman.conf: official repos + our local repo (unsigned, build-only; not shipped).
# The container image ships NoExtract rules (locales, man pages, docs, even etc/pacman.conf); an ISO built
# with them would be missing all of that. Strip them.
docker run --rm archlinux:base-devel cat /etc/pacman.conf | sed "/^NoExtract/d" > "$P/pacman.conf"
cat >> "$P/pacman.conf" <<'CONF'

[torchos]
SigLevel = Optional TrustAll
Server = file:///repo
CONF

docker run --rm --privileged \
  -v "$P:/profile" -v "$ROOT/image/repo:/repo:ro" -v "$ROOT/image/out:/out" -v "$ROOT/image/build/work:/work" \
  -e HOST_UID="$(id -u):$(id -g)" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}" \
  archlinux:base-devel bash -euxc '
    trap "chown -R \$HOST_UID /out /profile /work" EXIT
    pacman -Syu --noconfirm archiso >/dev/null
    R=/usr/share/archiso/configs/releng
    # Reuse releng boot menus, rebranded.
    cp -a $R/efiboot $R/syslinux /profile/
    # Live keyring init (tmpfs gnupg dir + populate), as in releng; removed again on the installed system.
    cp $R/airootfs/etc/systemd/system/pacman-init.service $R/airootfs/etc/systemd/system/etc-pacman.d-gnupg.mount /profile/airootfs/etc/systemd/system/
    ln -sf /etc/systemd/system/pacman-init.service /profile/airootfs/etc/systemd/system/multi-user.target.wants/pacman-init.service
    sed -i "s/Arch Linux install medium/TorchOS Live/g; s/Arch Linux/TorchOS/g" \
      $(grep -rl "Arch Linux" /profile/efiboot /profile/syslinux --include=*.conf --include=*.cfg)
    rm -rf /work/*
    mkarchiso -v -w /work -o /out /profile
    cd /out && for f in *.iso; do sha256sum "$f" > "$f.sha256"; done
    chown -R $HOST_UID /out /profile /work
  '
ls -la image/out
