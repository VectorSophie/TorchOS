#!/usr/bin/env bash
# R-D reproductions on the CURRENT code (docs/decisions/0003-recovery-integrity.md R5): what the shipped grub-mkconfig
# (grub 2.16) and grub-btrfs (4.14) do to the live boot configuration when interrupted or fed a bad generator.
# Each case runs on a fresh qcow2 overlay of supported.sh's image/vm/A-installed.qcow2; power cut = QEMU `quit`.
# When the overlay no longer boots, GRUB's view of the files is read offline with grub-fstest from a raw copy.
# Cases (RD_CASES): H1a H1b H1c H1d H2 H3 H4 H5.
source "$(dirname "$0")/lib.sh"
BASE="A-installed.qcow2"; BVARS=image/vm/A-installed.vars
[ -f "image/vm/$BASE" ] && [ -f "$BVARS" ] || { echo "run supported.sh first" >&2; exit 2; }
CASES=${RD_CASES:-H1a H1b H1c H1d H2 H3 H4 H5}
CFG=/boot/grub/grub.cfg; BT=/boot/grub/grub-btrfs.cfg

power_cut() { monitor quit; for _ in $(seq 1 30); do vm_alive || break; sleep 1; done; wait "$VM_PID" 2>/dev/null; VM_PID=; }
setup() { overlay "$BASE" "rd-$1.qcow2"; cp "$BVARS" "image/vm/rd-$1.vars"; boot "$1" || abort "$1: no ssh"; }
boot() { qemu_run uefi "image/vm/rd-$1.vars" - "image/vm/rd-$1.qcow2"; wait_ssh inst "${2:-40}"; }
cleanup() { stop_vm 2>/dev/null; rm -f "image/vm/rd-$1.qcow2" "image/vm/rd-$1.vars" "image/vm/rd-$1.raw"; }
r() { isudo "bash -c '$*'"; }   # root shell on the guest; the command must not contain '
# What GRUB itself reads from the disk (offline, raw copy of the overlay): grub-fstest cat <path>
gread() {
  [ -f "image/vm/rd-$1.raw" ] || qemu-img convert -O raw "image/vm/rd-$1.qcow2" "image/vm/rd-$1.raw"
  grub-fstest "image/vm/rd-$1.raw" cat "(loop0,gpt2)$2" 2>&1
}
# Console text after a failed boot: the serial log of the last qemu_run (GRUB mirrors to serial? not on TorchOS),
# so take a VNC screenshot instead.
mark_cfg() { r "sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$1/\" /etc/default/grub"; }

for c in $CASES; do
  echo "== $c ($(ts))"
  case $c in
    H1a)  # real grub-mkconfig, then power cut with no transaction commit in between
      setup $c; mark_cfg 7; r "sync"; old=$(r "md5sum $CFG | cut -c1-32")
      r "grub-mkconfig -o $CFG >/dev/null 2>&1; echo rc=\$?; md5sum $CFG; stat -c size=%s $CFG"
      power_cut
      out=$(gread $c /@/boot/grub/grub.cfg); echo "after cut: GRUB reads $(wc -c <<<"$out") bytes; timeout line: $(grep -m1 'set timeout=' <<<"$out")"
      if boot $c 20; then echo "H1a: boots; md5 $(r "md5sum $CFG | cut -c1-32") (old $old)"; else echo "H1a: does NOT boot"; shot rd-$c; fi
      cleanup $c ;;
    H1b)  # real grub-mkconfig, then an unrelated metadata commit (creating a subvolume elsewhere), then power cut
      setup $c; mark_cfg 7; r "sync"
      r "grub-mkconfig -o $CFG >/dev/null 2>&1; btrfs subvolume create /.snapshots/rdprobe >/dev/null; echo committed"
      power_cut
      out=$(gread $c /@/boot/grub/grub.cfg); echo "after cut: GRUB reads $(wc -c <<<"$out") bytes; timeout line: $(grep -m1 'set timeout=' <<<"$out")"
      gread $c /@snapshots/rdprobe >/dev/null 2>&1; echo "probe subvolume committed: $(grub-fstest image/vm/rd-$c.raw ls '(loop0,gpt2)/@snapshots/' 2>&1 | grep -o rdprobe)"
      if boot $c 20; then echo "H1b: boots"; else echo "H1b: does NOT boot"; shot rd-$c; fi
      cleanup $c ;;
    H1c)  # real grub-mkconfig, then 35 s idle (one periodic commit), then power cut
      setup $c; mark_cfg 7; r "sync"; r "grub-mkconfig -o $CFG >/dev/null 2>&1; echo done"; sleep 35; power_cut
      out=$(gread $c /@/boot/grub/grub.cfg); echo "after cut: GRUB reads $(wc -c <<<"$out") bytes; timeout line: $(grep -m1 'set timeout=' <<<"$out")"
      cleanup $c ;;
    H1d)  # the state grub-mkconfig's `cat new > grub.cfg` passes through (truncated, before the write), committed
      setup $c; r "exec 3>$CFG; sync; stat -c size=%s $CFG"; power_cut
      echo "after cut: GRUB reads $(gread $c /@/boot/grub/grub.cfg | wc -c) bytes"
      if boot $c 20; then echo "H1d: boots"; else echo "H1d: does NOT boot (expected: GRUB prompt)"; shot rd-$c; fi
      cleanup $c ;;
    H2)  # failed candidate generation: a grub.d script that fails, one that emits a syntax error
      setup $c; r "sync"; old=$(r "md5sum $CFG | cut -c1-32")
      r "printf \"#!/bin/sh\nexit 1\n\" > /etc/grub.d/99_rdfail; chmod +x /etc/grub.d/99_rdfail"
      r "grub-mkconfig -o $CFG >/dev/null 2>&1; echo exit-script rc=\$?; md5sum $CFG | cut -c1-32; ls /boot/grub | grep -c new"
      r "printf \"#!/bin/sh\necho if true\n\" > /etc/grub.d/99_rdfail"
      r "grub-mkconfig -o $CFG >/dev/null 2>&1; echo syntax rc=\$?; md5sum $CFG | cut -c1-32; ls /boot/grub/"
      echo "live grub.cfg before: $old"
      cleanup $c ;;
    H3)  # power cut while grub-btrfs regenerates the snapshot menu (paused after it moved the live file away)
      setup $c; r "sync"
      r "time /etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1" 2>&1 | grep real
      r "/etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 & p=\$!; for i in \$(seq 200); do [ -e $BT.bkp ] && break; sleep 0.01; done; kill -STOP \$p; ls /boot/grub; sync; echo paused"
      power_cut
      echo "GRUB sees grub-btrfs.cfg: $(gread $c /@/boot/grub/grub-btrfs.cfg | head -c 60 | tr '\n' ' ')"
      echo "grub.cfg guard: $(gread $c /@/boot/grub/grub.cfg | grep -A2 'grub-btrfs.cfg" ]' | tr '\n' ' ')"
      if boot $c 20; then
        echo "H3: main entry boots"; sleep 20
        r "ls -la /boot/grub; systemctl is-active grub-btrfsd; journalctl -b -u grub-btrfsd --no-pager | tail -5"
      else echo "H3: does NOT boot"; shot rd-$c; fi
      cleanup $c ;;
    H4)  # a parseable but unbootable configuration: grub-mkconfig accepts and installs it
      setup $c; r "sync"
      r "printf \"#!/bin/sh\ncat <<X\nmenuentry \\\"TorchOS Linux\\\" {\n  linux /@/boot/vmlinuz-missing root=UUID=00000000-0000-0000-0000-000000000000 rw rootflags=subvol=@\n}\nX\n\" > /etc/grub.d/05_rdbad; chmod +x /etc/grub.d/05_rdbad; cat /etc/grub.d/05_rdbad"
      r "grub-mkconfig -o $CFG >/dev/null 2>&1; echo rc=\$?; grub-script-check $CFG && echo script-check-passes; grep -n -m2 menuentry $CFG"
      r "sync"; power_cut
      if boot $c 20; then echo "H4: boots (default entry not the bad one?)"; else echo "H4: does NOT boot"; shot rd-$c; fi
      cleanup $c ;;
    H5)  # the default kernel's initramfs is missing (e.g. a failed mkinitcpio hook): grub-mkconfig emits an entry
         # without initrd, script-check passes, and the default entry cannot mount the root
      setup $c; r "sync"
      r "mv /boot/initramfs-linux.img /root/; grub-mkconfig -o $CFG >/dev/null 2>&1; echo rc=\$?; grub-script-check $CFG && echo script-check-passes; sed -n \"/^menuentry .TorchOS Linux/,/^}/p\" $CFG | grep -E \"linux|initrd\""
      r "sync"; power_cut
      if boot $c 20; then echo "H5: boots"; else echo "H5: default entry does NOT boot"; shot rd-$c; fi
      cleanup $c ;;
  esac
done
