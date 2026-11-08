#!/usr/bin/env bash
# Installer regression tests: config + install gate (Python unittest, runs anywhere) and the real
# torch-target-setup / torch-target-verify against a fake target, one disposable container per scenario
# (needs docker; the image is the archlinux:base-devel already used by the build). Nothing here touches
# the host system or any real disk.
#   image/tests/run.sh            all of it
#   image/tests/run.sh supported  one scenario
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
fail=0

if [ $# -eq 0 ]; then
  echo "== static: bash -n"
  for f in image/calamares/usr/lib/torchos/torch-target-setup image/calamares/usr/lib/torchos/torch-target-verify \
           image/tests/install-steps-scenario.sh image/tests/hyprland-config-scenario.sh image/tests/vm/*.sh \
           image/scripts/*.sh image/tests/release-integrity-scenario.sh; do
    bash -n "$f" || fail=1
  done
  if command -v shellcheck >/dev/null; then
    echo "== static: shellcheck"
    shellcheck -S warning image/calamares/usr/lib/torchos/torch-target-setup \
      image/calamares/usr/lib/torchos/torch-target-verify image/scripts/verify-release.sh \
      image/scripts/publish-repo.sh || fail=1
  else
    echo "== static: shellcheck not installed, skipped"
  fi
  echo "== unit: config + install gate + Hyprland config"
  python3 -m unittest discover -s image/tests -p 'test_*.py' || fail=1
  echo "== hyprland: real Hyprland --verify-config on the shipped Lua config (installed + live user)"
  docker run --rm -v "$PWD:/src:ro" archlinux:base-devel bash /src/image/tests/hyprland-config-scenario.sh || fail=1
  echo "== release integrity: publish gate + release ISO check (disposable keys, mock gh; never reaches GitHub)"
  docker run --rm -v "$PWD:/src:ro" archlinux:base-devel bash /src/image/tests/release-integrity-scenario.sh || fail=1
fi

SCENARIOS=${*:-supported bios ext4-root wrong-subvolume encrypted-root mbr-table kernel-missing
  initramfs-hook-missed initramfs-hook-noop initramfs-build-fails initramfs-without-overlay-hook
  keyring-populate-fails signing-key-missing greetd-enable-fails no-login-account torchd-enable-fails
  snapper-config-fails first-snapshot-fails optional-service-fails
  verify-ok verify-wrong-root verify-grub-reads-short-kernel verify-grub-cfg-invalid verify-no-fallback-loader
  verify-no-snapshot-menu verify-no-nvram-entry}
passed=0; failed=()
for s in $SCENARIOS; do
  if docker run --rm -v "$PWD:/src:ro" archlinux:base-devel bash /src/image/tests/install-steps-scenario.sh "$s"; then
    passed=$((passed + 1))
  else
    failed+=("$s"); fail=1
  fi
done
echo "== scenarios: $passed passed, ${#failed[@]} failed ${failed[*]:-}"
exit $fail
