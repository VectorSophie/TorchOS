#!/usr/bin/env bash
# A. Supported path: blank UEFI disk -> Calamares erase install -> boot the disk alone -> login, step record,
#    doctor, signed repo, Snapper, GRUB recovery entries, both kernels + fallback initramfs, checkpoint and
#    rollback across a reboot, boot-chain verification cost. Leaves image/vm/A-installed.qcow2 for the other scenarios.
# STATUS: drafted 2026-11-02, never executed. See README.md.
source "$(dirname "$0")/lib.sh"
[ -f "${ISO:-}" ] || { echo "no ISO in image/out" >&2; exit 2; }
echo "== A1 install from $ISO ($(ts))"; mem
start_iso; wait_ssh live 60 || exit 1; wait_calamares || exit 1
live 'test -d /sys/firmware/efi && echo "live firmware: UEFI"; lsblk -dno NAME,SIZE,PTTYPE /dev/vda; echo "signatures on vda: $(sudo wipefs -n /dev/vda | wc -l)"'
T0=$(date +%s); install_via_ui 3600; echo "install rc=$? after $(( $(date +%s) - T0 )) s"
shot A1-install-finished; mem
echo "--- values the real torchpreflight job saw"; live 'grep -E "torchpreflight" ~/.cache/calamares/session.log'
echo "--- job timing"; live 'grep -nE "Starting job|torch-target-verify|boot chain verified|completion:" ~/.cache/calamares/session.log | tail -40'
live 'cat ~/.cache/calamares/session.log' > "$OUT/A1-session.log"
live 'sync'; stop_vm

echo "== A2 boot the installed disk without the ISO ($(ts))"
start_disk; wait_ssh inst 60 || exit 1; sleep 15; shot A2-greeter
echo "--- greetd/tuigreet login on tty1 with the keyboard (VNC)"
python3 image/scripts/dev/vnc.py type "${TORCH_TEST_USER:-tester}"; python3 image/scripts/dev/vnc.py press Return; sleep 2
python3 image/scripts/dev/vnc.py type "$PW"; python3 image/scripts/dev/vnc.py press Return; sleep 25; shot A2-after-login
inst 'loginctl list-sessions --no-legend; pgrep -u "$(id -u)" -a Hyprland | head -2; uname -r'
echo "--- install step record"; inst 'cat /var/log/torchos-install-steps.tsv; echo "FAILED entries: $(grep -c FAILED /var/log/torchos-install-steps.tsv)"'
inst 'pacman -Q grub torch-cli calamares torch-installer-config 2>&1 | grep -v ^warning; findmnt -no SOURCE,FSTYPE,OPTIONS /; findmnt -no SOURCE /.snapshots; ls /boot'
echo "--- torch doctor"; inst 'torch doctor; echo "doctor rc=$?"'
echo "--- signed [torchos] repo (hosted GitHub release)"
inst 'grep -A2 "^\[torchos\]" /etc/pacman.conf; pacman-key --list-keys FD561EDBA8080AA625A935E075870B90E4C34AC8 2>&1 | head -3'
inst "echo '$PW' | sudo -S -p '' pacman -Sy 2>&1 | tail -4; pacman -Si torchos/torch-cli 2>&1 | grep -E 'Repository|Version'"
echo "--- snapper"; inst 'snapper -c root list; snapper -c root get-config | grep -E "NUMBER_LIMIT|TIMELINE_CREATE|ALLOW_GROUPS"'
echo "--- GRUB recovery entries"
inst "echo '$PW' | sudo -S -p '' grep -nE '^menuentry|^submenu|^\s+menuentry|grub-btrfs' /boot/grub/grub.cfg | head -20; grep -c '^submenu' /boot/grub/grub-btrfs.cfg"
inst "echo '$PW' | sudo -S -p '' efibootmgr"

echo "== A3 boot linux-lts and the linux fallback initramfs via grub-reboot ($(ts))"
for e in "Advanced options for TorchOS Linux>TorchOS Linux, with Linux linux-lts" \
         "Advanced options for TorchOS Linux>TorchOS Linux, with Linux linux (fallback initramfs)"; do
  inst "echo '$PW' | sudo -S -p '' grub-reboot '$e' && sync && echo '$PW' | sudo -S -p '' systemctl reboot"; sleep 30
  wait_ssh inst 60 || exit 1
  # The fallback initramfs is not visible in /proc/cmdline; a successful boot after selecting it is the evidence.
  inst "echo 'selected: $e'; uname -r; systemctl is-system-running; torch doctor >/dev/null; echo doctor rc=\$?"
done

echo "== A4 checkpoint + change + rollback across a reboot ($(ts))"
inst 'torch snapshot create "install-correctness verification: checkpoint" && snapper -c root list | tail -3'
N=$(inst 'snapper -c root list | grep "install-correctness verification: checkpoint" | tail -1 | cut -d"|" -f1 | tr -d " *"')
echo "checkpoint number: $N"
inst "echo '$PW' | sudo -S -p '' sh -c 'echo changed > /etc/torch-rollback-probe'; echo kept > ~/home-probe"
inst "printf 'y\n' | torch snapshot rollback $N"
inst "sync; echo '$PW' | sudo -S -p '' systemctl reboot"; sleep 30
wait_ssh inst 60 || exit 1
inst 'test -e /etc/torch-rollback-probe && echo "PROBE STILL THERE: rollback did not revert" || echo "system change reverted"; echo "home: $(cat ~/home-probe)"; torch doctor; echo "doctor rc=$?"'

echo "== A5 boot-chain verification cost on the installed system ($(ts))"
# Note: appends "verify:" lines to the installed system's install log and step record.
inst 'cat > /tmp/torch-target-verify && chmod +x /tmp/torch-target-verify' < image/calamares/usr/lib/torchos/torch-target-verify
inst "du -cb /boot/initramfs-* /boot/vmlinuz-* | tail -1"
echo "--- cold cache"
inst "echo '$PW' | sudo -S -p '' sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; systemd-run --wait --pipe -p IOAccounting=yes -p MemoryAccounting=yes /tmp/torch-target-verify / 2>&1' | grep -E 'CHECK FAILED|boot chain|runtime|CPU time|Memory peak|IO bytes'"
echo "--- warm cache"
inst "echo '$PW' | sudo -S -p '' sh -c 'systemd-run --wait --pipe -p IOAccounting=yes -p MemoryAccounting=yes /tmp/torch-target-verify / 2>&1' | grep -E 'boot chain|runtime|CPU time|Memory peak|IO bytes'"
inst 'sync'; stop_vm
qemu-img convert -O qcow2 "$BLANK" image/vm/A-installed.qcow2 && echo "kept image/vm/A-installed.qcow2 for the other scenarios"
echo "SUPPORTED_DONE $(ts)"
