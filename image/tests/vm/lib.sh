# shellcheck shell=bash
# Shared helpers for the installer VM scenarios in this directory (sourced, not run).
#
# Linux host with KVM, OVMF (/usr/share/OVMF), docker, python3, qemu-img, ss; a dev ISO built with DEV_SSH_PUBKEY
# (sshd + key, needed for every scenario here). Only qcow2/vars files under image/vm/ are ever written.
# Env: TORCH_TEST_PW (or image/vm/.testpw; throwaway password for the test user)  VMRAM (MiB, default 3072)
#      RENDER=blob|virgl|plain as for image/scripts/run-qemu.sh (default blob)   TORCH_VM_KEY (ssh key, see vmssh.sh)
#      ISO (default: newest image/out/*.iso)
#
# Every check goes through assert/pass/fail: results land in image/vm/evidence/results.tsv, and a scenario exits
# non-zero if any check failed. Reaching the last line is not a pass; "<scenario>: PASS" is.
# Process safety: a scenario only ever stops the QEMU process it started itself (by PID), and refuses to start
# if the SSH/VNC ports are already taken (another VM would otherwise receive our keystrokes).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 2
PW=${TORCH_TEST_PW:-$(cat image/vm/.testpw 2>/dev/null)}
[ -n "$PW" ] || { echo "set TORCH_TEST_PW or create image/vm/.testpw (throwaway password)" >&2; exit 2; }
export TORCH_TEST_PW=$PW
VMRAM=${VMRAM:-3072}
RENDER=${RENDER:-blob}
OUT=image/vm/evidence; mkdir -p "$OUT"
QLOG=$OUT/qemu.log
# shellcheck disable=SC2034  # used by the scenarios that source this file
BLANK=image/vm/torchos-test-blank-01.qcow2
ISO=${ISO:-$(ls -t image/out/*.iso 2>/dev/null | head -1)}
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TPL=/usr/share/OVMF/OVMF_VARS_4M.fd
SSH_PORT=2222 VNC_PORT=5901   # fixed: vmssh.sh and vnc.py default to these
SCEN=${SCEN:-$(basename "$0" .sh)}
RES=$OUT/results.tsv
NFAIL=0
VM_PID=

ts() { date +%T; }
pass() { printf '%s\t%s\tPASS\t%s\n' "$(date -Is)" "$SCEN" "$1" | tee -a "$RES"; }
fail() { printf '%s\t%s\tFAIL\t%s\n' "$(date -Is)" "$SCEN" "$1" | tee -a "$RES"; NFAIL=$((NFAIL + 1)); }
assert() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
# A known product defect outside the scenario's subject: recorded and reported, does not fail the scenario.
defect() { printf '%s\t%s\tDEFECT\t%s\n' "$(date -Is)" "$SCEN" "$1" | tee -a "$RES"; }
has() { grep -qE -- "$1" <<<"$2"; }        # has <ERE> <text>
lacks() { ! grep -qE -- "$1" <<<"$2"; }
finish() {
  stop_vm
  if [ "$NFAIL" -eq 0 ]; then echo "$SCEN: PASS ($(ts))"; exit 0; fi
  echo "$SCEN: FAIL, $NFAIL failed check(s) ($(ts))"; exit 1
}
abort() { fail "$1 (scenario aborted)"; finish; }
trap stop_vm EXIT

live() { VM_USER=liveuser image/scripts/dev/vmssh.sh "$@"; }
inst() { VM_USER=${TORCH_TEST_USER:-tester} image/scripts/dev/vmssh.sh "$@"; }
isudo() { inst "echo '$PW' | sudo -S -p '' $*"; }   # root command on the installed system; $* must not contain '
monitor() { python3 -c "
import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect('image/vm/monitor.sock'); s.recv(4096); s.sendall((sys.argv[1]+'\n').encode()); time.sleep(1)" "$1"; }
wait_ssh() {  # wait_ssh live|inst [tries x 10 s]
  for _ in $(seq 1 "${2:-60}"); do
    vm_alive || { echo "qemu exited"; return 1; }
    "$1" true 2>/dev/null && return 0; sleep 10
  done
  echo "ssh never came up"; return 1
}
# Reboot the installed system and wait until a *new* boot answers (boot_id changed), so a slow shutdown
# can never be mistaken for the next boot.
reboot_wait() {
  local old new; old=$(inst 'cat /proc/sys/kernel/random/boot_id')
  inst sync; isudo 'systemctl reboot' >/dev/null 2>&1; sleep 20
  for _ in $(seq 1 60); do
    vm_alive || return 1
    new=$(inst 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && [ -n "$new" ] && [ "$new" != "$old" ] && return 0
    sleep 10
  done
  return 1
}
calamares_mapped() { live 'hyprctl clients | grep -q io.calamares.calamares' 2>/dev/null; }
# The live session must start Calamares by itself (live.lua from torch-live-setup); the harness never starts it here.
wait_calamares() {
  for _ in $(seq 1 40); do calamares_mapped && { sleep 10; return 0; }; sleep 5; done
  echo "calamares never mapped"; return 1
}
shot() { python3 image/scripts/dev/vnc.py shot "$OUT/$1.png" >/dev/null 2>&1 && echo "screenshot: $OUT/$1.png"; }
mem() { echo "mem $(ts): $(free -m | awk '/Mem:/{print "used="$3"M avail="$7"M"}')"; }

# --- QEMU process ownership -------------------------------------------------------------------------------
listeners() { ss -Hltn "( sport = :$SSH_PORT or sport = :$VNC_PORT )" | awk '{print $4}'; }
vm_alive() { [ -n "$VM_PID" ] && kill -0 "$VM_PID" 2>/dev/null; }
before_start() {
  [ -z "$VM_PID" ] || abort "a VM from this scenario is still running (pid $VM_PID)"
  [ -z "$(listeners)" ] || abort "ports $SSH_PORT/$VNC_PORT already in use: $(listeners | tr '\n' ' ')"
}
# Called right after a background launch: remember OUR qemu (run-qemu.sh execs qemu, so $! is qemu itself).
launched() {
  VM_PID=$1; sleep 3
  vm_alive || { cat "$QLOG"; VM_PID=; abort "qemu did not start"; }
  [ "$(cat "/proc/$VM_PID/comm")" = qemu-system-x86 ] || abort "pid $VM_PID is not qemu"
  for _ in 1 2 3 4 5; do [ -n "$(listeners)" ] && break; sleep 1; done
  local l; l=$(listeners)
  assert "qemu pid $VM_PID: SSH/VNC listen on loopback only ($(tr '\n' ' ' <<<"$l"))" \
    sh -c '[ -n "$1" ] && ! printf "%s\n" "$1" | grep -qv "^127\.0\.0\.1:"' _ "$l"
}
stop_vm() {
  vm_alive || { VM_PID=; return 0; }
  monitor quit 2>/dev/null
  for _ in $(seq 1 30); do vm_alive || break; sleep 2; done
  # Still up: terminate only the process this scenario started, after re-checking it is qemu.
  if vm_alive && [ "$(cat "/proc/$VM_PID/comm" 2>/dev/null)" = qemu-system-x86 ]; then kill "$VM_PID"; fi
  wait "$VM_PID" 2>/dev/null
  VM_PID=
}

# --- launching --------------------------------------------------------------------------------------------
install_via_ui() {  # drive Calamares Welcome -> Install; rc 0 = success, 1 = installer reported failure, other = harness
  VM_USER=liveuser timeout "${1:-3600}" python3 image/scripts/dev/drive_install.py
}
# Single-disk runs use the repo's launcher.
start_iso() {
  before_start; image/scripts/run-qemu.sh blank-reset >/dev/null
  RENDER=$RENDER DISPLAY_MODE=vnc RAM=$VMRAM image/scripts/run-qemu.sh iso "$ISO" > "$QLOG" 2>&1 &
  launched $!
}
start_disk() {
  before_start
  RENDER=$RENDER DISPLAY_MODE=vnc RAM=$VMRAM image/scripts/run-qemu.sh disk > "$QLOG" 2>&1 &
  launched $!
}
# qemu_run <uefi|bios> <vars-file|-> <iso|-> <disk1> [disk2]: the same devices as run-qemu.sh, for multi-disk runs.
qemu_run() {
  local fw=$1 vars=$2 iso=$3 d1=$4 d2=${5:-} a=() gpu=()
  before_start
  case $RENDER in
    blob)  gpu=(-object memory-backend-memfd,id=mem1,size="${VMRAM}M" -machine memory-backend=mem1 -device virtio-gpu-pci,blob=true,hostmem=256M -display none) ;;
    virgl) gpu=(-device virtio-vga-gl,xres=1280,yres=800 -display gtk,gl=on) ;;
    *)     gpu=(-device virtio-gpu-pci -display none) ;;
  esac
  [ "$fw" = uefi ] && a+=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$vars")
  a+=(-drive file="$d1",if=virtio,format=qcow2)
  [ -n "$d2" ] && a+=(-drive file="$d2",if=virtio,format=qcow2)
  if [ "$iso" != - ]; then a+=(-drive file="$iso",media=cdrom,readonly=on -boot order=d); else a+=(-boot order=c); fi
  qemu-system-x86_64 -name torchos -enable-kvm -cpu host -smp 2 -m "$VMRAM" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 -device virtio-net-pci,netdev=net0 "${gpu[@]}" \
    -vnc 127.0.0.1:$((VNC_PORT - 5900)) \
    -device qemu-xhci -device usb-tablet -monitor unix:image/vm/monitor.sock,server,nowait \
    -serial file:image/vm/serial.log "${a[@]}" > "$QLOG" 2>&1 &
  launched $!
}
fresh_vars() { cp "$OVMF_VARS_TPL" "$1"; }
overlay() { rm -f "image/vm/$2"; qemu-img create -q -f qcow2 -b "$1" -F qcow2 "image/vm/$2"; }  # overlay <base-name> <new-name>
# Test-only live-session config edits need Calamares restarted; the old session.log is moved aside so
# drive_install.py cannot read the previous run's verdict.
relaunch_calamares() {
  live 'sudo pkill -x calamares; sleep 3; sudo mv ~/.cache/calamares/session.log ~/.cache/calamares/session.prev-$(date +%s).log 2>/dev/null; (nohup calamares-launch >/dev/null 2>&1 &); sleep 1'
  wait_calamares
}

# --- Calamares and disk evidence ------------------------------------------------------------------------------
# JobQueue (3.4.2) logs `Starting job <name> ( i / n )` for every job it runs, `Skipping non-emergency job <name>`
# for every job it skips after a failure, and `Starting EMERGENCY JOB <name>` for umount.
session_log() { live 'cat ~/.cache/calamares/session.log' > "$OUT/$1-session.log"; cat "$OUT/$1-session.log"; }
started_jobs() { grep -oE 'Starting job .*' <<<"$1"; }
# Calamares 3.4.2 logs Python jobs by module name, not by pretty_name(): 'Starting job "torchpreflight" ( 1 / 30 )'.
PREFLIGHT_JOB='"torchpreflight"'
# The gate ran first, rejected, and every later non-emergency job was skipped (nothing destructive started).
assert_gate_rejected() {  # <log> <reason ERE>
  local log=$1 jobs; jobs=$(started_jobs "$log")
  assert "exactly one job started, and it is the install gate" \
    sh -c '[ "$(printf "%s\n" "$1" | grep -c .)" = 1 ] && printf "%s\n" "$1" | grep -qF "$2"' _ "$jobs" "$PREFLIGHT_JOB"
  assert "gate logged the rejection reason /$2/" has "torchpreflight: .*$2" "$log"
  assert "later jobs (partition first) were skipped" has 'Skipping non-emergency job' "$log"
  assert "Calamares reported installation failure" has 'onInstallationFailed|Installation failed' "$log"
}
# Disk state seen from the live session, for before/after comparison: partition table and geometry, every
# signature wipefs finds (with offsets), every UUID/label. Read-only: no mounting, no writing.
disk_state() {  # disk_state <dev>
  live "sudo sfdisk -d $1 2>&1; echo '-- wipefs'; sudo wipefs -n $1 $1?* 2>&1; echo '-- blkid'; sudo blkid -o export $1 $1?* 2>&1"
}

# --- TorchOS desktop (Hyprland Lua config) ------------------------------------------------------------------------
# assert_torch_desktop <live|inst> <id> <expected bind count>: Hyprland really loaded TorchOS's config (not the
# autogenerated stock one), with TorchOS's styling and binds, each session program running exactly once, and the
# keyboard shortcuts working. Run while the session is on screen (keys go through the QEMU monitor).
hj() { "$1" "hyprctl $2 -j | python3 -c \"import json,sys; d=json.load(sys.stdin); print($3)\""; }  # hj <who> <cmd> <expr on d>
opt() { hj "$1" "getoption $2" "d.get('int', d.get('str', d.get('gradient', d.get('bool'))))"; }
nproc_of() { "$1" "pgrep -cx $2"; }
assert_torch_desktop() {
  local who=$1 id=$2 nbinds=$3 p before
  assert "$id: no Hyprland config errors" test -z "$("$who" 'hyprctl configerrors' | tr -d '[:space:]')"
  assert "$id: hyprland.lua is TorchOS's, not the autogenerated stock config" \
    "$who" 'head -1 ~/.config/hypr/hyprland.lua | grep -q "TorchOS Hyprland configuration" && ! grep -rq "autogenerated = true" ~/.config/hypr'
  assert "$id: no legacy hyprland.conf in ~/.config/hypr" "$who" 'test ! -e ~/.config/hypr/hyprland.conf'
  assert "$id: border 2, rounding 6, dwindle" \
    test "$(opt "$who" general:border_size) $(opt "$who" decoration:rounding) $(opt "$who" general:layout)" = "2 6 dwindle"
  assert "$id: TorchOS border colours (ff4500 / 2b0a00)" \
    test "$(opt "$who" general:col.active_border) $(opt "$who" general:col.inactive_border)" = "ffff4500 0deg ff2b0a00 0deg"
  assert "$id: $nbinds binds loaded" test "$(hj "$who" binds 'len(d)')" = "$nbinds"
  assert "$id: media keys work while locked" test "$(hj "$who" binds "sum(b['locked'] for b in d if b['key'].startswith('XF86'))")" = 5
  assert "$id: waybar layer mapped" test "$(hj "$who" layers "sum(l['namespace']=='waybar' for m in d.values() for lv in m['levels'].values() for l in lv)")" -ge 1
  for p in waybar mako hypridle swayosd-server torch-welcome; do
    assert "$id: $p running exactly once" test "$(nproc_of "$who" "$p")" = 1
  done
  assert "$id: clipboard watchers running exactly twice (text + image)" test "$(nproc_of "$who" wl-paste)" = 2
  [ "$(nproc_of "$who" hyprpaper)" = 1 ] || defect "$id: hyprpaper not running (known VM-only GBM/DRM crash, CLAUDE.md gotchas)"
  echo "--- $id keyboard"
  key() { python3 image/scripts/dev/qmon.py keys "$@"; sleep 2; }
  ws() { hj "$who" activeworkspace "d['id']"; }
  ncls() { hj "$who" clients "sum(c['class']=='$1' for c in d)"; }
  # The VM has two outputs; workspace 2 starts on the second, which VNC screenshots do not show (hyprctl does).
  key meta_l-2; assert "$id: SUPER+2 switches to workspace 2" test "$(ws)" = 2
  before=$(ncls kitty); key meta_l-q; sleep 2
  assert "$id: SUPER+Q opens a kitty terminal" test "$(ncls kitty)" = $((before + 1))
  shot "$id-terminal"
  key meta_l-c; sleep 1; assert "$id: SUPER+C closes it" test "$(ncls kitty)" = "$before"
  key meta_l-1; assert "$id: SUPER+1 back to workspace 1" test "$(ws)" = 1
  key meta_l-d; sleep 2; assert "$id: SUPER+D opens the wofi launcher" test "$(nproc_of "$who" wofi)" = 1
  shot "$id-launcher"; key esc; sleep 1
  assert "$id: Escape closes the launcher" test "$(nproc_of "$who" wofi)" = 0
  "$who" 'hyprctl reload >/dev/null'; sleep 3
  assert "$id: after a config reload: no errors, same binds, no second autostart" \
    test "$("$who" 'hyprctl configerrors' | tr -d '[:space:]')|$(hj "$who" binds 'len(d)')|$(nproc_of "$who" waybar)$(nproc_of "$who" mako)$(nproc_of "$who" torch-welcome)" = "|$nbinds|111"
}
