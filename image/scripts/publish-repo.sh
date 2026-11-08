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

# Create the release only if GitHub says it does not exist (not on an auth or network error).
if ! err=$(gh release view "$TAG" -R "$DEST" 2>&1 >/dev/null); then
  grep -qi 'not found' <<<"$err" || fail "cannot read release $TAG on $DEST: $err"
  gh release create "$TAG" -R "$DEST" --title "TorchOS package repository" --latest=false \
    --notes "Rolling pacman repository (signed). Not a release: packages are replaced in place."
fi
remote=$(gh release view "$TAG" -R "$DEST" --json assets -q '.assets[].name')
# Decide on BYTES, not names: fetch the live database and every remote asset this upload would reuse or replace.
mkdir "$T/live"; : > "$T/live.list"
for p in "$S"/*; do
  f=$(basename "$p")
  [[ $f == torchos.files* ]] && continue
  grep -qxF "$f" <<<"$remote" && gh release download "$TAG" -R "$DEST" -p "$f" -D "$T/live"
done
# What the LIVE database promises clients: "<filename> <sha256>".
[[ -f $T/live/torchos.db ]] && tar -xOf "$T/live/torchos.db" --wildcards '*/desc' |
  awk '/^%FILENAME%$/{getline f} /^%SHA256SUM%$/{getline; print f, $0}' > "$T/live.list"
up=()
for p in "$S"/*.pkg.tar.zst; do
  f=$(basename "$p"); s=$(sha256sum < "$p" | cut -d' ' -f1)
  live=$(awk -v f="$f" '$1==f{print $2}' "$T/live.list")
  [[ -z $live || $live == "$s" ]] || fail "$f is live with different contents: bump pkgrel instead of replacing it"
  cmp -s "$p" "$T/live/$f" || up+=("$p")            # absent or different remotely (repairs a damaged asset)
  cmp -s "$p.sig" "$T/live/$f.sig" || up+=("$p.sig")
done
# Packages first: until the databases change, clients only see what the old database lists.
(( ${#up[@]} )) && gh release upload "$TAG" -R "$DEST" --clobber "${up[@]}"
# shortcut: GitHub has no atomic multi-asset swap. From here until the check below passes, a client may see a missing
# database or one that does not match its signature (pacman refuses it; nothing wrong is installed). Recovery = rerun.
trap '[[ $? == 0 ]] || echo "INCOMPLETE: the [torchos] databases on $DEST may not match their signatures; rerun this script now" >&2; rm -rf "$T"' EXIT
gh release upload "$TAG" -R "$DEST" --clobber "$S/torchos.files" "$S/torchos.files.sig"
gh release upload "$TAG" -R "$DEST" --clobber "$S/torchos.db" "$S/torchos.db.sig"

# Check what is live now, byte for byte against the verified stage, not what we meant to send.
mkdir "$T/after"
for p in "$S"/*; do
  f=$(basename "$p")
  gh release download "$TAG" -R "$DEST" -p "$f" -D "$T/after" && cmp -s "$p" "$T/after/$f" ||
    fail "remote $f is not what was verified and uploaded"
done
echo "published: $(( ${#up[@]} )) package files uploaded, all $(ls "$S" | wc -l) assets verified byte-identical on $DEST release $TAG"
