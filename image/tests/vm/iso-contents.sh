#!/usr/bin/env bash
# Prove the installer gate and step scripts inside an ISO are byte-identical to this working tree.
#   image/tests/vm/iso-contents.sh [image/out/torchos-*.iso]      (needs docker; reads the ISO only)
# STATUS: drafted 2026-11-02, never executed. See README.md.
set -u
cd "$(dirname "$0")/../../.." || exit 2
ISO=${1:-$(ls -t image/out/*.iso 2>/dev/null | head -1)}
[ -f "${ISO:-}" ] || { echo "no ISO" >&2; exit 2; }
FILES="usr/lib/torchos/torch-target-setup usr/lib/torchos/torch-target-verify
usr/lib/torchos/calamares/modules/torchpreflight/main.py usr/lib/torchos/calamares/modules/torchpreflight/module.desc
etc/calamares/settings.conf etc/calamares/modules/partition.conf etc/calamares/modules/shellprocess_verify.conf"
echo "ISO: $ISO  sha256: $(sha256sum "$ISO" | cut -d' ' -f1)"
docker run --rm -v "$(readlink -f "$(dirname "$ISO")"):/iso:ro" -v "$PWD/image/calamares:/src:ro" -e ISO="$(basename "$ISO")" -e FILES="$FILES" \
  archlinux:base-devel bash -c '
  pacman -Sy --noconfirm --needed squashfs-tools libisoburn >/dev/null 2>&1 || { echo "cannot install squashfs-tools/libisoburn"; exit 2; }
  osirrox -indev "/iso/$ISO" -extract /arch/x86_64/airootfs.sfs /tmp/a.sfs >/dev/null 2>&1 || { echo "cannot extract airootfs.sfs"; exit 2; }
  unsquashfs -q -d /tmp/x /tmp/a.sfs usr/lib/torchos etc/calamares >/dev/null 2>&1
  [ -e /tmp/x/etc/torch-dev-build ] || unsquashfs -q -d /tmp/y /tmp/a.sfs etc/torch-dev-build >/dev/null 2>&1
  [ -e /tmp/y/etc/torch-dev-build ] && echo "image type: DEV (sshd + key baked in, never distribute)" || echo "image type: release"
  rc=0
  for f in $FILES; do
    if [ ! -e "/tmp/x/$f" ]; then echo "MISSING  $f"; rc=1; continue; fi
    a=$(sha256sum < "/tmp/x/$f" | cut -c1-16); b=$(sha256sum < "/src/$f" | cut -c1-16)
    [ "$a" = "$b" ] && echo "same     $a $(stat -c %a "/tmp/x/$f") $f" || { echo "DIFFERS  iso=$a tree=$b $f"; rc=1; }
  done
  exit $rc'
