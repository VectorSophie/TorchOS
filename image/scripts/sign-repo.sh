#!/usr/bin/env bash
# Sign every package in image/repo/ and rebuild a signed repo database.
# Key: a GnuPG home holding the TorchOS signing key (default ~/.torchos-signing, never in Git).
# Its public half ships as pkg/torchos/keyring/torchos.gpg (torchos-keyring package).
set -euo pipefail
cd "$(dirname "$0")/../.."
KEYHOME=${TORCHOS_GNUPGHOME:-$HOME/.torchos-signing}
[[ -d $KEYHOME ]] || { echo "no signing key at $KEYHOME" >&2; exit 1; }
FPR=$(cut -d: -f1 pkg/torchos/keyring/torchos-trusted)
docker run --rm -v "$KEYHOME:/key:ro" -v "$PWD/image/repo:/repo" -e FPR="$FPR" -e HOST_UID="$(id -u):$(id -g)" \
  archlinux:base-devel bash -euc '
    cp -a /key /tmp/g && chmod 700 /tmp/g && export GNUPGHOME=/tmp/g
    cd /repo
    for p in *.pkg.tar.zst; do
      [[ -f $p.sig ]] && gpg --verify "$p.sig" "$p" 2>/dev/null && continue
      gpg --batch --yes -u "$FPR" --detach-sign --no-armor "$p"
    done
    rm -f torchos.db* torchos.files*
    repo-add --sign --key "$FPR" torchos.db.tar.gz *.pkg.tar.zst
    chown -R "$HOST_UID" /repo'
echo "signed repo in image/repo (key $FPR)"
