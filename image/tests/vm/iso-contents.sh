#!/usr/bin/env bash
# Prove the installer gate, step/verify scripts and the whole Calamares configuration (every git-tracked file under
# image/calamares/), the new-user desktop config (/etc/skel/.config, incl. Hyprland) and the live-session scripts
# (/usr/local/bin) inside an ISO are byte-identical to this working tree, and report what the ISO trusts.
#   image/tests/vm/iso-contents.sh [image/out/torchos-*.iso]      (needs docker; reads the ISO only)
# Exit 0 only if every file is present and identical.
set -u
cd "$(dirname "$0")/../../.." || exit 2
ISO=${1:-$(ls -t image/out/*.iso 2>/dev/null | head -1)}
[ -f "${ISO:-}" ] || { echo "no ISO" >&2; exit 2; }
echo "ISO: $ISO  sha256: $(sha256sum "$ISO" | cut -d' ' -f1)"
echo "tree: $(git rev-parse HEAD)$(git diff --quiet HEAD -- image/calamares || echo ' + UNCOMMITTED changes in image/calamares')"
# "<tree path> <path in the image>" pairs, git-tracked files only (build leftovers such as __pycache__ are not the tree).
FILES=$( { git ls-files image/calamares | sed 's|^image/calamares/\(.*\)|image/calamares/\1 \1|'
           git ls-files dotfiles/dot_config | sed 's|^dotfiles/dot_config/\(.*\)|& etc/skel/.config/\1|'
           git ls-files image/archiso/airootfs/usr/local/bin | sed 's|^image/archiso/airootfs/\(.*\)|& \1|'; } | tr -s ' ')
docker run --rm -v "$(readlink -f "$(dirname "$ISO")"):/iso:ro" -v "$PWD:/src:ro" -e ISO="$(basename "$ISO")" -e FILES="$FILES" \
  archlinux:base-devel bash -c '
  pacman -Sy --noconfirm --needed squashfs-tools libisoburn openssh >/dev/null 2>&1 || { echo "cannot install squashfs-tools/libisoburn"; exit 2; }
  osirrox -indev "/iso/$ISO" -extract /arch/x86_64/airootfs.sfs /tmp/a.sfs >/dev/null 2>&1 || { echo "cannot extract airootfs.sfs"; exit 2; }
  unsquashfs -q -d /tmp/x /tmp/a.sfs usr/lib/torchos etc/calamares usr/share/calamares etc/torch-dev-build \
    etc/ssh/dev_authorized_keys usr/share/pacman/keyrings/torchos-trusted var/lib/pacman/local etc/skel/.config \
    usr/local/bin >/dev/null 2>&1
  [ -s /tmp/x/usr/lib/torchos/torch-target-setup ] || { echo "unsquashfs extracted nothing usable"; exit 2; }
  if [ -e /tmp/x/etc/torch-dev-build ]; then
    echo "image type: DEV (sshd + key baked in, never distribute): $(ssh-keygen -lf /tmp/x/etc/ssh/dev_authorized_keys 2>/dev/null || echo key unreadable)"
  else
    echo "image type: release (no /etc/torch-dev-build$([ -e /tmp/x/etc/ssh/dev_authorized_keys ] && echo ", BUT dev_authorized_keys PRESENT"))"
  fi
  echo "torchos-keyring trusts: $(cut -d: -f1 /tmp/x/usr/share/pacman/keyrings/torchos-trusted | tr "\n" " ")"
  echo "torch-installer-config in the image: $(ls /tmp/x/var/lib/pacman/local | grep -E "^(torch-installer-config|calamares)-[0-9]" | tr "\n" " ")"
  rc=0 n=0
  cd /src
  while read -r src f; do
    n=$((n + 1))
    if [ ! -e "/tmp/x/$f" ]; then echo "MISSING  $f"; rc=1; continue; fi
    a=$(sha256sum < "/tmp/x/$f" | cut -c1-16); b=$(sha256sum < "$src" | cut -c1-16)
    [ "$a" = "$b" ] && echo "same     $a $(stat -c %a "/tmp/x/$f") $f" || { echo "DIFFERS  iso=$a tree=$b $f"; rc=1; }
  done <<<"$FILES"
  # Hyprland >= 0.57 ignores hyprlang configs and would autogenerate its stock one if hyprland.lua were missing.
  for f in etc/skel/.config/hypr/hyprland.conf etc/skel/.config/hypr/bindings.conf etc/skel/.config/hypr/conf.d; do
    [ -e "/tmp/x/$f" ] && { echo "LEGACY   $f"; rc=1; }
  done
  [ -e /tmp/x/etc/ssh/dev_authorized_keys ] && [ ! -e /tmp/x/etc/torch-dev-build ] && rc=1
  echo "$n files compared, result: $([ $rc = 0 ] && echo IDENTICAL || echo MISMATCH)"
  exit $rc'
