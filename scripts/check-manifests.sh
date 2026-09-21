#!/usr/bin/env bash
# Resolve every manifest entry against the official Arch repos in a container.
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD/packages:/p:ro" archlinux:base-devel bash -c '
  pacman -Sy --noconfirm >/dev/null
  rc=0
  for f in /p/*.txt; do
    n=$(basename "$f")
    [[ $n == aur.txt || $n == flatpak.txt ]] && continue
    for pkg in $(sed "s/#.*//" "$f"); do
      pacman -Si "$pkg" >/dev/null 2>&1 || { echo "UNRESOLVED in $n: $pkg"; rc=1; }
    done
  done
  exit $rc'
echo "all manifest entries resolve"
