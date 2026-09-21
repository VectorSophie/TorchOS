#!/usr/bin/env bash
# Launch TorchOS in QEMU/KVM. Never touches a host disk: only qcow2 files under image/.
#
#   run-qemu.sh installed            boot the installed disk   (image/vm/torchos-vm.qcow2, BIOS, existing Phase 1 VM)
#   run-qemu.sh iso  [file.iso]      boot the live ISO on a fresh blank UEFI disk (image/vm/blank.qcow2 is created if missing)
#   run-qemu.sh disk                 boot the blank disk alone (after installing from the ISO)
#   run-qemu.sh blank-reset          delete and recreate the blank disk + its OVMF vars
#
# Env: RAM=2048 CPUS=2 DISPLAY_MODE=gtk|vnc (default gtk; vnc listens on :1 = port 5901)
#      RENDER=blob|plain (default blob)  SSH_PORT=2222 (guest :22 forwarded to host localhost)
set -euo pipefail
cd "$(dirname "$0")/../.."
MODE=${1:-installed}
RAM=${RAM:-2048}; CPUS=${CPUS:-2}; SSH_PORT=${SSH_PORT:-2222}
DISPLAY_MODE=${DISPLAY_MODE:-gtk}
VM=image/vm; mkdir -p "$VM"
BLANK=$VM/torchos-test-blank-01.qcow2
VARS=$VM/OVMF_VARS.fd
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TPL=/usr/share/OVMF/OVMF_VARS_4M.fd

case $DISPLAY_MODE in
  gtk) DISP=(-display gtk) ;;
  vnc) DISP=(-display none -vnc :1) ;;
  *) echo "DISPLAY_MODE must be gtk or vnc" >&2; exit 2 ;;
esac

# blob=true + memfd is what lets Hyprland/aquamarine render in this VM (see CLAUDE.md gotchas);
# needs /dev/udmabuf access (kvm group). RENDER=plain drops it if that is unavailable.
if [[ ${RENDER:-blob} == blob ]]; then
  GPU=(-object memory-backend-memfd,id=mem1,size="${RAM}M" -machine memory-backend=mem1 -device virtio-gpu-pci,blob=true,hostmem=256M)
else
  GPU=(-device virtio-gpu-pci)
fi
COMMON=(-name torchos -enable-kvm -cpu host -smp "$CPUS" -m "$RAM"
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0
  "${GPU[@]}" -device qemu-xhci -device usb-tablet -device intel-hda -device hda-duplex
  "${DISP[@]}")
UEFI=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$VARS")

ensure_blank() {
  [[ -f $BLANK ]] || qemu-img create -f qcow2 "$BLANK" 40G >/dev/null
  [[ -f $VARS ]] || cp "$OVMF_VARS_TPL" "$VARS"
}

case $MODE in
  installed)
    exec qemu-system-x86_64 "${COMMON[@]}" -drive file=$VM/torchos-vm.qcow2,if=virtio,format=qcow2 -boot order=c ;;
  iso)
    ISO=${2:-$(ls -t image/out/*.iso 2>/dev/null | head -1)}
    [[ -f ${ISO:-} ]] || { echo "no ISO found; build one with image/scripts/build-iso.sh" >&2; exit 1; }
    ensure_blank
    echo "ISO:  $ISO"; echo "DISK: $BLANK (blank test disk, the only writable disk)"
    exec qemu-system-x86_64 "${COMMON[@]}" "${UEFI[@]}" \
      -drive file="$BLANK",if=virtio,format=qcow2 \
      -drive file="$ISO",media=cdrom,readonly=on -boot order=d ;;
  disk)
    ensure_blank
    exec qemu-system-x86_64 "${COMMON[@]}" "${UEFI[@]}" -drive file="$BLANK",if=virtio,format=qcow2 -boot order=c ;;
  blank-reset)
    rm -f "$BLANK" "$VARS"; ensure_blank; echo "fresh blank disk: $BLANK" ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
