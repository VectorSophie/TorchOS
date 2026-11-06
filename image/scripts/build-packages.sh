#!/usr/bin/env bash
# Build TorchOS packages (+ reviewed AUR recipes from packages/aur.txt) into a local
# pacman repo at image/repo/ using an Arch container. Output: image/repo/torchos.db.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
OUT=$ROOT/image/repo
WORK=$ROOT/image/build/pkgwork
mkdir -p "$OUT" "$WORK"
rm -rf "$WORK/torchos" && mkdir -p "$WORK/torchos"
cp pkg/torchos/{PKGBUILD,torchd.sysusers,os-release,torchos-os-release.hook,torchos-keyring.install} pkg/torchos/keyring/* "$WORK/torchos/"
# Working-tree source snapshot (no target/, no VM images).
tar --exclude=target -czf "$WORK/torchos/torchos-src.tar.gz" \
  --transform 's,^,src/,' torch dotfiles image/calamares assets/branding/logo-badge.png assets/branding/icons assets/branding/wallpaper.png assets/branding/wallpaper-light.png
AUR=$(sed 's/#.*//' packages/aur.txt | tr -s ' \n' ' ')
PINNED=$(sed 's/#.*//' packages/arch-pinned.txt | awk 'NF == 3 {printf "%s@%s@%s ", $1, $2, $3}')
docker run --rm -e AUR="$AUR" -e PINNED="$PINNED" -e HOST_UID="$(id -u):$(id -g)" -v "$WORK:/work" -v "$OUT:/out" archlinux:base-devel bash -euxc '
  pacman -Syu --noconfirm git
  echo "OPTIONS+=(!debug)" >> /etc/makepkg.conf
  useradd -m builder && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/b
  chown -R builder /work /out
  # Our own packages.
  su builder -c "cd /work/torchos && makepkg -sf --noconfirm"
  # Reviewed AUR recipes, each built against what we already have.
  for p in $AUR; do
    ls /out/$p-[0-9]*.pkg.tar.zst >/dev/null 2>&1 && { cp /out/$p-[0-9]*.pkg.tar.zst /work/; continue; }  # cached
    su builder -c "cd /work && rm -rf $p && git clone --depth 1 https://aur.archlinux.org/$p.git && cd $p && (source PKGBUILD; [ \${#validpgpkeys[@]} -eq 0 ] || gpg --keyserver keyserver.ubuntu.com --recv-keys \"\${validpgpkeys[@]}\") && makepkg -sf --noconfirm"
  done
  # Arch recipes pinned ahead of [extra] (packages/arch-pinned.txt): exact commit and version, recipe unmodified.
  for e in $PINNED; do
    IFS=@ read -r p v c <<<"$e"
    ls /out/$p-$v-*.pkg.tar.zst >/dev/null 2>&1 && { cp /out/$p-$v-*.pkg.tar.zst /work/; continue; }  # cached
    su builder -c "cd /work && rm -rf $p && git clone -q https://gitlab.archlinux.org/archlinux/packaging/packages/$p.git && cd $p && git checkout -q $c && test \"\$(git rev-parse HEAD)\" = $c && test \"\$(source PKGBUILD; echo \$pkgver-\$pkgrel)\" = $v && makepkg -sf --noconfirm"
  done
  cp /work/*/*.pkg.tar.zst /out/
  rm -f /out/*-debug-*.pkg.tar.zst
  cd /out && rm -f torchos.db* torchos.files* && repo-add torchos.db.tar.gz *.pkg.tar.zst
  chown -R $HOST_UID /out
'
ls -la "$OUT"
