#!/usr/bin/env bash
# Publish image/repo/ (signed: run sign-repo.sh first) as assets of the rolling GitHub release `repo`.
# Installed systems use: Server = https://github.com/VectorSophie/TorchOS/releases/download/repo
# Needs `gh auth login`. Outward-facing: run it deliberately.
set -euo pipefail
cd "$(dirname "$0")/../../image/repo"
REPO=${GH_REPO:-VectorSophie/TorchOS}
[[ -f torchos.db.tar.gz.sig ]] || { echo "repo is not signed; run image/scripts/sign-repo.sh" >&2; exit 1; }
# Release assets cannot be symlinks: upload real copies under the names pacman asks for.
stage=$(mktemp -d)
trap 'rm -r "$stage"' EXIT
for f in torchos.db torchos.db.sig torchos.files torchos.files.sig; do cp -L "$f" "$stage/$f"; done
gh release view repo -R "$REPO" >/dev/null 2>&1 ||
  gh release create repo -R "$REPO" --title "TorchOS package repository" --latest=false \
    --notes "Rolling pacman repository (signed). Not a release: packages are replaced in place."
gh release upload repo -R "$REPO" --clobber "$stage"/* ./*.pkg.tar.zst ./*.pkg.tar.zst.sig
echo "published $(ls ./*.pkg.tar.zst | wc -l) packages to $REPO release repo"
