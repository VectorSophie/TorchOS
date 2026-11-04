#!/usr/bin/env bash
# D. "Erase disk" over an existing installation (overlay of image/vm/A-installed.qcow2, which holds ~/home-probe),
#    with a second 1 GiB data disk carrying a labelled ext4 file system that must not change. Then boot the result.
# Only disposable qcow2 files are used: D1 is an overlay, D2 is created here.
source "$(dirname "$0")/lib.sh"
[ -f image/vm/A-installed.qcow2 ] || { echo "run supported.sh first (needs image/vm/A-installed.qcow2)" >&2; exit 2; }
echo "== D1 prepare ($(ts))"
overlay A-installed.qcow2 D1.qcow2; rm -f image/vm/D2.qcow2; qemu-img create -q -f qcow2 image/vm/D2.qcow2 1G
fresh_vars image/vm/D.vars
qemu_run uefi image/vm/D.vars "$ISO" image/vm/D1.qcow2 image/vm/D2.qcow2
wait_ssh live 60 || abort "live session reachable"; wait_calamares || abort "Calamares mapped"
# sfdisk (util-linux) is on every live image; sgdisk (gptfdisk) is not.
live 'sudo sh -c "echo type=83 | sfdisk -q /dev/vdb && udevadm settle && mkfs.ext4 -q -L TORCHDATA /dev/vdb1 && mount /dev/vdb1 /mnt && echo recognizable-test-data > /mnt/marker && umount /mnt && sync"'
assert "data disk prepared: ext4 TORCHDATA with the marker" live 'sudo mount -o ro /dev/vdb1 /mnt && { grep -qx recognizable-test-data /mnt/marker; r=$?; sudo umount /mnt; exit $r; }'
vdb_sum() { "$1" "echo '$PW' | sudo -S -p '' sha256sum /dev/vdb 2>/dev/null || sudo sha256sum /dev/vdb" | cut -d' ' -f1; }
SUM0=$(vdb_sum live); PT0=$(live 'sudo blkid -p -o value -s PTUUID /dev/vda'); FS0=$(live 'sudo blkid -o value -s UUID /dev/vda2')
echo "before: vdb sha256 $SUM0, vda PTUUID $PT0, vda2 UUID $FS0"
live 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PTTYPE /dev/vda /dev/vdb' | tee "$OUT/D1-before.txt"
assert "existing installation's /home holds home-probe" \
  live 'sudo mount -o ro,subvol=@home /dev/vda2 /mnt && { sudo sh -c "ls /mnt/*/home-probe"; r=$?; sudo umount /mnt; exit $r; }'
relaunch_calamares || abort "Calamares relaunched (rescan disks after preparing vdb)"
install_via_ui 3600; rc=$?; shot D1-install-finished
assert "install succeeded (drive_install rc=$rc)" test "$rc" = 0
LOG=$(session_log D1)
grep -nE "torchpreflight|/dev/vd[ab]" <<<"$LOG" | grep -E "Starting job|torchpreflight" | head -20
assert "gate accepted the configuration" has "torchpreflight: supported configuration" "$LOG"
assert "partition jobs targeted /dev/vda" has "Starting job .*(Create new|Format partition).*/dev/vda" "$LOG"
assert "no partition job touched /dev/vdb" lacks "Starting job .*/dev/vdb" "$LOG"
SUM1=$(vdb_sum live); PT1=$(live 'sudo blkid -p -o value -s PTUUID /dev/vda'); FS1=$(live 'sudo blkid -o value -s UUID /dev/vda2')
echo "after:  vdb sha256 $SUM1, vda PTUUID $PT1, vda2 UUID $FS1"
live 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PTTYPE /dev/vda /dev/vdb' | tee "$OUT/D1-after.txt"
assert "vda got a new partition table (PTUUID changed)" sh -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]' _ "$PT0" "$PT1"
assert "vda2 holds a new file system (UUID changed)" sh -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]' _ "$FS0" "$FS1"
assert "data disk vdb byte-identical (sha256 of the whole device)" sh -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$SUM0" "$SUM1"
assert "data disk marker readable" live 'sudo mount -o ro /dev/vdb1 /mnt && { grep -qx recognizable-test-data /mnt/marker; r=$?; sudo umount /mnt; exit $r; }'
assert "old home-probe is gone from the new @home" \
  live 'sudo mount -o ro,subvol=@home /dev/vda2 /mnt && { sudo sh -c "ls -d /mnt/*/ && ! ls /mnt/*/home-probe 2>/dev/null"; r=$?; sudo umount /mnt; exit $r; }'
live 'sync'; stop_vm

echo "== D2 boot the new installation, ISO detached ($(ts))"
qemu_run uefi image/vm/D.vars - image/vm/D1.qcow2 image/vm/D2.qcow2
wait_ssh inst 60 || abort "new installation reachable over SSH"
assert "booted without the live ISO" inst '! grep -q archiso /proc/cmdline'
assert "root is btrfs subvolume /@ on vda" inst 'findmnt -no SOURCE,FSTYPE,OPTIONS / | grep -Eq "^/dev/vda2\[/@\] btrfs .*subvol=/@(,|$)"'
assert "booted kernel is 'linux'" test "$(inst 'cat /usr/lib/modules/$(uname -r)/pkgbase')" = linux
assert "no required install step FAILED" inst '! grep -q "^required.*FAILED$" /var/log/torchos-install-steps.tsv'
assert "no home-probe from the old installation" inst 'test ! -e ~/home-probe'
DOC=$(inst 'torch doctor; echo "rc=$?"'); echo "$DOC" > "$OUT/D2-doctor.txt"
assert "torch doctor exits 0" has '^rc=0$' "$DOC"
assert "data disk still byte-identical after booting the new system" test "$(vdb_sum inst)" = "$SUM0"
inst 'sync'; stop_vm
finish
