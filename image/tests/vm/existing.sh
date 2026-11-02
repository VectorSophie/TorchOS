#!/usr/bin/env bash
# D. "Erase disk" over an existing installation (overlay of image/vm/A-installed.qcow2, which holds ~/home-probe),
#    with a second 1 GiB data disk carrying a labelled ext4 file system that must not change. Then boot the result.
# STATUS: drafted 2026-11-02, never executed. See README.md.
source "$(dirname "$0")/lib.sh"
[ -f image/vm/A-installed.qcow2 ] || { echo "run supported.sh first (needs image/vm/A-installed.qcow2)" >&2; exit 2; }
echo "== D1 prepare ($(ts))"
overlay A-installed.qcow2 D1.qcow2; rm -f image/vm/D2.qcow2; qemu-img create -q -f qcow2 image/vm/D2.qcow2 1G
fresh_vars image/vm/D.vars
qemu_run uefi image/vm/D.vars "$ISO" image/vm/D1.qcow2 image/vm/D2.qcow2
wait_ssh live 60 || exit 1; wait_calamares || exit 1
live 'sudo sh -c "sgdisk -n1:0:0 -t1:8300 /dev/vdb >/dev/null && mkfs.ext4 -q -L TORCHDATA /dev/vdb1 && mount /dev/vdb1 /mnt && echo recognizable-test-data > /mnt/marker && umount /mnt && sync"'
echo "--- before"
live 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PTTYPE /dev/vda /dev/vdb; echo "vdb sha256: $(sudo sha256sum /dev/vdb | cut -c1-16)"; sudo mount -o ro,subvol=@home /dev/vda2 /mnt && { ls /mnt/*/home-probe; sudo umount /mnt; }'
relaunch_calamares || exit 1   # rescan disks after preparing vdb
install_via_ui 3600; echo "install rc=$?"; shot D1-install-finished
echo "--- which disk was erased"
live 'grep -nE "torchpreflight|/dev/vd[ab]|CreatePartitionTable|Create new partition|Format partition|bootLoader|installPath" ~/.cache/calamares/session.log | head -40'
live 'cat ~/.cache/calamares/session.log' > "$OUT/D1-session.log"
echo "--- after"
live 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PTTYPE /dev/vda /dev/vdb; echo "vdb sha256: $(sudo sha256sum /dev/vdb | cut -c1-16)"; sudo mount -o ro /dev/vdb1 /mnt && { cat /mnt/marker; sudo umount /mnt; }; sudo mount -o ro,subvol=@home /dev/vda2 /mnt && { ls -la /mnt; ls /mnt/*/home-probe 2>&1; sudo umount /mnt; }'
live 'sync'; stop_vm
echo "== D2 boot the new installation ($(ts))"
qemu_run uefi image/vm/D.vars - image/vm/D1.qcow2 image/vm/D2.qcow2
wait_ssh inst 60 || exit 1
inst 'findmnt -no SOURCE,FSTYPE /; echo "FAILED steps: $(grep -c FAILED /var/log/torchos-install-steps.tsv)"; ls ~/home-probe 2>&1; torch doctor; echo "doctor rc=$?"'
inst 'sync'; stop_vm
echo "EXISTING_DONE $(ts)"
