# Shared helpers for the installer VM scenarios in this directory (sourced, not run).
# STATUS: drafted 2026-11-02 and NEVER EXECUTED (the ISO build on the original host failed first). Expect harness
# fixes on the first real run; a harness failure is not a product failure. See README.md.
#
# Linux host with KVM, OVMF (/usr/share/OVMF), docker, python3, qemu-img; a dev ISO built with DEV_SSH_PUBKEY
# (sshd + key, needed for every scenario here). Only qcow2 files under image/vm/ are ever written.
# Env: TORCH_TEST_PW (or image/vm/.testpw; throwaway password for the test user)  VMRAM (MiB, default 3072)
#      RENDER=blob|virgl|plain as for image/scripts/run-qemu.sh (default blob)   TORCH_VM_KEY (ssh key, see vmssh.sh)
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 2
PW=${TORCH_TEST_PW:-$(cat image/vm/.testpw 2>/dev/null)}
[ -n "$PW" ] || { echo "set TORCH_TEST_PW or create image/vm/.testpw (throwaway password)" >&2; exit 2; }
export TORCH_TEST_PW=$PW
VMRAM=${VMRAM:-3072}
RENDER=${RENDER:-blob}
OUT=image/vm/evidence; mkdir -p "$OUT"
BLANK=image/vm/torchos-test-blank-01.qcow2
ISO=${ISO:-$(ls -t image/out/*.iso 2>/dev/null | head -1)}
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TPL=/usr/share/OVMF/OVMF_VARS_4M.fd

ts() { date +%T; }
live() { VM_USER=liveuser image/scripts/dev/vmssh.sh "$@"; }
inst() { VM_USER=${TORCH_TEST_USER:-tester} image/scripts/dev/vmssh.sh "$@"; }
monitor() { python3 -c "
import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect('image/vm/monitor.sock'); s.recv(4096); s.sendall((sys.argv[1]+'\n').encode()); time.sleep(1)" "$1"; }
wait_ssh() {  # wait_ssh live|inst [tries x 10 s]
  for _ in $(seq 1 "${2:-60}"); do "$1" true 2>/dev/null && return 0; sleep 10; done
  echo "ssh never came up"; return 1
}
wait_down() { for _ in $(seq 1 30); do pgrep -f 'qemu-system-x86_64 -name torchos' >/dev/null || return 0; sleep 2; done; }
wait_calamares() {
  for _ in $(seq 1 40); do live 'hyprctl clients | grep -q io.calamares.calamares' 2>/dev/null && { sleep 10; return 0; }; sleep 5; done
  echo "calamares never mapped"; return 1
}
shot() { python3 image/scripts/dev/vnc.py shot "$OUT/$1.png" >/dev/null 2>&1 && echo "screenshot: $OUT/$1.png"; }
stop_vm() { monitor quit 2>/dev/null; wait_down; pkill -f 'qemu-system-x86_64 -name torchos' 2>/dev/null; wait_down; }
mem() { echo "mem $(ts): $(free -m | awk '/Mem:/{print "used="$3"M avail="$7"M"}')"; }
install_via_ui() {  # drive Calamares Welcome -> Install with the test user; rc 0 = success, 1 = installer failure
  VM_USER=liveuser timeout "${1:-3600}" python3 image/scripts/dev/drive_install.py
}
# Single-disk runs use the repo's launcher.
start_iso() { image/scripts/run-qemu.sh blank-reset >/dev/null; RENDER=$RENDER DISPLAY_MODE=vnc RAM=$VMRAM image/scripts/run-qemu.sh iso "$ISO" > /tmp/torch-qemu.log 2>&1 & }
start_disk() { RENDER=$RENDER DISPLAY_MODE=vnc RAM=$VMRAM image/scripts/run-qemu.sh disk > /tmp/torch-qemu.log 2>&1 & }
# qemu_run <uefi|bios> <vars-file|-> <iso|-> <disk1> [disk2]: the same devices as run-qemu.sh, for multi-disk runs.
qemu_run() {
  local fw=$1 vars=$2 iso=$3 d1=$4 d2=${5:-} a=() gpu=()
  case $RENDER in
    blob)  gpu=(-object memory-backend-memfd,id=mem1,size="${VMRAM}M" -machine memory-backend=mem1 -device virtio-gpu-pci,blob=true,hostmem=256M -display none -vnc :1) ;;
    virgl) gpu=(-device virtio-vga-gl,xres=1280,yres=800 -display gtk,gl=on -vnc :1) ;;
    *)     gpu=(-device virtio-gpu-pci -display none -vnc :1) ;;
  esac
  [ "$fw" = uefi ] && a+=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$vars")
  a+=(-drive file="$d1",if=virtio,format=qcow2)
  [ -n "$d2" ] && a+=(-drive file="$d2",if=virtio,format=qcow2)
  if [ "$iso" != - ]; then a+=(-drive file="$iso",media=cdrom,readonly=on -boot order=d); else a+=(-boot order=c); fi
  qemu-system-x86_64 -name torchos -enable-kvm -cpu host -smp 2 -m "$VMRAM" \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 "${gpu[@]}" \
    -device qemu-xhci -device usb-tablet -monitor unix:image/vm/monitor.sock,server,nowait \
    -serial file:image/vm/serial.log "${a[@]}" > /tmp/torch-qemu.log 2>&1 &
}
fresh_vars() { cp "$OVMF_VARS_TPL" "$1"; }
overlay() { rm -f "image/vm/$2"; qemu-img create -q -f qcow2 -b "$1" -F qcow2 "image/vm/$2"; }  # overlay <base-name> <new-name>
# Test-only live-session config edits need Calamares restarted; the old session.log is moved aside so
# drive_install.py cannot read the previous run's verdict.
relaunch_calamares() {
  live 'sudo pkill -x calamares; sleep 3; sudo mv ~/.cache/calamares/session.log ~/.cache/calamares/session.prev-$(date +%s).log 2>/dev/null; (nohup calamares-launch >/dev/null 2>&1 &); sleep 1'
  wait_calamares
}
