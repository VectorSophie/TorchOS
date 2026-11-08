#!/usr/bin/env bash
# Release-integrity tests for image/scripts/{verify-release,publish-repo}.sh. Runs inside a disposable
# archlinux:base-devel container (image/tests/run.sh): throwaway "prod" and "test" GnuPG keys, a throwaway git repo
# standing in for TorchOS (its origin/master holds the "prod" key and a mock destination), real repo-add, a MOCK `gh`
# that only copies files into a local directory, and synthetic ISOs. The real gh is not installed here and has no
# credentials, and the mock refuses any destination but mock-owner/mock-repo: nothing can reach GitHub.
set -uo pipefail
pacman -Sy --noconfirm --needed git squashfs-tools libisoburn >/dev/null 2>&1 || { echo "cannot install test tools"; exit 2; }
W=/tmp/ri; rm -rf $W; mkdir -p $W/bin $W/pkgs
R=$W/torchos REMOTE=$W/remote GHLOG=$W/gh.log DEST=mock-owner/mock-repo
export REMOTE GHLOG GH_CONFIG_DIR=$W/ghcfg PATH=$W/bin:$PATH; unset GH_TOKEN GITHUB_TOKEN GH_REPO
pass=0; failed=()

# --- keys ---
for k in prod test; do
  mkdir -m 700 $W/$k
  gpg --homedir $W/$k --batch --passphrase '' --quick-gen-key "TorchOS $k <$k@test.invalid>" ed25519 sign 1d 2>/dev/null
  declare "FPR_$k=$(gpg --homedir $W/$k --with-colons -K | awk -F: '/^fpr/{print $10; exit}')"
  mkdir $W/kr-$k; gpg --homedir $W/$k --export > $W/kr-$k/torchos.gpg
  echo "$(eval echo \$FPR_$k):4:" > $W/kr-$k/torchos-trusted; : > $W/kr-$k/torchos-revoked
done

# --- the stand-in TorchOS checkout: origin/master trusts "prod" and publishes to the mock destination ---
mkdir -p $R/image/scripts $R/image/calamares/usr/lib/torchos $R/pkg/torchos/keyring
cp /src/image/scripts/verify-release.sh /src/image/scripts/publish-repo.sh $R/image/scripts/
cp $W/kr-prod/* $R/pkg/torchos/keyring/
echo "printf '\n[torchos]\nServer = https://github.com/$DEST/releases/download/repo\n' >> /etc/pacman.conf" \
  > $R/image/calamares/usr/lib/torchos/torch-target-setup
git -C $R init -q && git -C $R add -A && git -C $R -c user.name=t -c user.email=t@t commit -qm base
git -C $R update-ref refs/remotes/origin/master HEAD

# --- mock gh: release view|create|download|upload against $REMOTE/<tag>; logs every call ---
cat > $W/bin/gh <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
[[ $1 == release ]] || exit 1
cmd=$2 tag=$3; shift 3; files=() pats=()
while (($#)); do case $1 in
  -R) dest=$2; shift 2 ;; -p) pats+=("$2"); shift 2 ;; -D) dir=$2; shift 2 ;;
  --json|-q|--title|--notes) shift 2 ;; --clobber|--latest=*) shift ;; *) files+=("$1"); shift ;; esac; done
[[ $dest == mock-owner/mock-repo ]] || { echo "mock gh: refusing destination $dest" >&2; exit 1; }
rel=$REMOTE/$tag
case $cmd in
  view) [[ -d $rel ]] && ls "$rel" ;;
  create) mkdir -p "$rel" ;;
  download) for p in "${pats[@]}"; do cp "$rel"/$p "$dir/" || exit 1; done ;;
  upload) n=0; for f in "${files[@]}"; do
      [[ -n ${MOCK_FAIL_AFTER:-} && $n -ge $MOCK_FAIL_AFTER ]] && { echo "mock gh: connection lost" >&2; exit 1; }
      cp "$f" "$rel/" && n=$((n + 1)); done ;;
  *) exit 1 ;;
esac
EOF
chmod +x $W/bin/gh

# --- packages: mkpkg <file> <name> <ver> <salt> [keyring dir] ---
mkpkg() {
  local d=$W/build; rm -rf $d; mkdir -p $d/usr/share/$2
  printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = test\nbuilddate = 1\nsize = 1\narch = any\n' $2 $2 $3 > $d/.PKGINFO
  echo "$4" > $d/usr/share/$2/content
  [[ -n ${5:-} ]] && { mkdir -p $d/usr/share/pacman/keyrings; cp $5/* $d/usr/share/pacman/keyrings/; }
  (cd $d && bsdtar --zstd -cf $W/pkgs/$1 .PKGINFO usr)
}
mkpkg A torch-cli 1.0-1 a; mkpkg Aold torch-cli 1.0-1 a-older-build; mkpkg B torch-cli 1.1-1 b
mkpkg K torchos-keyring 1.0-1 k $W/kr-prod; mkpkg Kt torchos-keyring 1.0-1 k $W/kr-test
fname() { case $1 in A|Aold) echo torch-cli-1.0-1-any.pkg.tar.zst ;; B) echo torch-cli-1.1-1-any.pkg.tar.zst ;;
  K|Kt) echo torchos-keyring-1.0-1-any.pkg.tar.zst ;; esac; }
sign() { gpg --homedir $W/$2 --batch --yes --detach-sign --no-armor -o "$1.sig" "$1"; }
# mkrepo <dir> <db key> <pkg>:<key>...
mkrepo() {
  local d=$1 dbkey=$2 e f; shift 2; rm -rf $d; mkdir -p $d
  for e in "$@"; do f=$d/$(fname ${e%:*}); cp $W/pkgs/${e%:*} $f; sign $f ${e#*:}; done
  GNUPGHOME=$W/$dbkey repo-add -q --sign --key "$(eval echo \$FPR_$dbkey)" $d/torchos.db.tar.gz $d/*.pkg.tar.zst >/dev/null 2>&1
}
mkrepo $W/good prod A:prod K:prod
mkrepo $W/next prod B:prod K:prod
[[ -f $W/good/torchos.db.sig && -f $W/good/torchos.files.sig ]] || { echo "fixture: repo-add did not sign"; exit 2; }

# --- helpers ---
remote_state() { (cd $REMOTE 2>/dev/null && find . -type f -exec sha256sum {} + | sort); }
use_repo() { rm -rf $R/image/repo; cp -a $1 $R/image/repo; git -C $R checkout -q -- . ; git -C $R clean -qfd -e image/repo; }
publish() { (cd /; $R/image/scripts/publish-repo.sh "$@") > $W/out 2>&1; }
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { failed+=("$1"); echo "FAIL  $1"; sed 's/^/      /' $W/out; }
# refused <label>: the last command failed, said REFUSED, and neither uploaded nor changed the remote.
expect_refused() {
  local rc=$? label=$1
  if [[ $rc != 0 ]] && grep -q REFUSED $W/out && ! grep -qE 'upload|create' $GHLOG && [[ "$(remote_state)" == "$BEFORE" ]]; then
    ok "refused: $label -- $(grep -v -e ^authorized -e "^  would" $W/out | head -2 | tr "\n" " ")"
  else bad "refused: $label (rc=$rc)"; fi
}
attempt() { : > $GHLOG; BEFORE=$(remote_state); }

# === repository: negative cases (all with an explicit --publish to the right destination) ===
rm -rf $REMOTE; mkdir $REMOTE
case_repo() { use_repo $W/case; attempt; publish --publish $DEST; expect_refused "$1"; }
mkrepo $W/case test A:test K:test;            case_repo "whole repo signed by a test key"
mkrepo $W/case prod A:test K:prod;            case_repo "one package signed by an unauthorized key"
mkrepo $W/case prod A:prod Kt:prod;           case_repo "keyring package trusting a test key, prod-signed"
rm -rf $W/case; cp -a $W/good $W/case; f=$W/case/"$(fname A)"; cp $W/pkgs/Aold $f; sign $f prod
                                              case_repo "older/different package file with its own valid signature"
rm -rf $W/case; cp -a $W/good $W/case; (cd $W/case && mkdir x && tar -xf torchos.db.tar.gz -C x &&
  sed -i 's/^test$/tampered/' x/*/desc && rm torchos.db.tar.gz && tar -czf torchos.db.tar.gz -C x . && rm -r x)
                                              case_repo "altered repository database"
rm -rf $W/case; cp -a $W/good $W/case; cp -P $W/next/torchos.files* $W/case/
                                              case_repo "files database from another build (validly signed)"
rm -rf $W/case; cp -a $W/good $W/case; rm $W/case/"$(fname A)"
                                              case_repo "database lists a package that is missing"
rm -rf $W/case; cp -a $W/good $W/case; rm $W/case/"$(fname A)".sig
                                              case_repo "missing package signature"
rm -rf $W/case; cp -a $W/good $W/case; rm $W/case/torchos.db.tar.gz.sig
                                              case_repo "missing database signature"
# Trust anchor and tooling.
use_repo $W/good; cp $W/kr-test/* $R/pkg/torchos/keyring/; attempt; publish --publish $DEST
                                              expect_refused "working-tree keyring swapped to a test key (prod-signed repo)"
mkrepo $W/case test A:test Kt:test; use_repo $W/case; cp $W/kr-test/* $R/pkg/torchos/keyring/
git -C $R -c user.name=t -c user.email=t@t commit -qam "swap to test key"; attempt; publish --publish $DEST
                                              expect_refused "test key committed on a branch, origin/master still prod"
git -C $R reset -q --hard origin/master
use_repo $W/good; echo '# local edit' >> $R/image/scripts/verify-release.sh; attempt; publish --publish $DEST
                                              expect_refused "verifier modified in the working tree"
use_repo $W/good; attempt; publish --publish evil-owner/mock-repo; expect_refused "--publish to an unauthorized destination"
use_repo $W/good; attempt; GH_REPO=evil-owner/mock-repo publish --publish $DEST; expect_refused "GH_REPO pointing elsewhere"

# === repository: positive cases ===
use_repo $W/good; : > $GHLOG
if publish && [[ ! -s $GHLOG ]] && grep -q 'dry run' $W/out; then ok "dry run verifies and calls no gh at all"; else bad "dry run"; fi
if publish --publish $DEST && cmp -s $REMOTE/repo/torchos.db $W/good/torchos.db.tar.gz &&
   cmp -s $REMOTE/repo/"$(fname A)" $W/good/"$(fname A)"; then ok "publish of a good repo (mock), remote verified"; else bad "publish good"; fi
if publish --publish $DEST && grep -q 'published 0 new' $W/out; then ok "republish is idempotent (no package re-upload)"; else bad "republish"; fi
mkrepo $W/case prod Aold:prod K:prod; use_repo $W/case; attempt; publish --publish $DEST
                                              expect_refused "replacing a live package filename with different bytes"
# Interrupted publish: the live database must still describe intact packages, and a rerun completes it.
use_repo $W/next; : > $GHLOG
MOCK_FAIL_AFTER=1 publish --publish $DEST
if [[ $? != 0 ]] && cmp -s $REMOTE/repo/torchos.db $W/good/torchos.db.tar.gz && cmp -s $REMOTE/repo/"$(fname A)" $W/good/"$(fname A)"; then
  ok "interrupted upload leaves the old database and its packages intact"; else bad "interrupted upload"; fi
if publish --publish $DEST && cmp -s $REMOTE/repo/torchos.db $W/next/torchos.db.tar.gz; then
  ok "rerun after interruption completes the publish"; else bad "rerun after interruption"; fi

# === ISO ===
# mkiso <name> <setup command run in the airootfs dir>
mkiso() {
  local r=$W/iso/$1; rm -rf $r $W/iso/$1.d; mkdir -p $r/etc/ssh $r/usr/share/pacman/keyrings $r/etc/systemd/system/multi-user.target.wants $W/iso/$1.d/arch/x86_64
  echo torchos > $r/etc/hostname; cp $W/kr-prod/* $r/usr/share/pacman/keyrings/
  (cd $r && eval "$2")
  mksquashfs $r $W/iso/$1.d/arch/x86_64/airootfs.sfs -quiet -noappend >/dev/null
  xorriso -as mkisofs -quiet -o $W/iso/$1.iso $W/iso/$1.d 2>/dev/null
}
iso() { (cd /; $R/image/scripts/verify-release.sh iso $W/iso/$1.iso) > $W/out 2>&1; }
use_repo $W/good
mkiso clean true;  if iso clean; then ok "release-looking ISO with the production keyring passes"; else bad "clean ISO"; fi
iso_refused() { mkiso $1 "$2"; iso $1 && bad "ISO: $3" || { grep -q REFUSED $W/out && ok "refused ISO: $3 -- $(grep -v ^authorized $W/out | head -2 | tr "\n" " ")" || bad "ISO: $3"; }; }
iso_refused dev "touch etc/torch-dev-build; echo k > etc/ssh/dev_authorized_keys; mkdir etc/ssh/sshd_config.d
  echo 'AuthorizedKeysFile /etc/ssh/dev_authorized_keys' > etc/ssh/sshd_config.d/10-dev.conf
  ln -s /usr/lib/systemd/system/sshd.service etc/systemd/system/multi-user.target.wants/sshd.service" "full DEV_SSH_PUBKEY image"
iso_refused hiddenkey "mkdir -p root/.ssh; echo k > root/.ssh/authorized_keys" "SSH key without any dev marker"
iso_refused sshd "ln -s /usr/lib/systemd/system/sshd.service etc/systemd/system/multi-user.target.wants/sshd.service" "sshd enabled, no key"
iso_refused testkey "cp $W/kr-test/* usr/share/pacman/keyrings/" "keyring trusts a test key"
iso_refused nokeyring "rm usr/share/pacman/keyrings/*" "keyring missing"

echo "== release integrity: $pass passed, ${#failed[@]} failed"
for f in "${failed[@]}"; do echo "   $f"; done
[[ ${#failed[@]} == 0 ]]
