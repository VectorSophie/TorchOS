#!/usr/bin/env bash
# F. Removable-media fallback loader: boot image/vm/A-installed.qcow2 with EMPTY firmware variables (no TorchOS
#    boot entry), which is what makes a missing NVRAM entry "optional" in torch-target-verify.
# C. Required-step failure: pacman-key is made unexecutable inside the target through the LIVE session's
#    shellprocess config (test only; shipped code is unchanged). Calamares must report failure and skip
#    grubcfg/bootloader. Nothing already written (partitions, unpacked files) is rolled back; this documents that.
# STATUS: drafted 2026-11-02, never executed. See README.md.
source "$(dirname "$0")/lib.sh"
[ -f image/vm/A-installed.qcow2 ] || { echo "run supported.sh first (needs image/vm/A-installed.qcow2)" >&2; exit 2; }

echo "== F fallback loader ($(ts))"
overlay A-installed.qcow2 F.qcow2; fresh_vars image/vm/F.vars
qemu_run uefi image/vm/F.vars - image/vm/F.qcow2
if wait_ssh inst 40; then
  inst "echo '$PW' | sudo -S -p '' efibootmgr -v | head -12; uname -r; systemctl is-system-running"; echo "F: BOOTED through the fallback path"
else
  echo "F: did NOT boot"
fi
shot F-fallback; inst sync 2>/dev/null; stop_vm

echo "== C required step failure ($(ts))"
start_iso; wait_ssh live 60 || exit 1; wait_calamares || exit 1
live 'sudo sed -i "s#\"/usr/lib/torchos/torch-target-setup\"#\"chmod -x /usr/bin/pacman-key; /usr/lib/torchos/torch-target-setup\"#" /etc/calamares/modules/shellprocess_setup.conf && grep -A2 script /etc/calamares/modules/shellprocess_setup.conf'
relaunch_calamares || exit 1
install_via_ui 3600; echo "install rc=$? (1 = installer reported failure, expected)"; sleep 3; shot C-required-step-failed
live 'grep -nE "Starting job|TORCHOS INSTALL FAILED|required step|onInstallationFailed|Installation failed|exit code" ~/.cache/calamares/session.log | tail -25'
live 'cat ~/.cache/calamares/session.log' > "$OUT/C-session.log"
echo "--- what is on the disk now (not rolled back)"
live 'lsblk -o NAME,FSTYPE,PTTYPE /dev/vda; sudo mkdir -p /mnt/t /mnt/e; sudo mount -o ro,subvol=@ /dev/vda2 /mnt/t && { sudo cat /mnt/t/var/log/torchos-install-steps.tsv; sudo umount /mnt/t; }; sudo mount -o ro /dev/vda1 /mnt/e && { sudo find /mnt/e; sudo umount /mnt/e; }; sudo efibootmgr | grep -i torchos || echo "no TorchOS firmware entry"'
live 'sync'; stop_vm
echo "== C2 try to boot that disk without the ISO ($(ts))"
start_disk; sleep 75; shot C2-boot-attempt
inst true 2>/dev/null && echo "C2: an installed system answered on SSH (UNEXPECTED)" || echo "C2: no installed system came up"
stop_vm
echo "FAILURE_DONE $(ts)"
