#!/usr/bin/env bash
# B. Rejections on a disk holding an existing installation (overlay of image/vm/A-installed.qcow2 from supported.sh).
#  B1 BIOS boot (real SeaBIOS)            B2 erase + swap partition     B3 erase + ext4
#  B4 "Replace a partition" (vda2)        B5 "Install alongside" (vda2) B6 erase + "Encrypt system"
#  B2/B3/B6 re-enable the option in the LIVE session's partition.conf (test only), proving the gate itself rejects
#  them even if the configuration ever offers them again. B4/B5 are offered by Calamares on any disk that holds an OS.
#  B4-B6 need a mouse click on the partition page: VNC/monitor pointer events never reach Hyprland, so ydotool
#  (uinput) is installed into the live session's RAM overlay for the test. Manual partitioning is not driven.
# Evidence that nothing destructive ran, per case:
#  - Calamares' job log: the gate is the only job that started, every later non-emergency job was skipped;
#  - the disk as the live session sees it (partition table + geometry, signatures with offsets, UUIDs/labels)
#    is identical before and after.
#  `qemu-img compare` is printed for information only: identical images prove nothing was written, but differing
#  ones do not prove a partition operation (the guest may write ordinary metadata).
source "$(dirname "$0")/lib.sh"
[ -f image/vm/A-installed.qcow2 ] || { echo "run supported.sh first (needs image/vm/A-installed.qcow2)" >&2; exit 2; }
written() { qemu-img compare -q image/vm/A-installed.qcow2 "image/vm/$1" && echo "identical" || echo "differ (informational)"; }
# reject_case <id> <reason ERE>: install attempt in the running live session, then all the evidence.
reject_case() {  # [TORCH_PARTITION_ACTION=<live command>]
  local id=$1 reason=$2 before after rc log
  before=$(disk_state /dev/vda); printf '%s\n' "$before" > "$OUT/$id-disk-before.txt"
  assert "$id: target disk holds the existing installation (GPT + btrfs)" \
    sh -c 'printf "%s\n" "$1" | grep -q "label: gpt" && printf "%s\n" "$1" | grep -q "TYPE=btrfs"' _ "$before"
  install_via_ui 1800; rc=$?
  sleep 3; shot "$id-refused"
  assert "$id: Calamares reported failure (drive_install rc=$rc, 1 expected)" test "$rc" = 1
  log=$(session_log "$id")
  grep -nE "torchpreflight|Starting|Skipping" <<<"$log" | tail -25
  assert_gate_rejected "$log" "$reason"
  # The values line starts with /sys/firmware/efi=; every other torchpreflight line is one rejection reason.
  assert "$id: the gate gave exactly one reason" \
    test "$(grep 'torchpreflight: ' <<<"$log" | grep -v 'torchpreflight: /sys/firmware/efi=' | grep -vc 'supported configuration')" = 1
  after=$(disk_state /dev/vda); printf '%s\n' "$after" > "$OUT/$id-disk-after.txt"
  assert "$id: partition table, signatures and UUIDs unchanged" test "$before" = "$after"
}

echo "== B1 BIOS boot ($(ts))"
overlay A-installed.qcow2 B1.qcow2
qemu_run bios - "$ISO" image/vm/B1.qcow2
wait_ssh live 60 || abort "B1 live session reachable"; wait_calamares || abort "B1 Calamares mapped"
assert "B1: live session booted in BIOS mode" live 'test ! -d /sys/firmware/efi'
reject_case B1 'BIOS/legacy mode'
stop_vm; echo "B1 qemu-img compare: $(written B1.qcow2)"

echo "== B2-B6 UEFI ($(ts))"
overlay A-installed.qcow2 B2.qcow2; fresh_vars image/vm/B2.vars
qemu_run uefi image/vm/B2.vars "$ISO" image/vm/B2.qcow2
wait_ssh live 60 || abort "B2 live session reachable"; wait_calamares || abort "B2 Calamares mapped"
assert "B2: live session booted in UEFI mode" live 'test -d /sys/firmware/efi'
live 'sudo sed -i "s/^userSwapChoices:.*/userSwapChoices: [ none, small ]/; s/^initialSwapChoice:.*/initialSwapChoice: small/" /etc/calamares/modules/partition.conf; grep Swap /etc/calamares/modules/partition.conf'
relaunch_calamares || abort "B2 Calamares relaunched"
reject_case B2 "Swap choice 'small'"
live 'sudo sed -i "s/^userSwapChoices:.*/userSwapChoices: [ none ]/; s/^initialSwapChoice:.*/initialSwapChoice: none/; s/^defaultFileSystemType:.*/defaultFileSystemType: \"ext4\"/; s/^availableFileSystemTypes:.*/availableFileSystemTypes: [ \"ext4\" ]/" /etc/calamares/modules/partition.conf; grep -E "Swap|FileSystem" /etc/calamares/modules/partition.conf'
relaunch_calamares || abort "B3 Calamares relaunched"
reject_case B3 "File system 'ext4'"

# click.sh <dx> <dy>: left click at dx from the Calamares window's left edge and dy above its bottom edge (the
# partition page anchors the disk bars and the encryption checkbox to the bottom). libinput doubles relative
# motion here, so move from the origin by half the distance (even targets) and check where the cursor landed.
live 'cat > /tmp/click.sh' <<'CLICK'
export YDOTOOL_SOCKET=/tmp/.ydotool_socket
read -r X Y H < <(hyprctl clients -j | python3 -c 'import json,sys; c=[c for c in json.load(sys.stdin) if c["class"]=="io.calamares.calamares"][0]; print(c["at"][0], c["at"][1], c["size"][1])')
tx=$(( (X + $1) / 2 * 2 )); ty=$(( (Y + H - $2) / 2 * 2 ))
sudo -E ydotool mousemove --absolute -x 0 -y 0; sudo -E ydotool mousemove -x $((tx / 2)) -y $((ty / 2)); sleep 0.3
[ "$(hyprctl cursorpos)" = "$tx, $ty" ] || echo "CLICK MISPLACED: cursor $(hyprctl cursorpos), wanted $tx, $ty"
sudo -E ydotool click 0xC0 >/dev/null; sleep 2
CLICK
assert "ydotool available in the live session (test only)" \
  live 'sudo pacman -Sy --noconfirm --needed ydotool >/dev/null 2>&1 && (sudo nohup ydotoold >/dev/null 2>&1 &); sleep 2; test -S /tmp/.ydotool_socket'
live 'sudo sed -i "s/^defaultFileSystemType:.*/defaultFileSystemType: \"btrfs\"/; s/^availableFileSystemTypes:.*/availableFileSystemTypes: [ \"btrfs\" ]/; s/^initialPartitioningChoice:.*/initialPartitioningChoice: replace/" /etc/calamares/modules/partition.conf'
relaunch_calamares || abort "B4 Calamares relaunched"
TORCH_PARTITION_ACTION='bash /tmp/click.sh 748 190' reject_case B4 "Partitioning choice 'replace'"
live 'sudo sed -i "s/^initialPartitioningChoice:.*/initialPartitioningChoice: alongside/" /etc/calamares/modules/partition.conf'
relaunch_calamares || abort "B5 Calamares relaunched"
TORCH_PARTITION_ACTION='bash /tmp/click.sh 748 169' reject_case B5 "Partitioning choice 'alongside'"
live 'sudo sed -i "s/^initialPartitioningChoice:.*/initialPartitioningChoice: erase/; s/^enableLuksAutomatedPartitioning:.*/enableLuksAutomatedPartitioning: true/" /etc/calamares/modules/partition.conf'
relaunch_calamares || abort "B6 Calamares relaunched"
TORCH_PARTITION_ACTION='bash /tmp/click.sh 206 204 && export YDOTOOL_SOCKET=/tmp/.ydotool_socket && sudo -E ydotool key 15:1 15:0 && sudo -E ydotool type luks-test-only && sudo -E ydotool key 15:1 15:0 && sudo -E ydotool type luks-test-only && sleep 1' \
  reject_case B6 "Disk encryption is not supported"
stop_vm; echo "B2-B6 qemu-img compare: $(written B2.qcow2)"
finish
