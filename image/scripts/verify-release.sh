#!/usr/bin/env bash
# Release gate: prove a package repo or ISO is signed by / trusts ONLY the production TorchOS key.
#   verify-release.sh repo <dir>   dir holds exactly what would be uploaded: torchos.{db,files}{,.sig}, *.pkg.tar.zst{,.sig}
#   verify-release.sh iso <file>   a release ISO: no development access, keyring identical to production
# The trust anchor is the COMMITTED keyring at $TRUST_REF (origin/master), never the working tree: the documented
# test-key workflow swaps pkg/torchos/keyring/* in the tree, and that swap must not redefine "production".
# Prints the authorized destination (OWNER/REPO TAG) on fd 3 if fd 3 is open. Exit 0 only if every check passes.
# Needs git gpg gpgv tar zstd sha256sum (+ osirrox unsquashfs for iso). Reads only; writes a temp dir.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TRUST_REF=origin/master   # deliberately not overridable: a reviewed, merged keyring is the only authority
KR=pkg/torchos/keyring
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GNUPGHOME=$T/gnupg; mkdir -m 700 "$GNUPGHOME"
fail() { echo "REFUSED: $*" >&2; exit 1; }

# --- trust anchor ---
git -C "$ROOT" rev-parse -q --verify "$TRUST_REF^{commit}" >/dev/null || fail "no $TRUST_REF in $ROOT (git fetch origin)"
for f in torchos.gpg torchos-trusted torchos-revoked; do
  git -C "$ROOT" show "$TRUST_REF:$KR/$f" > "$T/$f" || fail "$KR/$f missing at $TRUST_REF"
  # A swapped (test-key) working tree means the repo/ISO was built against the wrong keyring: say so, loudly.
  cmp -s "$T/$f" "$ROOT/$KR/$f" || fail "working-tree $KR/$f differs from $TRUST_REF (test-key swap?): restore it with git checkout"
done
FPR=$(gpg --show-keys --with-colons "$T/torchos.gpg" 2>/dev/null | awk -F: '$1=="pub"{n++} $1=="fpr"&&!f{f=$10} END{if(n==1)print f}')
[[ -n $FPR ]] || fail "committed torchos.gpg must hold exactly one primary key"
[[ $(grep -c . "$T/torchos-trusted") == 1 && $(cut -d: -f1 "$T/torchos-trusted") == "$FPR" ]] ||
  fail "committed torchos-trusted does not name exactly the key in torchos.gpg ($FPR)"
git -C "$ROOT" show "$TRUST_REF:pkg/torchos/torchos-keyring.install" > "$T/keyring.install" ||
  fail "pkg/torchos/torchos-keyring.install missing at $TRUST_REF"
grep -qi "$FPR" "$T/torchos-revoked" && fail "authorized key $FPR is in torchos-revoked"
# Destination = the Server line installed systems actually pull [torchos] from.
SRV=$(git -C "$ROOT" show "$TRUST_REF:image/calamares/usr/lib/torchos/torch-target-setup" |
  grep -o 'Server = https://github.com/[^ \\]*/releases/download/[A-Za-z0-9._-]*' | sort -u)
[[ $(grep -c . <<<"$SRV") == 1 ]] || fail "expected exactly one [torchos] Server URL at $TRUST_REF, got: ${SRV:-none}"
DEST=$(sed -E 's|.*github.com/([^/]+/[^/]+)/releases/download/(.*)|\1 \2|' <<<"$SRV")
{ echo "$DEST" >&3; } 2>/dev/null || true
echo "authorized key $FPR (from $TRUST_REF $(git -C "$ROOT" rev-parse --short "$TRUST_REF")), destination $DEST"

# sig_ok <sig> <file>: gpgv (which sees no other key) accepts the file, and it holds exactly ONE signature, whose
# PRIMARY key is the authorized one. gpgv fails if any signature in the file is bad or from an unknown key.
sig_ok() {
  local st
  [[ -f $1 ]] || { echo "missing signature $(basename "$1")" >&2; return 1; }
  st=$(gpgv --status-fd 1 --keyring "$T/torchos.gpg" "$1" "$2" 2>/dev/null) &&
    [[ $(awk '$2=="VALIDSIG"{print $12}' <<<"$st") == "$FPR" ]] ||
    { echo "bad, extra or unauthorized signature on $(basename "$2")" >&2; return 1; }
}
# A torchd built with the development-only fault-injection feature (docs/decisions/0003-recovery-integrity.md §7.1).
FAULT_MARKER=TORCHD-FAULT-INJECTION-BUILD
# Byte-identical production keyring files under <dir>/usr/share/pacman/keyrings.
keyring_ok() {
  for f in torchos.gpg torchos-trusted torchos-revoked; do
    cmp -s "$T/$f" "$1/usr/share/pacman/keyrings/$f" || { echo "$2: keyrings/$f is not the production one" >&2; return 1; }
  done
}

case ${1:-} in
repo)
  D=${2:?repo dir}; bad=0
  for db in torchos.db torchos.files; do
    sig_ok "$D/$db.sig" "$D/$db" || fail "$db signature"
    mkdir "$T/$db" && tar -xf "$D/$db" -C "$T/$db" || fail "$db unreadable"
    # "<filename> <sha256>" for every package the database advertises.
    find "$T/$db" -name desc | while read -r d; do
      awk '/^%FILENAME%$/{getline f} /^%SHA256SUM%$/{getline s} END{print f, s}' "$d"
    done | sort > "$T/$db.list"
  done
  [[ -s $T/torchos.db.list ]] || fail "database lists no packages"
  cmp -s "$T/torchos.db.list" "$T/torchos.files.list" || fail "torchos.db and torchos.files list different packages"
  while read -r f s; do
    [[ $f == */* || $f != *.pkg.tar.zst ]] && { echo "odd FILENAME $f" >&2; bad=1; continue; }
    [[ -f $D/$f ]] || { echo "database lists $f but it is not here" >&2; bad=1; continue; }
    [[ $(sha256sum < "$D/$f" | cut -d' ' -f1) == "$s" ]] || { echo "$f does not match its database checksum (stale/older file?)" >&2; bad=1; continue; }
    sig_ok "$D/$f.sig" "$D/$f" || bad=1
  done < "$T/torchos.db.list"
  for p in "$D"/*.pkg.tar.zst; do
    awk -v f="$(basename "$p")" '$1==f{n++} END{exit !n}' "$T/torchos.db.list" || { echo "$(basename "$p") is not in the database" >&2; bad=1; }
  done
  # Pacman trust: only torchos-keyring may touch it, with exactly the committed keyring files and install script.
  k=$(awk '$1 ~ /^torchos-keyring-[0-9]/{print $1}' "$T/torchos.db.list")
  [[ $(grep -c . <<<"$k") == 1 ]] || fail "expected exactly one torchos-keyring package, got: ${k:-none}"
  while read -r p _; do
    [[ -f $D/$p ]] || continue
    tar --zstd -tf "$D/$p" 2>/dev/null | grep -v '/$' > "$T/members" || { echo "$p unreadable" >&2; bad=1; continue; }
    if [[ $p == "$k" ]]; then
      grep -vxF -e .PKGINFO -e .BUILDINFO -e .MTREE -e .INSTALL -e usr/share/pacman/keyrings/torchos.gpg \
        -e usr/share/pacman/keyrings/torchos-trusted -e usr/share/pacman/keyrings/torchos-revoked "$T/members" |
        sed "s|^|$p ships unexpected |" | grep . >&2 && bad=1
      rm -rf "$T/kp"; mkdir "$T/kp"; tar --zstd -xf "$D/$p" -C "$T/kp" 2>/dev/null || { echo "$p unreadable" >&2; bad=1; }
      keyring_ok "$T/kp" "$p" || bad=1
      cmp -s "$T/keyring.install" "$T/kp/.INSTALL" || { echo "$p: .INSTALL is not the committed torchos-keyring.install" >&2; bad=1; }
    else
      grep -E '^(usr/share/pacman/keyrings/|etc/pacman\.conf$|etc/pacman\.d/)' "$T/members" |
        sed "s|^|$p touches pacman trust: |" | grep . >&2 && bad=1
      # Extract to a file: piping a large binary into `grep -q` makes tar die of SIGPIPE, and pipefail hides the match.
      if grep -qx usr/bin/torchd "$T/members"; then
        tar --zstd -xOf "$D/$p" usr/bin/torchd > "$T/torchd" 2>/dev/null || { echo "$p: cannot read usr/bin/torchd" >&2; bad=1; }
        grep -qaF "$FAULT_MARKER" "$T/torchd" && { echo "$p: torchd is a fault-injection (development) build" >&2; bad=1; }
      fi
      # Install scripts and libalpm hooks run as root on every system: none but the keyring's may manage keys.
      mapfile -t s < <(grep -E '^\.INSTALL$|\.hook$' "$T/members")
      (( ${#s[@]} )) && tar --zstd -xOf "$D/$p" "${s[@]}" 2>/dev/null | grep -qE 'pacman-key|pacman\.d/gnupg|gpg ' &&
        { echo "$p: install script or hook manages pacman keys" >&2; bad=1; }
    fi
  done < "$T/torchos.db.list"
  [[ $bad == 0 ]] || fail "repository failed verification"
  echo "OK: $(wc -l < "$T/torchos.db.list") packages and both databases signed by $FPR, contents match"
  ;;
iso)
  ISO=${2:?iso file}; X=$T/x; bad=0
  osirrox -indev "$ISO" -extract /arch/x86_64/airootfs.sfs "$T/a.sfs" >/dev/null 2>&1 || fail "cannot extract airootfs.sfs from $ISO"
  # Name checks run on the listing of the WHOLE image (fails on a corrupt image), not on a partial extraction.
  unsquashfs -ls -d '' "$T/a.sfs" > "$T/list" 2>/dev/null || fail "cannot list airootfs.sfs (corrupt image?)"
  grep -q '^/etc/' "$T/list" || fail "airootfs has no /etc"
  grep -xE '/etc/torch-dev-build|/etc/ssh/dev_authorized_keys|/etc/ssh/sshd_config\.d/10-dev\.conf' "$T/list" |
    sed 's/^/development marker /' | grep . >&2 && bad=1
  grep -E '/[^/]*authorized_keys[^/]*$|^/etc/ssh/ssh_host_[^/]*_key$' "$T/list" | sed 's/^/baked-in SSH credential /' | grep . >&2 && bad=1
  grep -E '^/etc/systemd/system/.*sshd[^/]*$' "$T/list" | sed 's/^/sshd enabled: /' | grep . >&2 && bad=1
  # unsquashfs exits 0 for paths that do not exist; the comparisons below fail on anything missing.
  unsquashfs -st -q -d "$X" "$T/a.sfs" usr/share/pacman/keyrings etc/ssh usr/bin/torchd >/dev/null 2>&1 || fail "cannot extract from airootfs.sfs"
  keyring_ok "$X" "ISO" || bad=1
  [[ -f $X/usr/bin/torchd ]] || { echo "ISO has no usr/bin/torchd" >&2; bad=1; }
  grep -qaF "$FAULT_MARKER" "$X/usr/bin/torchd" 2>/dev/null && { echo "ISO torchd is a fault-injection (development) build" >&2; bad=1; }
  grep -rlis '^[[:space:]]*AuthorizedKeys' "$X/etc/ssh" 2>/dev/null | sed "s|^$X|sshd override |" | grep . >&2 && bad=1
  [[ $bad == 0 ]] || fail "ISO is not a release image"
  echo "OK: ISO trusts only $FPR, no development access found"
  ;;
*) echo "usage: $0 repo <dir> | iso <file>" >&2; exit 2 ;;
esac
