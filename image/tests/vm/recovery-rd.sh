#!/usr/bin/env bash
# R-D fault-injection cases (docs/decisions/0003-recovery-integrity.md R5, §7 F6/F6b/F7): torchd's safe grub.cfg
# regeneration and its startup repair of the boot menus. Each case runs on a fresh qcow2 overlay of
# image/vm/A-installed.qcow2; this tree's torchd (fault-injection build) is copied over /usr/bin/torchd on the overlay
# only. The development-only `torchd grub-regenerate` runs the same code kernel.install runs, without a network
# kernel install. Power cut = QEMU `quit`. Cases (RD_CASES): G0 F6 F6v F6i F6b-validated F6b-prev F6b-renamed F7 F7b.
# The reproductions on the old code are image/tests/vm/grub-rd-repro.sh.
source "$(dirname "$0")/lib.sh"
BASE="A-installed.qcow2"; BVARS=image/vm/A-installed.vars
[ -f "image/vm/$BASE" ] && [ -f "$BVARS" ] || { echo "run supported.sh first (image/vm/$BASE, $BVARS)" >&2; exit 2; }
CASES=${RD_CASES:-G0 F6 F6v F6i F6b-validated F6b-prev F6b-renamed F7 F7b}
BIN=image/build/rd; mkdir -p "$BIN"
CFG=/boot/grub/grub.cfg; BT=/boot/grub/grub-btrfs.cfg

if [ -n "${RD_TORCHD_FI:-}" ]; then  # a fault-injection torchd already built from this tree (e.g. when the mirror is down)
  install -m755 "$RD_TORCHD_FI" "$BIN/torchd-fi"
else
echo "== building torchd from this tree (fault-injection) ($(ts))"
docker run --rm -v "$PWD/torch:/src:ro" -v "$PWD/$BIN:/out" -e HOST_UID="$(id -u):$(id -g)" archlinux:base-devel bash -euc '
  pacman -Sy --noconfirm --needed rust >/dev/null 2>&1; cp -a /src /tmp/s; cd /tmp/s
  cargo build -q --release --locked -p torchd --features fault-injection && cp target/release/torchd /out/torchd-fi
  chown "$HOST_UID" /out/torchd-fi' || { echo "torchd build failed" >&2; exit 2; }
fi
grep -qaF TORCHD-FAULT-INJECTION-BUILD "$BIN/torchd-fi" || { echo "$BIN/torchd-fi is not a fault-injection build" >&2; exit 2; }

power_cut() { monitor quit; for _ in $(seq 1 30); do vm_alive || break; sleep 1; done; wait "$VM_PID" 2>/dev/null; VM_PID=; }
boot() { qemu_run uefi "image/vm/rd-$1.vars" - "image/vm/rd-$1.qcow2"; wait_ssh inst "${2:-40}"; }
r() { isudo "bash -c '$*'"; }   # root shell on the guest; the command must not contain '
md5() { r "md5sum $1 2>/dev/null | cut -c1-32"; }
setup() {
  overlay "$BASE" "rd-$1.qcow2"; cp "$BVARS" "image/vm/rd-$1.vars"
  boot "$1" || abort "$1: overlay reachable"
  inst 'cat > /tmp/torchd.new' < "$BIN/torchd-fi"
  r "install -m755 /tmp/torchd.new /usr/bin/torchd && systemctl restart torchd && sleep 2 && systemctl is-active -q torchd" ||
    abort "$1: this tree's torchd running"
  r "sync"; OLD=$(md5 $CFG); [ -n "$OLD" ] || abort "$1: grub.cfg readable"
}
regen() { r "torchd grub-regenerate 2>&1; echo rc=\$?"; }
# A configuration that differs from the installed one, so old and new are told apart.
mark() { r "sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=7/\" /etc/default/grub"; }
timeout_of() { r "grep -m1 \"set timeout=\" $CFG" | tr -d ' '; }
boots_after_cut() {  # boots_after_cut <case>: power cut, boot, assert it came up by itself
  power_cut; if boot "$1" 20; then pass "$1: boots unaided after the power cut"; else shot "rd-$1-noboot"; abort "$1: boots unaided"; fi
}
cleanup() { stop_vm; rm -f "image/vm/rd-$1.qcow2" "image/vm/rd-$1.vars"; }

for c in $CASES; do
  echo "== $c ($(ts))"
  case $c in
    G0)  # normal regeneration: accepted (no false rejection), previous kept, durable, boots
      setup $c; mark
      out=$(regen); echo "$out"
      assert "G0: regeneration accepted on the installed system" has 'rc=0' "$out"
      assert "G0: grub.cfg.prev is the configuration it replaced" test "$(md5 $CFG.prev)" = "$OLD"
      assert "G0: the new grub.cfg is installed" test "$(timeout_of)" = "settimeout=7"
      assert "G0: no candidate or temporary left" test -z "$(r "ls /boot/grub | grep torchd")"
      boots_after_cut $c   # no sync before the cut: regenerate committed it
      assert "G0: the new grub.cfg survived the cut" test "$(timeout_of)" = "settimeout=7"
      cleanup $c ;;
    F6)  # a generator script that fails: refused, live byte-identical
      setup $c; r "printf \"#!/bin/sh\nexit 1\n\" > /etc/grub.d/99_rdfail; chmod +x /etc/grub.d/99_rdfail"
      out=$(regen); echo "$out"
      assert "F6: refused" has 'rc=1' "$out"
      assert "F6: says the boot menu is unchanged" has 'boot menu is unchanged' "$out"
      assert "F6: grub.cfg byte-identical" test "$(md5 $CFG)" = "$OLD"
      r "sync"; boots_after_cut $c; cleanup $c ;;
    F6v)  # reproduced H4: a parseable but unbootable default entry is now rejected
      setup $c
      r "printf \"#!/bin/sh\ncat <<X\nmenuentry \\\"TorchOS Linux\\\" {\n  linux /@/boot/vmlinuz-missing root=UUID=00000000-0000-0000-0000-000000000000 rw rootflags=subvol=@\n}\nX\n\" > /etc/grub.d/05_rdbad; chmod +x /etc/grub.d/05_rdbad"
      out=$(regen); echo "$out"
      assert "F6v: refused" has 'rc=1' "$out"
      assert "F6v: names the missing kernel" has 'vmlinuz-missing is not a file' "$out"
      assert "F6v: grub.cfg byte-identical" test "$(md5 $CFG)" = "$OLD"
      assert "F6v: rejected candidate kept for inspection" r "test -s /boot/grub/grub.cfg.torchd-rejected"
      r "sync"; boots_after_cut $c; cleanup $c ;;
    F6i)  # reproduced H5: the default kernel's initramfs is missing
      setup $c; r "mv /boot/initramfs-linux.img /root/"
      out=$(regen); echo "$out"
      assert "F6i: refused" has 'rc=1' "$out"
      assert "F6i: says the default entry has no initrd" has "'TorchOS Linux': has no initrd" "$out"
      assert "F6i: grub.cfg byte-identical" test "$(md5 $CFG)" = "$OLD"
      r "mv /root/initramfs-linux.img /boot/; sync"; boots_after_cut $c; cleanup $c ;;
    F6b-*)  # power cut at each point of the replacement, after a full commit (the worst case for that point)
      p=${c#F6b-}; setup $c; mark
      r "echo after:grub-$p > /run/torchd/fault"
      r "nohup torchd grub-regenerate > /tmp/rg.out 2>&1 < /dev/null &"   # the redirects stay inside: sudo needs its stdin
      for _ in $(seq 1 60); do inst 'test -e /run/torchd/fault-paused' && break; sleep 2; done
      assert "$c: paused at after:grub-$p" inst "grep -q 'PAUSED after:grub-$p' /run/torchd/fault-paused"
      r "sync"; boots_after_cut $c
      t=$(timeout_of); echo "after: $t prev=$(md5 $CFG.prev)"
      assert "$c: grub.cfg is the old or the new one, never empty or partial" test "$t" = "settimeout=5" -o "$t" = "settimeout=7"
      assert "$c: grub.cfg parses" r "grub-script-check $CFG"
      [ "$p" = renamed ] && assert "$c: after the rename the new one is live" test "$t" = "settimeout=7"
      [ "$p" = validated ] && assert "$c: before the rename the old one is live" test "$(md5 $CFG)" = "$OLD"
      out=$(regen); assert "$c: a later regeneration cleans up and succeeds" has 'rc=0' "$out"
      assert "$c: no candidate or temporary left" test -z "$(r "ls /boot/grub | grep torchd")"
      cleanup $c ;;
    F7)  # reproduced H3: power cut while grub-btrfs regenerates the snapshot menu; torchd restores it at startup
      setup $c
      r "/etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 & p=\$!; for i in \$(seq 200); do [ -e $BT.bkp ] && break; sleep 0.01; done; kill -STOP \$p; sync"
      assert "F7: the live snapshot menu was moved away by grub-btrfs" r "test ! -e $BT -a -e $BT.bkp"
      boots_after_cut $c; sleep 5
      assert "F7: torchd regenerated the snapshot menu at startup" has 'regenerated /boot/grub/grub-btrfs.cfg' \
        "$(r "journalctl -u torchd -b --no-pager -o cat")"
      assert "F7: the menu lists a snapshot" r "grep -q @snapshots/[0-9]*/snapshot $BT"
      assert "F7: the menu parses" r "grub-script-check $BT"
      assert "F7: no .bkp left" r "test ! -e $BT.bkp"
      cleanup $c ;;
    F7b)  # grub.cfg damaged by something else (a hand-run grub-mkconfig cut short): torchd restores grub.cfg.prev
      setup $c; out=$(regen); assert "F7b: regeneration made grub.cfg.prev" has 'rc=0' "$out"
      good=$(md5 $CFG); r ": > $CFG; systemctl restart torchd; sleep 2"
      assert "F7b: torchd restored grub.cfg from grub.cfg.prev" test "$(md5 $CFG)" = "$good"
      assert "F7b: and logged it" has 'restored it from /boot/grub/grub.cfg.prev' "$(r "journalctl -u torchd -b --no-pager -o cat")"
      boots_after_cut $c; cleanup $c ;;
  esac
done
finish
