#!/usr/bin/env bash
# B. Rejections on a disk holding an existing installation (overlay of image/vm/A-installed.qcow2 from supported.sh).
#    After each VM stops, `qemu-img compare` against the base shows whether anything at all was written.
#  B1 BIOS boot (real SeaBIOS)            B2 erase + swap partition     B3 erase + ext4
#  B4 best effort: "Replace a partition" chosen with the keyboard (screenshots show how far it got)
#  B2-B4 re-enable the option in the LIVE session's partition.conf (test only), proving the gate itself
#  rejects them even if the configuration ever offers them again.
# STATUS: drafted 2026-11-02, never executed. See README.md.
source "$(dirname "$0")/lib.sh"
[ -f image/vm/A-installed.qcow2 ] || { echo "run supported.sh first (needs image/vm/A-installed.qcow2)" >&2; exit 2; }
gate_log() { live 'grep -nE "torchpreflight|Starting job|onInstallationFailed|Installation failed" ~/.cache/calamares/session.log | tail -12'; }
written() { qemu-img compare -q image/vm/A-installed.qcow2 "image/vm/$1" && echo "NO (images identical)" || echo "YES (images differ)"; }

echo "== B1 BIOS boot ($(ts))"
overlay A-installed.qcow2 B1.qcow2
qemu_run bios - "$ISO" image/vm/B1.qcow2
wait_ssh live 60 || exit 1; wait_calamares || exit 1
live 'test -d /sys/firmware/efi && echo "live firmware: UEFI" || echo "live firmware: BIOS"; lsblk -no NAME,FSTYPE,PTTYPE /dev/vda'
install_via_ui 1800; echo "install rc=$? (1 = installer reported failure, expected)"
sleep 3; shot B1-bios-refused; gate_log; live 'cat ~/.cache/calamares/session.log' > "$OUT/B1-session.log"
stop_vm; echo "B1 disk written: $(written B1.qcow2)"

echo "== B2/B3/B4 UEFI ($(ts))"
overlay A-installed.qcow2 B2.qcow2; fresh_vars image/vm/B2.vars
qemu_run uefi image/vm/B2.vars "$ISO" image/vm/B2.qcow2
wait_ssh live 60 || exit 1; wait_calamares || exit 1
live 'sudo sed -i "s/^userSwapChoices:.*/userSwapChoices: [ none, small ]/; s/^initialSwapChoice:.*/initialSwapChoice: small/" /etc/calamares/modules/partition.conf; grep Swap /etc/calamares/modules/partition.conf'
relaunch_calamares || exit 1
install_via_ui 1800; echo "B2 install rc=$? (1 expected)"; sleep 3; shot B2-swap-refused; gate_log
live 'sudo sed -i "s/^userSwapChoices:.*/userSwapChoices: [ none ]/; s/^initialSwapChoice:.*/initialSwapChoice: none/; s/^defaultFileSystemType:.*/defaultFileSystemType: \"ext4\"/; s/^availableFileSystemTypes:.*/availableFileSystemTypes: [ \"ext4\" ]/" /etc/calamares/modules/partition.conf; grep -E "Swap|FileSystem" /etc/calamares/modules/partition.conf'
relaunch_calamares || exit 1
install_via_ui 1800; echo "B3 install rc=$? (1 expected)"; sleep 3; shot B3-ext4-refused; gate_log
live 'cat ~/.cache/calamares/session.log' > "$OUT/B3-session.log"
live 'sudo sed -i "s/^defaultFileSystemType:.*/defaultFileSystemType: \"btrfs\"/; s/^availableFileSystemTypes:.*/availableFileSystemTypes: [ \"btrfs\" ]/; s/^initialPartitioningChoice:.*/initialPartitioningChoice: replace/" /etc/calamares/modules/partition.conf'
relaunch_calamares || exit 1
live 'hyprctl dispatch focuswindow class:io.calamares.calamares' >/dev/null
for _ in 1 2 3; do python3 image/scripts/dev/qmon.py keys alt-n; sleep 3; done; shot B4-partition-page
for _ in 1 2 3 4 5 6; do python3 image/scripts/dev/vnc.py press Tab; sleep 1; done; shot B4-tabbed
python3 image/scripts/dev/vnc.py press Right; sleep 1; python3 image/scripts/dev/vnc.py press space; sleep 2; shot B4-selected
live 'grep -nE "Replace|replace|partitionChoices" ~/.cache/calamares/session.log | tail -8'
stop_vm; echo "B2-B4 disk written: $(written B2.qcow2)"
echo "REJECTED_DONE $(ts)"
