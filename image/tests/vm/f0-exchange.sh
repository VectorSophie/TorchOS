#!/usr/bin/env bash
# F0 (docs/decisions/0003-recovery-integrity.md §7): can renameat2(RENAME_EXCHANGE) swap two Btrfs subvolume roots
# (@ and a writable copy of a snapshot) on the kernel and layout TorchOS ships, and does every crash state still
# have an @ that boots by itself? Gate for the R-A rollback design. Kernel capability probe: it drives btrfs and the
# syscall directly as root inside the VM (no torchd involved), on disposable overlays of supported.sh's
# image/vm/A-installed.qcow2 (+ its OVMF vars as image/vm/A-installed.vars). Power cut = QEMU monitor `quit`.
#   a  exchange, syncfs, clean reboot -> swapped root; then exchange back, reboot -> original root
#   b  exchange, NO sync, power cut   -> boots unaided, @ is U0 or Un, names consistent
#   c  exchange, syncfs, power cut    -> boots the swapped root unaided
#   ref the OLD two-rename design's window: rename @ away, syncfs, power cut -> expected NOT to boot (R2 evidence)
source "$(dirname "$0")/lib.sh"
BASE="A-installed.qcow2"; BVARS=image/vm/A-installed.vars
[ -f "image/vm/$BASE" ] && [ -f "$BVARS" ] || { echo "run supported.sh first (needs image/vm/$BASE and $BVARS)" >&2; exit 2; }
CASES=${F0_CASES:-a b c ref}

# Guest helper, run as root. Never touches anything but the VM's own disk.
GUEST=$(cat <<'EOF'
set -u
TOP=/run/f0top
dev=$(findmnt -no SOURCE / | sed 's/\[.*//')
mnt() { mkdir -p $TOP; mountpoint -q $TOP || mount -o subvolid=5 "$dev" $TOP; }
uuid() { btrfs subvolume show "$1" 2>/dev/null | awk '$1=="UUID:"{print $2}'; }
# The exact syscall R-A uses: renameat2(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE=2), via glibc.
xchg() { python3 -c '
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
r = libc.renameat2(-100, sys.argv[1].encode(), -100, sys.argv[2].encode(), 2)
e = ctypes.get_errno()
print("renameat2 rc=%d%s" % (r, " errno=%d %s" % (e, os.strerror(e)) if r else ""))
sys.exit(1 if r else 0)' "$1" "$2"; }
mnt
case $1 in
  facts)
    echo "booted=$(uuid /)"
    for n in $(ls -1 $TOP); do echo "name $n $(uuid $TOP/$n)"; done
    echo "default-subvol: $(btrfs subvolume get-default $TOP)"
    echo "probe-root=$(cat /etc/f0-probe 2>/dev/null || echo absent)"
    echo "probe-log=$(cat /var/log/f0-log-probe 2>/dev/null || echo absent)"
    echo "snapshots=$(snapper -c root list --columns number | grep -c '^ *[0-9]')"
    echo "kernel=$(uname -r) $(pacman -Q linux btrfs-progs glibc python | tr '\n' ' ')"
    echo "cmdline=$(cat /proc/cmdline)"
    grep -v '^#' /etc/fstab | grep . | sed 's/^/fstab: /' ;;
  prepare)  # <snapshot n>: writable copy of the snapshot, refusing an existing destination
    [ -e $TOP/@.f0-new ] && { echo "destination exists"; exit 3; }
    btrfs subvolume snapshot /.snapshots/$2/snapshot $TOP/@.f0-new >/dev/null || exit 1
    echo "U0=$(uuid $TOP/@) Un=$(uuid $TOP/@.f0-new)" ;;
  exchange) xchg $TOP/@.f0-new $TOP/@ ;;
  oldrename) mv $TOP/@ $TOP/@.f0-old && echo "renamed @ away (old design, first rename only)" ;;
  sync) sync -f $TOP && echo synced ;;
  content) echo "under-other-name probe-root=$(cat $TOP/$2/etc/f0-probe 2>/dev/null || echo absent)" ;;
esac
EOF
)
# The helper is re-sent before every call: /tmp is emptied by each reboot.
g() { inst 'cat > /tmp/f0g.sh' <<<"$GUEST"; isudo "bash /tmp/f0g.sh $*"; }
val() { grep -oE "(^| )$1=[^ ]*" <<<"$2" | head -1 | sed 's/^ *[^=]*=//'; }   # val <key> <facts>: key=value anywhere
# facts that are empty (ssh/sudo/helper broken) must abort, never compare "" = "".
facts() { local f; f=$(g facts); printf '%s\n' "$f"; [ -n "$(val booted "$f")" ] && grep -q '^name @ ' <<<"$f"; }
name_uuid() { awk -v n="$1" '$1=="name" && $2==n {print $3}' <<<"$2"; } # name_uuid <subvol name> <facts>
power_cut() { monitor quit; for _ in $(seq 1 30); do vm_alive || break; sleep 1; done; wait "$VM_PID" 2>/dev/null; VM_PID=; }
boot() { qemu_run uefi "image/vm/f0-$1.vars" - "image/vm/f0-$1.qcow2"; }

# setup <case>: fresh overlay, boot, checkpoint N, probes written after N (so U0 has them, a copy of N does not).
setup() {
  local c=$1
  overlay "$BASE" "f0-$c.qcow2"; cp "$BVARS" "image/vm/f0-$c.vars"
  boot "$c"; wait_ssh inst 60 || abort "$c: installed overlay reachable"
  inst "torch snapshot create 'F0 base $c' >/dev/null" || abort "$c: checkpoint created"
  N=$(inst 'snapper -c root list' | grep "F0 base $c" | tail -1 | cut -d"|" -f1 | tr -d " *-")
  [ -n "$N" ] || abort "$c: checkpoint number"
  isudo "sh -c 'echo root-after-snapshot > /etc/f0-probe; echo log-$c > /var/log/f0-log-probe; sync'"
  inst "echo home-$c > ~/f0-home-probe; sync"
  F_BEFORE=$(facts) || abort "facts unreadable (booted UUID or @ missing)"; echo "$F_BEFORE" > "$OUT/F0-$c-before.txt"
  U0=$(name_uuid @ "$F_BEFORE"); [ -n "$U0" ] || abort "$c: U0 read"
  assert "$c: booted root is @ (U0=$U0)" test "$(val booted "$F_BEFORE")" = "$U0"
  P=$(g prepare "$N"); echo "$P"
  Un=$(val Un "$P"); [ -n "$Un" ] || abort "$c: Un read ($P)"
  assert "$c: writable copy of snapshot $N created (Un=$Un)" test -n "$Un"
}
# Facts that must hold in every state: /home, @log, @snapshots untouched and the other probes intact.
invariants() {  # invariants <case> <facts>
  local c=$1 f=$2 n
  for n in @home @log @snapshots; do
    assert "$c: $n is the same subvolume" test "$(name_uuid $n "$f")" = "$(name_uuid $n "$F_BEFORE")"
  done
  assert "$c: /home probe intact" test "$(inst 'cat ~/f0-home-probe')" = "home-$c"
  assert "$c: @log probe intact" test "$(val probe-log "$f")" = "log-$c"
  assert "$c: snapper still lists every snapshot" test "$(val snapshots "$f")" = "$(val snapshots "$F_BEFORE")"
  assert "$c: no default-subvolume change (still 5)" has 'ID 5 ' "$f"
}
# The exchange itself, observed from the running system before any reboot.
exchange_checks() {
  local c=$1 x f
  x=$(g exchange); echo "$x"
  assert "$c: renameat2(RENAME_EXCHANGE) of two subvolume roots returned 0" has '^renameat2 rc=0$' "$x"
  f=$(facts) || abort "facts unreadable (booted UUID or @ missing)"
  assert "$c: @ now has the copy's UUID (Un)" test "$(name_uuid @ "$f")" = "$Un"
  assert "$c: @.f0-new now has the original's UUID (U0)" test "$(name_uuid @.f0-new "$f")" = "$U0"
  assert "$c: the running system still runs on U0" test "$(val booted "$f")" = "$U0"
  assert "$c: original root's content reachable under @.f0-new" has 'probe-root=root-after-snapshot' "$(g content @.f0-new)"
  assert "$c: @ (the copy) lacks the post-snapshot probe" has 'probe-root=absent' "$(g content @)"
}
relaunch_after_cut() {  # boot the same disk after a power cut; returns 1 if it never answers
  boot "$1"; wait_ssh inst 30
}

for c in $CASES; do
  echo "== F0 case $c ($(ts))"
  case $c in
  a)
    setup a; exchange_checks a
    g sync; reboot_wait || abort "a: rebooted after exchange + syncfs"
    F=$(facts) || abort "facts unreadable (booted UUID or @ missing)"; echo "$F" > "$OUT/F0-a-after.txt"
    assert "a: booted the swapped root unaided (booted=Un)" test "$(val booted "$F")" = "$Un"
    assert "a: post-snapshot probe absent in the swapped root" test "$(val probe-root "$F")" = absent
    assert "a: original root still present as @.f0-new (U0)" test "$(name_uuid @.f0-new "$F")" = "$U0"
    assert "a: original content intact under @.f0-new" has 'probe-root=root-after-snapshot' "$(g content @.f0-new)"
    invariants a "$F"
    echo "-- a: exchange back, reboot"
    assert "a: exchange back returned 0" has '^renameat2 rc=0$' "$(g exchange)"
    g sync; reboot_wait || abort "a: rebooted after exchanging back"
    F=$(facts) || abort "facts unreadable (booted UUID or @ missing)"; echo "$F" > "$OUT/F0-a-back.txt"
    assert "a: booted the original root again (booted=U0)" test "$(val booted "$F")" = "$U0"
    assert "a: original probe back" test "$(val probe-root "$F")" = root-after-snapshot
    invariants a "$F"
    inst sync; stop_vm ;;
  b|c)
    setup $c; exchange_checks $c
    [ $c = c ] && g sync
    power_cut; echo "power cut ($( [ $c = c ] && echo after syncfs || echo no sync))"
    relaunch_after_cut $c || { shot "F0-$c-noboot"; abort "$c: boots unaided after the power cut"; }
    pass "$c: boots unaided after the power cut"
    F=$(facts) || abort "facts unreadable (booted UUID or @ missing)"; echo "$F" > "$OUT/F0-$c-after.txt"
    B=$(val booted "$F"); AT=$(name_uuid @ "$F"); OTHER=$(name_uuid @.f0-new "$F")
    echo "after cut: booted=$B @=$AT @.f0-new=${OTHER:-<absent>}"
    assert "$c: the booted root is the subvolume named @" test "$B" = "$AT"
    if [ $c = c ]; then
      assert "c: synced exchange survived the cut (booted=Un)" test "$B" = "$Un"
      assert "c: original kept as @.f0-new (U0)" test "$OTHER" = "$U0"
    else
      # Unsynced: either side is correct; what must never happen is a missing @ or a mismatched pair.
      assert "b: @ is U0 or Un, and the other name holds the other one (or the uncommitted copy is absent)" \
        sh -c '{ [ "$1" = "$3" ] && { [ -z "$2" ] || [ "$2" = "$4" ]; }; } || { [ "$1" = "$4" ] && [ "$2" = "$3" ]; }' _ "$AT" "$OTHER" "$U0" "$Un"
      echo "b: observed $( [ "$AT" = "$U0" ] && echo 'exchange NOT committed: original root booted' || echo 'exchange committed: swapped root booted')"
    fi
    invariants $c "$F"
    inst sync; stop_vm ;;
  ref)
    setup ref; g oldrename; g sync
    power_cut; echo "power cut after the old design's first rename + syncfs"
    # GRUB prints to the serial console (console=ttyS0): read it with a deadline; ssh would hang on a dead guest.
    boot ref
    for _ in $(seq 1 60); do grep -q 'grub rescue>' image/vm/serial.log && break; sleep 2; done
    tr -d '\r' < image/vm/serial.log | grep -aE 'error:|rescue' | tee "$OUT/F0-ref-serial.txt"
    shot F0-ref-noboot
    if grep -q 'grub rescue>' image/vm/serial.log; then
      defect "ref: OLD design, @ renamed away + syncfs + power cut: grub rescue>, no boot without manual help (R2 reproduced)"
    else
      fail "ref: expected grub rescue> after the old design's first rename (R2 claim not reproduced)"
    fi
    stop_vm ;;
  esac
done
finish
