# 0002: Release integrity (publishing gate)

Status: implemented on `fix/torchos-release-integrity` (2026-11-08), not yet reviewed or merged.

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
  - `gpgv` with *only* the authorized key, and the `VALIDSIG` primary fingerprint must match, for both databases and every package;
  - every database entry's file is present with the database's SHA-256;
  - no unlisted package is present;
  - `.db` and `.files` list the same set;
  - exactly one `torchos-keyring` package, and its keyring files are byte-identical to the anchor.
- `publish-repo.sh`:
  - **dry run by default**, and the dry run calls no `gh` at all;
  - refuses if it or the verifier differs from `origin/master`, so only reviewed tooling can publish;
  - stages exactly the files the database lists, verifies **the staged copies**, and uploads from the stage.
- `verify-release.sh iso <file>` (T8) reads the squashfs inside the ISO:
  - the keyring is identical to the anchor;
  - no `/etc/torch-dev-build`, `dev_authorized_keys` or `10-dev.conf`;
  - no `*authorized_keys*` anywhere in `etc`, `root` or `home`;
  - no `AuthorizedKeys*` sshd override;
  - no enabled `sshd*` unit.

### Partial publication (T7)

GitHub has no atomic multi-asset swap. Mitigations:
1. Read the live `torchos.db` first. A filename it lists with a different SHA-256 is **refused** before any upload
   (bump `pkgrel`). An identical one is skipped. So a live package is never mutated.
2. Upload packages first, then `torchos.files`, then `torchos.db` + `.sig` in one call. If the run stops before the
   last step, the old database still describes intact packages.
3. Afterwards, download and compare the four database assets and list every package remotely. On mismatch the
   script tells the operator to rerun; a rerun is idempotent.

**Remaining limitation:** during the final call, `torchos.db` and `torchos.db.sig` are replaced one after the other
(`--clobber` deletes, then uploads). For a few seconds a client can see a missing database or one that does not
match its signature. pacman then fails that sync with an error and succeeds on retry. It does not install wrong
bits. Removing this window needs a different host: a versioned path plus an atomic pointer.

## Not covered (known)

- A local user who edits `publish-repo.sh`/`verify-release.sh` and also fakes `origin/master` (e.g. `git update-ref`)
  can bypass everything. The gate prevents accidents. It is not a defense against the operator.
- `origin/master` is used as last fetched; the script does not fetch.
- Package *contents* other than the keyring are not traced back to a commit (`build-packages.sh` tars the working
  tree). A prod-signed package built from a dirty tree would still pass. Next step: record the source commit in the
  package and require a clean tree.
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
