#!/usr/bin/env bash
# Publish image/repo/ (signed with the PRODUCTION key: run sign-repo.sh first) as assets of the rolling GitHub
# release that installed systems use as [torchos].
#   publish-repo.sh                         verify + dry run: shows what would be uploaded, uploads nothing
#   publish-repo.sh --publish OWNER/REPO    really upload; OWNER/REPO must equal the committed destination
# Refuses unless verify-release.sh accepts the exact files to upload (production key from origin/master, databases
# match the packages, production keyring package) and this script + the verifier are the reviewed origin/master copies.
# Upload order keeps clients working if it stops halfway: packages first (a filename the live database already lists
# is never replaced with different bytes), databases last, then the remote copy is checked. Needs `gh auth login`.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
fail() { echo "REFUSED: $*" >&2; exit 1; }
case "$#:${1:-}" in
  0:) CONFIRM= ;;
  2:--publish) CONFIRM=$2 ;;
  *) echo "usage: $0 [--publish OWNER/REPO]" >&2; exit 2 ;;
esac
for f in image/scripts/publish-repo.sh image/scripts/verify-release.sh; do
  git show "origin/master:$f" 2>/dev/null | cmp -s - "$f" || fail "$f differs from origin/master: publish only with reviewed tooling"
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/stage; mkdir "$S"
# Release assets cannot be symlinks: stage real copies under the names pacman asks for, then verify the stage itself.
for f in torchos.db torchos.db.sig torchos.files torchos.files.sig; do
  cp -L "image/repo/$f" "$S/$f" 2>/dev/null || fail "image/repo/$f missing (build-packages.sh + sign-repo.sh)"
done
# Stage only what the database names (older builds left in image/repo are not published); the verifier checks it all.
for f in $(tar -xOf "$S/torchos.db" --wildcards '*/desc' | awk '/^%FILENAME%$/{getline; print}'); do
  f=$(basename "$f"); cp "image/repo/$f" "$S/" 2>/dev/null || true; cp "image/repo/$f.sig" "$S/" 2>/dev/null || true
done
image/scripts/verify-release.sh repo "$S" 3>"$T/dest"
read -r DEST TAG < "$T/dest"
[[ -z ${GH_REPO:-} || $GH_REPO == "$DEST" ]] || fail "GH_REPO=$GH_REPO is not the authorized destination $DEST"
unset GH_REPO

if [[ -z $CONFIRM ]]; then
  ls "$S" | sed 's/^/  would upload /'
  echo "dry run: nothing uploaded. To publish: $0 --publish $DEST"
  exit 0
fi
[[ $CONFIRM == "$DEST" ]] || fail "--publish $CONFIRM is not the authorized destination $DEST"

gh release view "$TAG" -R "$DEST" >/dev/null 2>&1 ||
  gh release create "$TAG" -R "$DEST" --title "TorchOS package repository" --latest=false \
    --notes "Rolling pacman repository (signed). Not a release: packages are replaced in place."
remote=$(gh release view "$TAG" -R "$DEST" --json assets -q '.assets[].name')
# What the LIVE database promises clients: "<filename> <sha256>".
mkdir "$T/live"; : > "$T/live.list"
if grep -qx torchos.db <<<"$remote"; then
  gh release download "$TAG" -R "$DEST" -p torchos.db -D "$T/live"
  tar -xOf "$T/live/torchos.db" --wildcards '*/desc' |
    awk '/^%FILENAME%$/{getline f} /^%SHA256SUM%$/{getline; print f, $0}' > "$T/live.list"
fi
up=()
for p in "$S"/*.pkg.tar.zst; do
  f=$(basename "$p"); s=$(sha256sum < "$p" | cut -d' ' -f1)
  live=$(awk -v f="$f" '$1==f{print $2}' "$T/live.list")
  if [[ -n $live ]]; then
    [[ $live == "$s" ]] || fail "$f is live with different contents: bump pkgrel instead of replacing it"
    grep -qx "$f.sig" <<<"$remote" && continue
  fi
  up+=("$p" "$p.sig")
done
# Packages first: until the databases change, clients only see what the old database lists.
(( ${#up[@]} )) && gh release upload "$TAG" -R "$DEST" --clobber "${up[@]}"
# shortcut: GitHub has no atomic multi-asset swap; db and db.sig go in one call to keep the mismatch window short.
gh release upload "$TAG" -R "$DEST" --clobber "$S/torchos.files" "$S/torchos.files.sig"
gh release upload "$TAG" -R "$DEST" --clobber "$S/torchos.db" "$S/torchos.db.sig"

# Check what is live now, not what we meant to send.
mkdir "$T/after"
for f in torchos.db torchos.db.sig torchos.files torchos.files.sig; do
  gh release download "$TAG" -R "$DEST" -p "$f" -D "$T/after"
  cmp -s "$S/$f" "$T/after/$f" || fail "remote $f is not what was uploaded: rerun this script"
done
remote=$(gh release view "$TAG" -R "$DEST" --json assets -q '.assets[].name')
for p in "$S"/*.pkg.tar.zst "$S"/*.pkg.tar.zst.sig; do
  grep -qx "$(basename "$p")" <<<"$remote" || fail "$(basename "$p") missing remotely: rerun this script"
done
echo "published $((${#up[@]} / 2)) new packages ($(ls "$S"/*.pkg.tar.zst | wc -l) listed) to $DEST release $TAG"
