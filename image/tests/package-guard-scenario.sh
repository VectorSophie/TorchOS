#!/usr/bin/env bash
# Fault-injection release guards against REAL packages (docs/decisions/0003-recovery-integrity.md §7.1).
#   docker run --rm -v "$PWD:/src:ro" archlinux:base-devel bash /src/image/tests/package-guard-scenario.sh
# Inside a disposable container: makepkg builds the torchos split package from this tree (needs network for
# makedepends). A throwaway GnuPG key stands in for the production key, and a throwaway git repo for the trust anchor,
# exactly as in release-integrity-scenario.sh. Nothing is published; no real key is involved.
# Checks: a normal build packages; a fault-injection build is refused by the PKGBUILD; verify-release.sh accepts the
# signed normal repo and refuses the same repo once torch-cli carries the fault-injection torchd.
set -uo pipefail
pacman -Sy --noconfirm --needed git >/dev/null 2>&1 || { echo "cannot install git"; exit 2; }
W=/tmp/pg; rm -rf $W; mkdir -p $W/build $W/repo
pass=0; failed=()
check() { local what=$1; shift; if "$@"; then echo "PASS $what"; pass=$((pass + 1)); else echo "FAIL $what"; failed+=("$what"); fi; }
MARK=TORCHD-FAULT-INJECTION-BUILD

# --- throwaway "production" key and the stand-in checkout whose origin/master trusts it ---
mkdir -m 700 $W/gpg; export GNUPGHOME=$W/gpg
gpg --batch --passphrase '' --quick-gen-key "TorchOS throwaway <throwaway@test.invalid>" ed25519 sign 1d 2>/dev/null
FPR=$(gpg --with-colons -K | awk -F: '/^fpr/{print $10; exit}')
R=$W/torchos; mkdir -p $R/image/scripts $R/image/calamares/usr/lib/torchos $R/pkg/torchos/keyring
gpg --export > $R/pkg/torchos/keyring/torchos.gpg; echo "$FPR:4:" > $R/pkg/torchos/keyring/torchos-trusted
: > $R/pkg/torchos/keyring/torchos-revoked
cp /src/pkg/torchos/torchos-keyring.install $R/pkg/torchos/; cp /src/image/scripts/verify-release.sh $R/image/scripts/
echo "Server = https://github.com/mock-owner/mock-repo/releases/download/repo" > $R/image/calamares/usr/lib/torchos/torch-target-setup
git -C $R init -q && git -C $R add -A && git -C $R -c user.name=t -c user.email=t@t commit -qm base
git -C $R update-ref refs/remotes/origin/master HEAD

# --- real makepkg, as build-packages.sh does, but with the throwaway keyring ---
B=$W/build
cp /src/pkg/torchos/{PKGBUILD,torchd.sysusers,os-release,torchos-os-release.hook,torchos-keyring.install} $B/
cp $R/pkg/torchos/keyring/* $B/
(cd /src && tar --exclude=target -czf $B/torchos-src.tar.gz --transform 's,^,src/,' torch dotfiles image/calamares \
  assets/branding/logo-badge.png assets/branding/icons assets/branding/wallpaper.png assets/branding/wallpaper-light.png)
echo "OPTIONS+=(!debug)" >> /etc/makepkg.conf
useradd -m builder; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/b; chown -R builder $B
su builder -c "cd $B && makepkg -sf --noconfirm" > $W/normal.log 2>&1; rc=$?
tail -3 $W/normal.log
check "normal build: makepkg succeeds" test $rc = 0
CLI=$(ls $B/torch-cli-*.pkg.tar.zst 2>/dev/null | head -1)
check "normal build: torch-cli package produced" test -n "$CLI"
mkdir $W/cli && tar --zstd -xf "$CLI" -C $W/cli
check "normal build: packaged torchd has no fault-injection marker" sh -c "! grep -qaF $MARK $W/cli/usr/bin/torchd"
cp $B/*.pkg.tar.zst $W/repo/; CLI=$W/repo/$(basename "$CLI")

# --- the same build with the development feature: the PKGBUILD must refuse to package it ---
sed -i 's|-p torchd -p torch-welcome$|-p torchd -p torch-welcome --features torchd/fault-injection|' $B/PKGBUILD
grep -q 'features torchd/fault-injection' $B/PKGBUILD || { echo "could not enable the feature in the PKGBUILD copy"; exit 2; }
rm -f $B/*.pkg.tar.zst
su builder -c "cd $B && makepkg -ef --noconfirm" > $W/fault.log 2>&1; rc=$?
tail -4 $W/fault.log
check "fault build: makepkg fails" test $rc != 0
check "fault build: refused for the fault-injection feature" grep -q 'built with the fault-injection feature: refusing to package it' $W/fault.log
check "fault build: no torch-cli package produced" sh -c "! ls $B/torch-cli-*.pkg.tar.zst 2>/dev/null"
FI=$B/src/target/release/torchd   # PKGBUILD: CARGO_TARGET_DIR=$srcdir/target
check "fault build: the built torchd does carry the marker" grep -qaF $MARK $FI

# --- release verification of the real packages ---
sign_repo() {  # (re)build and sign the repo in $W/repo
  (cd $W/repo && rm -f torchos.db* torchos.files* *.sig && repo-add -q torchos.db.tar.gz ./*.pkg.tar.zst &&
    for f in *.pkg.tar.zst torchos.db torchos.files; do gpg --batch --yes --detach-sign "$f" || exit 1; done)
}
sign_repo || { echo "signing failed"; exit 2; }
out=$(bash $R/image/scripts/verify-release.sh repo $W/repo 2>&1); rc=$?; echo "$out" | tail -2
check "verify-release accepts the signed normal repo (no false rejection)" test $rc = 0

# Replace torch-cli's torchd with the fault-injection binary, repack, re-sign: everything else is valid.
P=$W/repack; mkdir $P && tar --zstd -xf "$CLI" -C $P && install -m755 "$FI" $P/usr/bin/torchd
rm $W/repo/"$(basename "$CLI")"
# shellcheck disable=SC2046  # package member names have no spaces
(cd $P && shopt -s dotglob && bsdtar --zstd -cf $W/repo/"$(basename "$CLI")" .PKGINFO $(printf '%s\n' * | grep -vx .PKGINFO))
sign_repo || { echo "signing failed"; exit 2; }
out=$(bash $R/image/scripts/verify-release.sh repo $W/repo 2>&1); rc=$?; echo "$out" | tail -2
check "verify-release refuses a repo whose torch-cli carries a fault-injection torchd" test $rc != 0
check "  ... for that reason" grep -q 'torchd is a fault-injection (development) build' <<<"$out"

echo "== package guards: $pass passed, ${#failed[@]} failed ${failed[*]:-}"
[ ${#failed[@]} -eq 0 ]
