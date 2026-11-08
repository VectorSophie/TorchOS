#!/usr/bin/env bash
# R-A fault-injection cases (docs/decisions/0003-recovery-integrity.md §7): the crash-safe rollback, its journal and
# startup reconciliation, pending-rollback refusal, and rollback to a snapshot that holds a pre-R-A torchd.
# Each case runs on a fresh qcow2 overlay of supported.sh's image/vm/A-installed.qcow2 (+ image/vm/A-installed.vars),
# whose torchd is the pre-R-A one from that ISO. This working tree's torchd is built in a container (release build and
# a fault-injection build) and copied over /usr/bin/torchd on the overlay only; no package or ISO ever carries it.
# Power cut = QEMU monitor `quit` while torchd is paused at a fault point. Cases: F1 F2 F3 F4 F5 F12 F14 F13 F13b
# (RA_CASES to choose).
source "$(dirname "$0")/lib.sh"
BASE="A-installed.qcow2"; BVARS=image/vm/A-installed.vars
[ -f "image/vm/$BASE" ] && [ -f "$BVARS" ] || { echo "run supported.sh first (image/vm/$BASE, $BVARS)" >&2; exit 2; }
CASES=${RA_CASES:-F1 F2 F3 F4 F5 F12 F14 F13 F13b}
BIN=image/build/ra; mkdir -p "$BIN"

echo "== building torchd from this tree (release + fault-injection) ($(ts))"
docker run --rm -v "$PWD/torch:/src:ro" -v "$PWD/$BIN:/out" -e HOST_UID="$(id -u):$(id -g)" archlinux:base-devel bash -euc '
  pacman -Sy --noconfirm --needed rust >/dev/null 2>&1; cp -a /src /tmp/s; cd /tmp/s
  cargo build -q --release --locked -p torchd && cp target/release/torchd /out/torchd
  cargo build -q --release --locked -p torchd --features fault-injection && cp target/release/torchd /out/torchd-fi
  chown "$HOST_UID" /out/torchd /out/torchd-fi' || { echo "torchd build failed" >&2; exit 2; }
assert "release torchd has no fault-injection marker" sh -c '! grep -qaF TORCHD-FAULT-INJECTION-BUILD "$1"' _ "$BIN/torchd"
assert "fault build carries the marker" grep -qaF TORCHD-FAULT-INJECTION-BUILD "$BIN/torchd-fi"

GUEST=$(cat <<'EOF'
set -u
case $1 in
  facts)  # run as root
    echo "booted=$(btrfs subvolume show / 2>/dev/null | awk '$1=="UUID:"{print $2}')"
    btrfs subvolume list -a -u -q /.snapshots | awk '{for(i=1;i<=NF;i++){if($i=="uuid")u=$(i+1); if($i=="path")p=$(i+1)}
      if (p ~ /^<FS_TREE>\/[^\/]+$/) { sub(/^<FS_TREE>\//, "", p); print "name", p, u } }'
    echo "probe-root=$(cat /etc/ra-probe 2>/dev/null || echo absent)"
    echo "probe-log=$(cat /var/log/ra-log-probe 2>/dev/null || echo absent)"
    echo "nested-snapshot=$(test -e /snapshot && echo yes || echo no)"
    echo "snapshots=$(snapper -c root list --columns number | grep -c '^ *[0-9]')"
    echo "torchd-sha=$(sha256sum /usr/bin/torchd | cut -c1-16)"
    echo "results=$(grep -o '"result":"[^"]*"' /var/log/torchd/journal.jsonl 2>/dev/null | cut -d'"' -f4 | tr '\n' ' ')" ;;
  legacy)  # <snapshot>: an old torchd's stale @.rollback-new, as root
    mkdir -p /run/ra && mount -o subvolid=5 "$(findmnt -no SOURCE / | sed 's/\[.*//')" /run/ra &&
      btrfs subvolume snapshot "/.snapshots/$2/snapshot" /run/ra/@.rollback-new >/dev/null && umount /run/ra && echo legacy-made ;;
  journal) cat /var/log/torchd/journal.jsonl 2>/dev/null ;;
  rollback) printf 'y\n' | torch snapshot rollback "$2"; echo "rc=$?" ;;
esac
EOF
)
# The helper is re-sent before every call: /tmp is emptied by each reboot.
g() { inst 'cat > /tmp/rag.sh' <<<"$GUEST"; isudo "bash /tmp/rag.sh $*"; }
val() { sed -nE "s/^$1=(.*)$/\1/p" <<<"$2" | head -1; }
name_uuid() { awk -v n="$1" '$1=="name" && $2==n {print $3}' <<<"$2"; }
names() { awk '$1=="name"{print $2}' <<<"$1" | tr '\n' ' '; }
power_cut() { monitor quit; for _ in $(seq 1 30); do vm_alive || break; sleep 1; done; wait "$VM_PID" 2>/dev/null; VM_PID=; }
boot() { qemu_run uefi "image/vm/ra-$1.vars" - "image/vm/ra-$1.qcow2"; wait_ssh inst 40; }
put_torchd() {  # put_torchd <binary>: replace /usr/bin/torchd on this overlay and restart it
  inst 'cat > /tmp/torchd.new' < "$1"
  isudo 'install -m755 /tmp/torchd.new /usr/bin/torchd' && isudo 'systemctl restart torchd'; sleep 2
  inst 'systemctl is-active --quiet torchd'
}
snap() {  # snap <description>: torch snapshot create, prints the number
  inst "torch snapshot create '$1' >/dev/null" && inst 'snapper -c root list' | grep "$1" | tail -1 | cut -d"|" -f1 | tr -d " *-"
}
# setup <case> [binary|-]: fresh overlay; optional torchd replacement BEFORE the checkpoint (so N has it too);
# checkpoint N; probes written after N (U0 has them, a copy of N does not).
setup() {
  local c=$1 b=${2:--}
  overlay "$BASE" "ra-$c.qcow2"; cp "$BVARS" "image/vm/ra-$c.vars"
  boot "$c" || abort "$c: overlay reachable"
  inst 'cat > /tmp/rag.sh' <<<"$GUEST"
  if [ "$b" != - ]; then put_torchd "$b" || abort "$c: torchd from this tree running"; fi
  N=$(snap "RA base $c"); [ -n "$N" ] || abort "$c: checkpoint created"
  isudo "sh -c 'echo root-after-snapshot > /etc/ra-probe; echo log-$c > /var/log/ra-log-probe; sync'"
  inst "echo home-$c > ~/ra-home-probe; sync"
  F0=$(g facts); echo "$F0" > "$OUT/RA-$c-before.txt"
  U0=$(name_uuid @ "$F0")
  [ -n "$U0" ] && [ -n "$(val booted "$F0")" ] || abort "$c: facts readable (U0 and booted UUID non-empty)"
  assert "$c: booted root is @ before the rollback" test "$(val booted "$F0")" = "$U0"
}
invariants() {  # invariants <case> <facts>
  local c=$1 f=$2 n
  for n in @home @log @snapshots; do
    assert "$c: $n is the same subvolume" test "$(name_uuid $n "$f")" = "$(name_uuid $n "$F0")"
  done
  assert "$c: /home probe intact" test "$(inst 'cat ~/ra-home-probe')" = "home-$c"
  assert "$c: @log probe intact" test "$(val probe-log "$f")" = "log-$c"
  assert "$c: snapper lists every snapshot" test "$(val snapshots "$f")" = "$(val snapshots "$F0")"
  assert "$c: facts non-empty (booted UUID read)" test -n "$(val booted "$f")"
  assert "$c: the booted root is the subvolume named @" test "$(val booted "$f")" = "$(name_uuid @ "$f")"
}
# crash_at <case> <point:mode>: arm the fault, start the rollback, wait for PAUSED, cut the power, boot again.
crash_at() {
  local c=$1
  isudo "sh -c 'echo after:$2 > /run/torchd/fault'"
  inst "nohup bash /tmp/rag.sh rollback $N > /tmp/rb.out 2>&1 < /dev/null &"
  for _ in $(seq 1 60); do inst 'test -e /run/torchd/fault-paused' && break; sleep 2; done
  assert "$c: torchd paused at after:$2" inst 'grep -q "PAUSED after:'"$2"'" /run/torchd/fault-paused'
  power_cut; echo "power cut at after:$2"
  boot "$c" || { shot "RA-$c-noboot"; abort "$c: boots unaided after the power cut"; }
  pass "$c: boots unaided after the power cut"
  inst 'cat > /tmp/rag.sh' <<<"$GUEST"
  F=$(g facts); echo "$F" > "$OUT/RA-$c-after.txt"; g journal > "$OUT/RA-$c-journal.jsonl"
  [ -n "$(val booted "$F")" ] || abort "$c: facts readable after the cut"
  echo "after: booted=$(val booted "$F") names: $(names "$F") results: $(val results "$F")"
}
no_temporaries() { ! grep -qE '^name @\.torchd-.*\.new ' <<<"$1"; }

for c in $CASES; do
  echo "== $c ($(ts))"
  case $c in
  F1)
    setup F1 "$BIN/torchd-fi"; crash_at F1 intent:nosync
    assert "F1: old root booted (U0)" test "$(val booted "$F")" = "$U0"
    assert "F1: probe present (nothing applied)" test "$(val probe-root "$F")" = root-after-snapshot
    assert "F1: journal recovered-not-applied" test "$(val results "$F")" = "recovered-not-applied "
    assert "F1: no temporaries left" no_temporaries "$F"
    invariants F1 "$F"; inst sync; stop_vm ;;
  F2)
    setup F2 "$BIN/torchd-fi"; crash_at F2 created:sync
    assert "F2: old root booted (U0)" test "$(val booted "$F")" = "$U0"
    assert "F2: journal recovered-not-applied" test "$(val results "$F")" = "recovered-not-applied "
    assert "F2: the committed copy was deleted by reconciliation" no_temporaries "$F"
    invariants F2 "$F"; inst sync; stop_vm ;;
  F3)
    setup F3 "$BIN/torchd-fi"; crash_at F3 exchanged:sync
    assert "F3: new root booted (post-snapshot probe absent)" test "$(val probe-root "$F")" = absent
    assert "F3: old root renamed to its keep-name by reconciliation" sh -c 'printf "%s\n" "$1" | grep -qE "^name @\.torchd-.*\.prev $2$"' _ "$F" "$U0"
    assert "F3: no .new left" no_temporaries "$F"
    assert "F3: journal recovered-prepared -> verified" test "$(val results "$F")" = "recovered-prepared verified "
    invariants F3 "$F"; inst sync; stop_vm ;;
  F4)
    setup F4 "$BIN/torchd-fi"; crash_at F4 exchanged:nosync
    if [ "$(val booted "$F")" = "$U0" ]; then
      echo "F4: exchange was not committed before the cut: old root"
      assert "F4: journal recovered-not-applied" test "$(val results "$F")" = "recovered-not-applied "
    else
      echo "F4: exchange was committed before the cut: new root"
      assert "F4: journal recovered-prepared -> verified" test "$(val results "$F")" = "recovered-prepared verified "
    fi
    assert "F4: no .new left" no_temporaries "$F"
    invariants F4 "$F"; inst sync; stop_vm ;;
  F5)
    setup F5 "$BIN/torchd"
    A=$(snap "RA other F5")   # a different snapshot, A, as the stale legacy copy
    assert "F5: stale legacy @.rollback-new made from snapshot $A" has legacy-made "$(g legacy "$A")"
    F0=$(g facts)
    RB=$(inst "bash /tmp/rag.sh rollback $N"); echo "$RB"
    assert "F5: rollback to $N succeeds despite a legacy @.rollback-new" has '^rc=0$' "$RB"
    reboot_wait || abort "F5: rebooted"
    F=$(g facts); echo "$F" > "$OUT/RA-F5-after.txt"
    assert "F5: root is snapshot $N's content, not A's nested in it" test "$(val nested-snapshot "$F")" = no
    assert "F5: legacy @.rollback-new left untouched (uncertain ownership)" sh -c 'printf "%s\n" "$1" | grep -q "^name @.rollback-new "' _ "$F"
    assert "F5: journal prepared -> verified" test "$(val results "$F")" = "prepared verified "
    invariants F5 "$F"; inst sync; stop_vm ;;
  F12|F14)
    setup $c "$BIN/torchd"
    if [ $c = F14 ]; then
      RB=$(inst "bash /tmp/rag.sh rollback $N"); echo "$RB"
      assert "F14: rollback prepared" has 'prepared and committed to disk' "$RB"
      PKG0=$(inst 'pacman -Q | sha256sum'); AT0=$(name_uuid @ "$(g facts)")
      for cmd in 'torch update tree' 'torch remove nano' 'torch update' 'torch kernel add linux-zen' "torch snapshot rollback $N"; do
        R=$(inst "printf 'y\ny\n' | $cmd 2>&1; echo rc=\$?"); echo "$cmd -> $(tail -2 <<<"$R" | tr '\n' ' ')"
        assert "F14: '$cmd' refused while the rollback is pending" has 'rollback is pending' "$R"
      done
      assert "F14: package database unchanged" test "$(inst 'pacman -Q | sha256sum')" = "$PKG0"
      assert "F14: @ unchanged by the refused second rollback" test "$(name_uuid @ "$(g facts)")" = "$AT0"
      assert "F14: snapshot.create still allowed while pending" test -n "$(snap "RA pending F14")"
      F0=$(g facts)   # the extra snapshot is expected from here on
    else
      RB=$(inst "bash /tmp/rag.sh rollback $N"); echo "$RB"
      assert "F12: rollback rc 0, committed" sh -c 'printf "%s\n" "$1" | grep -q "^rc=0$" && printf "%s\n" "$1" | grep -q "committed to disk"' _ "$RB"
    fi
    reboot_wait || abort "$c: rebooted after the rollback"
    F=$(g facts); echo "$F" > "$OUT/RA-$c-after.txt"; g journal > "$OUT/RA-$c-journal.jsonl"
    assert "$c: rollback applied (probe absent)" test "$(val probe-root "$F")" = absent
    assert "$c: previous root kept as @.torchd-*.prev (U0)" sh -c 'printf "%s\n" "$1" | grep -qE "^name @\.torchd-.*\.prev $2$"' _ "$F" "$U0"
    assert "$c: journal prepared -> verified" test "$(val results "$F")" = "prepared verified "
    DOC=$(inst 'torch doctor; echo rc=$?'); echo "$DOC" > "$OUT/RA-$c-doctor.txt"
    assert "$c: torch doctor exits 0" has '^rc=0$' "$DOC"
    invariants $c "$F"; inst sync; stop_vm ;;
  F13|F13b)
    # The checkpoint holds the ISO's pre-R-A torchd; the R-A torchd is installed only after it.
    setup $c -
    OLD=$(val torchd-sha "$F0")
    if [ $c = F13 ]; then
      put_torchd "$BIN/torchd" || abort "F13: R-A torchd running"
      RB=$(inst "bash /tmp/rag.sh rollback $N"); echo "$RB"
      assert "F13: R-A rollback to a pre-R-A snapshot rc 0" has '^rc=0$' "$RB"
      reboot_wait || abort "F13: boots unaided into the old snapshot"
      F=$(g facts)
    else
      put_torchd "$BIN/torchd-fi" || abort "F13b: R-A fault torchd running"
      crash_at F13b exchanged:sync
    fi
    pass "$c: booted unaided into the snapshot"
    assert "$c: the running torchd is the pre-R-A one from the snapshot" test "$(val torchd-sha "$F")" = "$OLD"
    assert "$c: the old torchd serves requests (torch status)" inst 'torch status >/dev/null'
    assert "$c: rollback applied (probe absent)" test "$(val probe-root "$F")" = absent
    invariants $c "$F"
    echo "$c: journal untouched by the old torchd: $(val results "$F")"
    echo "-- $c: install the R-A torchd again: it reconciles the earlier op"
    put_torchd "$BIN/torchd" || abort "$c: R-A torchd back"
    F=$(g facts); g journal > "$OUT/RA-$c-journal.jsonl"; echo "results: $(val results "$F") names: $(names "$F")"
    if [ $c = F13 ]; then
      assert "F13: journal prepared -> verified once a new torchd starts" test "$(val results "$F")" = "prepared verified "
    else
      assert "F13b: journal recovered-prepared -> verified" test "$(val results "$F")" = "recovered-prepared verified "
      assert "F13b: no .new left after reconciliation" no_temporaries "$F"
    fi
    assert "$c: previous root kept (U0)" sh -c 'printf "%s\n" "$1" | grep -qE "^name @\.torchd-.*\.prev $2$"' _ "$F" "$U0"
    inst sync; stop_vm ;;
  esac
done
finish
