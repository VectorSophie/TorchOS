# 0002: Release integrity (publishing gate)

Status: implemented on `fix/torchos-release-integrity` (2026-11-08), independently reviewed the same day (fixes in
the review commit, see "Review findings"), draft PR #3. Not merged.

## Problem

Installed systems pull `[torchos]` from the GitHub release `repo` (`torch-target-setup` writes the `Server =` line) and
trust exactly the key shipped in `torchos-keyring`. Before this change, `publish-repo.sh` checked only that
`torchos.db.tar.gz.sig` *existed*, then `gh release upload --clobber`ed every file in `image/repo/` to
`${GH_REPO:-VectorSophie/TorchOS}`. It is the only publishing path (no CI workflow exists).

## Threat model

Who: the operator (or a Claude Code session) on a dev machine. Main concern: accidents and stale state, not a
malicious local user. Anyone who can edit the scripts can bypass any local check. That limit is stated below.

| # | Threat | Consequence for installed users |
|---|---|---|
| T1 | A repo signed with a throwaway test key (the documented QEMU flow) is published | `pacman -Syu` fails signature checks: updates break |
| T2 | The test flow swaps `pkg/torchos/keyring/*` in the working tree, and `build-packages.sh` builds `torchos-keyring` from it. If that package is signed with the production key and published | every system starts **trusting the test key**: silent trust takeover |
| T3 | The swapped working-tree keyring is used as the definition of "production" | every check passes for the wrong key |
| T4 | One package is unsigned, signed by another key, or stale (an older file with its own valid signature) | download or verification failure, or the wrong bits installed |
| T5 | The database does not match the files (edited, from another build, `.files` ≠ `.db`) | sync or install failures |
| T6 | `GH_REPO` or a typo sends the upload elsewhere, or a test reaches the real endpoint | wrong place overwritten |
| T7 | Partial upload: `--clobber` replaces a package filename the **live** database still lists with different bytes, or the database goes up before its packages | every client fails until fixed |
| T8 | A "release" ISO carries dev SSH access or a test keyring. Filenames prove nothing | remote access to every live session, or wrong trust after install |

## Design

- **Trust anchor = committed `origin/master`** (`git show origin/master:pkg/torchos/keyring/*`). It is not
  overridable. The working-tree keyring must be byte-identical to it, otherwise the run is refused (T2, T3). The key
  must be exactly one primary key, equal to `torchos-trusted`, and not in `torchos-revoked`. Key rotation therefore
  means a reviewed merge to master.
- **Destination = committed `Server =` URL** in `torch-target-setup` at `origin/master`, the one clients actually
  use. `--publish OWNER/REPO` must equal it, and `GH_REPO` must be unset or equal (T6).
- `image/scripts/verify-release.sh repo <dir>` (T1, T2, T4, T5):
  - `gpgv` with *only* the authorized key must succeed, and each `.sig` must hold exactly one signature, whose
    `VALIDSIG` primary fingerprint matches. This applies to both databases and every package;
  - every database entry's file is present with the database's SHA-256;
  - no unlisted package is present;
  - `.db` and `.files` list the same set;
  - exactly one `torchos-keyring` package. Its file list is an allowlist: the three keyring files, byte-identical to
    the anchor, plus `.INSTALL`, byte-identical to the committed `torchos-keyring.install`, plus package metadata;
  - no other package ships anything under `usr/share/pacman/keyrings/`, `etc/pacman.conf` or `etc/pacman.d/`, and
    no other package's `.INSTALL` or `*.hook` mentions `pacman-key`, `pacman.d/gnupg` or `gpg`.
- `publish-repo.sh`:
  - **dry run by default**, and the dry run calls no `gh` at all;
  - refuses if it or the verifier differs from `origin/master`, so only reviewed tooling can publish;
  - stages exactly the files the database lists, verifies **the staged copies**, and uploads from the stage.
- `verify-release.sh iso <file>` (T8) reads the squashfs inside the ISO:
  - name checks run on the listing of the **whole** image (`unsquashfs -ls`), which fails on a corrupt image;
  - no `/etc/torch-dev-build`, `dev_authorized_keys` or `10-dev.conf`;
  - no `*authorized_keys*` anywhere in the image, and no baked-in `/etc/ssh/ssh_host_*_key`;
  - no `sshd*` under `/etc/systemd/system`;
  - the keyring, extracted with `-st`, is identical to the anchor (a missing file fails);
  - no `AuthorizedKeys*` sshd override.

### Partial publication (T7)

GitHub has no atomic multi-asset swap. Mitigations:
1. Download the live `torchos.db` and every remote asset with a name the upload would reuse. A filename the live
   database lists with a different SHA-256 is **refused** before any upload (bump `pkgrel`). Otherwise skip/upload
   is decided on **bytes**: an identical asset is skipped, a missing or damaged one is (re)uploaded. A live package's
   intended content is never changed. The release is created only when GitHub answers "not found", never on an
   auth or network error.
2. Upload packages first, then `torchos.files`, then `torchos.db` + `.sig` in one call. If the run stops before the
   last step, the old database still describes intact packages.
3. Afterwards, download **every** asset of the upload set and compare it byte for byte with the verified stage. From
   the start of the database phase, any failure (upload error, interruption, wrong bytes) prints
   `INCOMPLETE: … rerun this script now`. A rerun is idempotent and repairs the remote.

**Remaining limitation:** during the final call, `torchos.db` and `torchos.db.sig` are replaced one after the other
(`--clobber` deletes, then uploads). For a few seconds a client can see a missing database or one that does not
match its signature. pacman then fails that sync with an error and succeeds on retry. It does not install wrong
bits. Removing this window needs a different host: a versioned path plus an atomic pointer.

## Review findings (2026-11-08) and fixes

| Finding | Confirmed? | Fix |
|---|---|---|
| ISO: `unsquashfs … \|\| true` plus extracting only `etc root home` | yes: a key in `/opt/x/authorized_keys` passed; `unsquashfs` exits 0 for missing paths even with `-st` | whole-image listing; strict extraction; byte comparison catches anything missing |
| Remote package integrity judged by filename | yes: a damaged remote asset with the right name was skipped, and the post-check only listed names | byte decisions + full byte post-check |
| Interruption in the database phase | yes (inherent): the database could change without its signature, with no explicit report | `INCOMPLETE` report + tested rerun; window documented above |
| Keyring package could change trust beyond the three files (extra keyring, modified `.INSTALL`), and so could other packages (keyrings, install scripts, hooks) | yes, none of it was checked | allowlist + committed `.INSTALL` + trust-path/script checks |
| A `.sig` holding the production signature plus a second, unknown one passed (only VALIDSIG was read) | yes | gpgv exit status + exactly one signature |
| `gh release view` failing for auth/network reasons led to `gh release create` | yes | create only on "not found" |

Read-only check of the live production repository (2026-11-08): fetched over public HTTPS, with no credentials and
no `gh` write calls. Result:
- 22 assets: 9 packages and their signatures, plus 4 database files;
- `verify-release.sh repo`, both before and after the stricter rules: **OK**, all signed by `FD561EDB…4AC8`;
- the keyring package's `.INSTALL` is identical to the committed one;
- the only package hook is `torch-release`'s os-release hook, which does not touch keys.

## Production build and signing: blockers vs follow-ups

Blockers **for the next publish or release** (the gate enforces or exposes them; none blocks merging this gate):
- **Version bump required.** `PKGBUILD` pins `pkgver=0.2.0`/`pkgrel=1`, and production already serves `*-0.2.0-1`.
  A rebuild has the same filenames with different bytes, and the gate refuses it. That is correct: pacman would
  never upgrade installed systems to the same version anyway.
- **No source provenance.** `build-packages.sh` tars the *working tree*, including uncommitted changes, and
  `sha256sums=SKIP`. A production-signed package cannot be traced to a commit. Before a release, build from a clean
  checkout of a tagged commit and record that commit. The gate cannot check this yet.
- **Production key handling.** The key has no passphrase (handoff §7). `sign-repo.sh` copies it into an unpinned
  `archlinux:base-devel` container pulled from Docker Hub. Sign on the host or in a digest-pinned image, and decide on
  a passphrase or offline key.

Follow-ups (documented, not blocking):
- AUR recipes are cloned at HEAD and cached by filename. They are GPG-checked against their `validpgpkeys`, but not
  pinned like `arch-pinned.txt`.
- `sign-repo.sh` keeps an existing `.sig` that verifies with *any* key in the GnuPG home. The publish gate catches the result.
- `gh release view --json assets` is assumed to list every asset. That holds for today's 22 assets.

## Not covered (known)

- A local user who edits `publish-repo.sh`/`verify-release.sh` and also fakes `origin/master` (e.g. `git update-ref`)
  can bypass everything. The gate prevents accidents. It is not a defense against the operator.
- `origin/master` is used as last fetched; the script does not fetch.
- Package *contents* other than pacman-trust paths are not traced back to a commit (see blockers above).
- The script/hook check is a text match (`pacman-key`, `pacman.d/gnupg`, `gpg `). It catches accidents, not
  deliberate obfuscation by someone who can produce production-signed packages.
- `sign-repo.sh` and `build-iso.sh` are unchanged: they are the test-key path too, and the gate sits at publication
  and release-ISO verification. Nothing publishes ISOs today. `verify-release.sh iso` must be run before any ISO
  is distributed.

## Tests

`image/tests/release-integrity-scenario.sh` (run by `image/tests/run.sh`, in a disposable `archlinux:base-devel`
container). It uses:
- throwaway "prod" and "test" keys;
- a throwaway git repo whose `origin/master` holds the "prod" key and a mock destination;
- real `repo-add --sign`;
- a mock `gh` that copies into a local directory and refuses any other destination (the real `gh` is not installed
  in the container and has no credentials);
- synthetic ISOs built with `mksquashfs` + `xorriso`.

Every negative case runs with an explicit `--publish` to the correct destination, and must fail with `REFUSED`,
make no `upload`/`create` call, and leave the remote unchanged. The cases are listed in that script.
