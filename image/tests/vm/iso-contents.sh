#!/usr/bin/env bash
# Prove the installer gate, step/verify scripts and the whole Calamares configuration inside an ISO are
# byte-identical to this working tree (every git-tracked file under image/calamares/), and report what the ISO trusts.
#   image/tests/vm/iso-contents.sh [image/out/torchos-*.iso]      (needs docker; reads the ISO only)
# Exit 0 only if every file is present and identical.
set -u
cd "$(dirname "$0")/../../.." || exit 2
ISO=${1:-$(ls -t image/out/*.iso 2>/dev/null | head -1)}
[ -f "${ISO:-}" ] || { echo "no ISO" >&2; exit 2; }
echo "ISO: $ISO  sha256: $(sha256sum "$ISO" | cut -d' ' -f1)"
echo "tree: $(git rev-parse HEAD)$(git diff --quiet HEAD -- image/calamares || echo ' + UNCOMMITTED changes in image/calamares')"
docker run --rm -v "$(readlink -f "$(dirname "$ISO")"):/iso:ro" -v "$PWD/image/calamares:/src:ro" -e ISO="$(basename "$ISO")" \
  -e FILES="$(git ls-files image/calamares | sed "s|^image/calamares/||")" \
  archlinux:base-devel bash -c '
  pacman -Sy --noconfirm --needed squashfs-tools libisoburn openssh >/dev/null 2>&1 || { echo "cannot install squashfs-tools/libisoburn"; exit 2; }
  osirrox -indev "/iso/$ISO" -extract /arch/x86_64/airootfs.sfs /tmp/a.sfs >/dev/null 2>&1 || { echo "cannot extract airootfs.sfs"; exit 2; }
  unsquashfs -q -d /tmp/x /tmp/a.sfs usr/lib/torchos etc/calamares usr/share/calamares etc/torch-dev-build \
    etc/ssh/dev_authorized_keys usr/share/pacman/keyrings/torchos-trusted var/lib/pacman/local >/dev/null 2>&1
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
  while IFS= read -r f; do   # git-tracked files only: build leftovers (__pycache__) are not part of the tree
    n=$((n + 1))
    if [ ! -e "/tmp/x/$f" ]; then echo "MISSING  $f"; rc=1; continue; fi
    a=$(sha256sum < "/tmp/x/$f" | cut -c1-16); b=$(sha256sum < "$f" | cut -c1-16)
    [ "$a" = "$b" ] && echo "same     $a $(stat -c %a "/tmp/x/$f") $f" || { echo "DIFFERS  iso=$a tree=$b $f"; rc=1; }
  done <<<"$FILES"
  [ -e /tmp/x/etc/ssh/dev_authorized_keys ] && [ ! -e /tmp/x/etc/torch-dev-build ] && rc=1
  echo "$n files compared, result: $([ $rc = 0 ] && echo IDENTICAL || echo MISMATCH)"
  exit $rc'
