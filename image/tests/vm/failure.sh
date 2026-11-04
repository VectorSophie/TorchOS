#!/usr/bin/env bash
# F. Removable-media fallback loader: boot image/vm/A-installed.qcow2 with EMPTY firmware variables (no TorchOS
#    boot entry), which is what makes a missing NVRAM entry "optional" in torch-target-verify.
# C. Required-step failure: pacman-key is made unexecutable inside the target through the LIVE session's
#    shellprocess config (test only; shipped code is unchanged). Calamares must report failure and skip
#    grubcfg/bootloader/verify. This is NOT a rollback: what was written before the failure (partitions, unpacked
#    files) stays on the disk, and the checks below document that.
source "$(dirname "$0")/lib.sh"
[ -f image/vm/A-installed.qcow2 ] || { echo "run supported.sh first (needs image/vm/A-installed.qcow2)" >&2; exit 2; }

echo "== F fallback loader ($(ts))"
overlay A-installed.qcow2 F.qcow2; fresh_vars image/vm/F.vars
qemu_run uefi image/vm/F.vars - image/vm/F.qcow2
wait_ssh inst 40 || abort "installed disk boots with empty firmware variables"
EFI=$(isudo 'efibootmgr -v'); echo "$EFI" | tee "$OUT/F-efibootmgr.txt"
CUR=$(sed -nE 's/^BootCurrent: ([0-9A-F]{4}).*/\1/p' <<<"$EFI")
assert "firmware has no TorchOS boot entry" lacks 'TorchOS' "$EFI"
assert "booted through the removable-media path, not EFI/TorchOS (Boot$CUR)" \
  sh -c '[ -n "$2" ] && printf "%s\n" "$1" | grep -E "^Boot$2" | grep -viq "TorchOS"' _ "$EFI" "$CUR"
assert "booted kernel is 'linux'" test "$(inst 'cat /usr/lib/modules/$(uname -r)/pkgbase')" = linux
inst 'systemctl is-system-running'
shot F-fallback; inst sync; stop_vm

echo "== C required step failure ($(ts))"
start_iso; wait_ssh live 60 || abort "live session reachable"; wait_calamares || abort "Calamares mapped"
live 'sudo sed -i "s#\"/usr/lib/torchos/torch-target-setup\"#\"chmod -x /usr/bin/pacman-key; /usr/lib/torchos/torch-target-setup\"#" /etc/calamares/modules/shellprocess_setup.conf && grep -A2 script /etc/calamares/modules/shellprocess_setup.conf'
relaunch_calamares || abort "Calamares relaunched"
install_via_ui 3600; rc=$?; sleep 3; shot C-required-step-failed
assert "Calamares reported failure (drive_install rc=$rc, 1 expected)" test "$rc" = 1
LOG=$(session_log C)
grep -nE "Starting|Skipping|TORCHOS INSTALL FAILED|required step" <<<"$LOG" | tail -25
assert "gate accepted the configuration (the failure is later)" has "torchpreflight: supported configuration" "$LOG"
# The log holds the failed script's whole trace (MBs): test it in-shell, never as one argv string (128 KiB limit).
skipped_not_started() { lacks "Starting job .$1. " "$LOG" && has "Skipping non-emergency job .$1." "$LOG"; }
assert "grubcfg was skipped, not started" skipped_not_started grubcfg
assert "bootloader was skipped, not started" skipped_not_started bootloader
assert "at least 3 jobs skipped (grubcfg, bootloader, verify)" test "$(grep -c 'Skipping non-emergency job' <<<"$LOG")" -ge 3
echo "--- what is on the disk now (not rolled back)"
DISK=$(live 'lsblk -o NAME,FSTYPE,PTTYPE /dev/vda; sudo mkdir -p /mnt/t /mnt/e; sudo mount -o ro,subvol=@log /dev/vda2 /mnt/t && { echo "-- steps"; sudo cat /mnt/t/torchos-install-steps.tsv; echo "-- install log"; sudo grep -E "TORCHOS INSTALL FAILED|CHECK FAILED" /mnt/t/torchos-install.log; sudo umount /mnt/t; }; sudo mount -o ro /dev/vda1 /mnt/e && { echo "-- esp"; sudo find /mnt/e; sudo umount /mnt/e; }; echo "-- nvram"; sudo efibootmgr')
echo "$DISK" | tee "$OUT/C-disk-after.txt"
assert "step record on the target shows package-trust FAILED" has "^required	package-trust	FAILED$" "$DISK"
# /var/log is the @log subvolume; Calamares does not log a shellprocess's output, the target's install log has it.
assert "torch-target-setup named the failed required step" has "TORCHOS INSTALL FAILED: required step 'package-trust'" "$DISK"
assert "no step after package-trust ran (login is the next required step)" lacks "^required	login	" "$DISK"
assert "partitions from before the failure remain (documented: no rollback)" has "vda2 +btrfs" "$DISK"
assert "no GRUB loader on the ESP" lacks 'EFI/(TorchOS|boot)/' "$DISK"
assert "no TorchOS firmware boot entry" lacks 'TorchOS' "$(sed -n '/^-- nvram/,$p' <<<"$DISK")"
live 'sync'; stop_vm
echo "== C2 try to boot that disk without the ISO ($(ts))"
start_disk; sleep 120; shot C2-boot-attempt
assert "qemu still running (no crash) while nothing boots" vm_alive
no_ssh() { ! inst true 2>/dev/null; }
assert "no installed system answers on SSH" no_ssh
stop_vm
rm -f "$BLANK"
finish
