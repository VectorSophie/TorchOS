#!/usr/bin/env bash
# Smoke-boot a release ISO (built WITHOUT DEV_SSH_PUBKEY): it must boot to the desktop and reach the installer
# with no development access at all. Keyboard and screen only, like a user:
#   ISO=image/out/<release>.iso image/tests/vm/rc-smoke.sh
# Asserts that nothing answers SSH; the desktop, `torch doctor` and Calamares are judged from the screenshots.
export SCEN=rc-smoke   # read by lib.sh
source "$(dirname "$0")/lib.sh"
[ -f "${ISO:-}" ] || { echo "set ISO=<release iso>" >&2; exit 2; }
key() { python3 image/scripts/dev/qmon.py keys "$@"; sleep 2; }
typeln() { python3 image/scripts/dev/vnc.py type "$1"; python3 image/scripts/dev/vnc.py press Return; }
echo "== RC boot $ISO ($(ts))"
start_iso; sleep 150; shot RC-1-booted
assert "qemu running after 150 s" vm_alive
no_ssh() { ! timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" liveuser@127.0.0.1 true 2>/dev/null; }
assert "no SSH access on the release image" no_ssh
grep -iE 'sshd|Welcome to|Reached target' image/vm/serial.log | tail -3
# Hyprland's stock binding (D1: TorchOS's own config is not loaded) opens kitty with SUPER+Q.
key meta_l-q; sleep 3
typeln 'torch doctor; echo doctor rc=$?; systemctl is-active sshd; ls /etc/torch-dev-build'; sleep 6; shot RC-2-doctor
typeln 'calamares-launch &'; sleep 30; shot RC-3-installer
finish
