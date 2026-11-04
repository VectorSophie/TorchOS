#!/usr/bin/env bash
# A. Supported path: blank UEFI disk -> Calamares erase install -> boot the disk alone -> login, step record,
#    doctor, signed repo, Snapper, GRUB recovery entries, both kernels + fallback initramfs, checkpoint and
#    rollback across a reboot, boot-chain verification cost. Leaves image/vm/A-installed.qcow2 for the other scenarios.
# Every result is an assertion (lib.sh); the scenario passes only if all of them do.
source "$(dirname "$0")/lib.sh"
[ -f "${ISO:-}" ] || { echo "no ISO in image/out" >&2; exit 2; }
KEYFPR=$(cut -d: -f1 pkg/torchos/keyring/torchos-trusted)   # the key the ISO's torchos-keyring trusts
echo "== A1 install from $ISO ($(ts)), repo key $KEYFPR"; mem
start_iso; wait_ssh live 60 || abort "live session reachable over SSH"; wait_calamares || abort "Calamares window mapped"
assert "live session booted in UEFI mode" live 'test -d /sys/firmware/efi'
assert "target disk is blank (no signatures)" test "$(live 'sudo wipefs -n /dev/vda | wc -l')" = 0
T0=$(date +%s); install_via_ui 3600; rc=$?; T_INSTALL=$(( $(date +%s) - T0 ))
echo "install rc=$rc after $T_INSTALL s"; shot A1-install-finished; mem
assert "Calamares reported success (drive_install rc=$rc)" test "$rc" = 0
LOG=$(session_log A1)
echo "--- values the real torchpreflight job saw"; grep -E 'torchpreflight' <<<"$LOG"
assert "gate saw /sys/firmware/efi" has "torchpreflight: /sys/firmware/efi=True" "$LOG"
assert "gate saw firmwareType 'efi'" has "firmwareType='efi'" "$LOG"
assert "gate saw install choice 'erase'" has "'install': 'erase'" "$LOG"
assert "gate saw swap choice 'none'" has "'swap': 'none'" "$LOG"
assert "gate saw defaultFileSystemType 'btrfs'" has "defaultFileSystemType='btrfs'" "$LOG"
assert "gate saw no encryption" has "encryption=no" "$LOG"
assert "gate accepted the configuration" has "torchpreflight: supported configuration" "$LOG"
echo "--- jobs, in order"; started_jobs "$LOG"
assert "the gate is the first job" sh -c 'printf "%s\n" "$1" | head -1 | grep -qF "$2"' _ "$(started_jobs "$LOG")" "$PREFLIGHT_JOB"
assert "no job was skipped" lacks 'Skipping non-emergency job' "$LOG"
live 'sync'; stop_vm

echo "== A2 boot the installed disk without the ISO ($(ts))"
start_disk; wait_ssh inst 60 || abort "installed system reachable over SSH"
assert "booted without the live ISO (no archiso on the kernel command line)" inst '! grep -q archiso /proc/cmdline'
assert "root is btrfs subvolume /@" inst 'findmnt -no FSTYPE,OPTIONS / | grep -Eq "^btrfs .*subvol=/@(,|$)"'
assert "booted kernel is the default 'linux' package" test "$(inst 'cat /usr/lib/modules/$(uname -r)/pkgbase')" = linux
INITRD_DEFAULT=$(isudo 'dmesg' | sed -nE 's/.*Freeing initrd memory: ([0-9]+)K.*/\1/p' | head -1)
FALLBACK_SIZE=$(inst 'stat -c %s /boot/initramfs-linux-fallback.img')
echo "default boot: initrd ${INITRD_DEFAULT}K; fallback image $FALLBACK_SIZE bytes"
sleep 15; shot A2-greeter
assert "greetd is active" inst 'systemctl is-active --quiet greetd'
assert "tuigreet is the greeter on screen" inst 'pgrep -x tuigreet >/dev/null'
echo "--- greetd/tuigreet login on tty1 with the keyboard (VNC)"
python3 image/scripts/dev/vnc.py type "${TORCH_TEST_USER:-tester}"; python3 image/scripts/dev/vnc.py press Return; sleep 2
python3 image/scripts/dev/vnc.py type "$PW"; python3 image/scripts/dev/vnc.py press Return; sleep 25; shot A2-after-login
SESS=$(inst 'for s in $(loginctl list-sessions --no-legend | awk -v u="$(id -un)" "\$3==u{print \$1}"); do loginctl show-session "$s" -p Service -p Type -p TTY -p Remote | tr "\n" " "; echo; done')
echo "$SESS"
assert "a local greetd wayland session on tty1 exists for the test user" \
  sh -c 'printf "%s\n" "$1" | grep -E "Service=greetd" | grep -E "Type=wayland" | grep -E "TTY=tty1" | grep -q "Remote=no"' _ "$SESS"
assert "Hyprland runs as the test user" inst 'pgrep -u "$(id -u)" -x Hyprland >/dev/null'
inst 'pgrep -u "$(id -u)" -x waybar >/dev/null' ||
  defect "D1 installed desktop: TorchOS Hyprland config not in effect (no waybar; $(inst 'ls ~/.config/hypr/hyprland.lua 2>/dev/null || echo "no hyprland.lua"'))"
echo "--- install step record"
STEPS=$(inst 'cat /var/log/torchos-install-steps.tsv'); printf '%s\n' "$STEPS" | tee "$OUT/A2-install-steps.tsv"
for s in target-layout remove-live-session kernel-images initramfs-config initramfs package-trust login core-services snapshots; do
  assert "required step $s ok" has "^required	$s	ok$" "$STEPS"
done
assert "no required step or verify check FAILED" lacks "^required	.*	FAILED$" "$STEPS"
assert "boot-chain verify checks were recorded (>= 8 ok)" test "$(grep -c '^required	verify: .*	ok$' <<<"$STEPS")" -ge 8
assert "install log ends the boot-chain check with 'boot chain verified'" inst 'grep -qx "boot chain verified" /var/log/torchos-install.log'
inst 'pacman -Q grub torch-cli calamares torch-installer-config 2>&1 | grep -v ^warning; findmnt -no SOURCE,FSTYPE,OPTIONS /; findmnt -no SOURCE /.snapshots; ls /boot'
DOC=$(inst 'torch doctor; echo "rc=$?"'); echo "$DOC" | tee "$OUT/A2-doctor.txt"
assert "torch doctor exits 0" has '^rc=0$' "$DOC"

echo "--- repository trust"
assert "[torchos] configured in pacman.conf" inst 'grep -q "^\[torchos\]" /etc/pacman.conf'
assert "pacman keyring holds the ISO's repo key $KEYFPR" isudo "pacman-key --list-keys $KEYFPR"
# Local repo = image/repo (signed by sign-repo.sh), served on host loopback; 10.0.2.2 is the host as seen from QEMU
# user networking. "bad" is the same repo with torch-cli's signature replaced by another package's.
R=$OUT/repos; rm -rf "$R"; mkdir -p "$R"; cp -a image/repo "$R/good"; cp -a image/repo "$R/bad"
cp "$R"/bad/wlogout-*.pkg.tar.zst.sig "$(ls "$R"/bad/torch-cli-*.pkg.tar.zst).sig"
python3 -m http.server --bind 127.0.0.1 --directory "$R" 8088 >/dev/null 2>&1 & HTTP=$!
trap 'kill $HTTP 2>/dev/null; stop_vm' EXIT
repo_try() {  # repo_try <subdir>: sync [torchos] from it into a scratch db and download torch-cli (verifies sigs)
  isudo "sh -c 'rm -rf /tmp/pdb /tmp/pc; mkdir -p /tmp/pdb /tmp/pc; sed \"/^\[torchos\]/,/^Server/ s|^Server.*|Server = http://10.0.2.2:8088/$1|\" /etc/pacman.conf > /tmp/pc.conf; pacman --config /tmp/pc.conf --dbpath /tmp/pdb --cachedir /tmp/pc -Sy && pacman --config /tmp/pc.conf --dbpath /tmp/pdb --cachedir /tmp/pc -Sw --noconfirm torchos/torch-cli; echo rc=\$?'" 2>&1
}
GOOD=$(repo_try good); echo "$GOOD" | tail -5
assert "local test repo: signed db + package accepted" has '^rc=0$' "$GOOD"
BAD=$(repo_try bad); echo "$BAD" | tail -5
assert "local test repo: package with a wrong signature is refused" \
  sh -c 'printf "%s\n" "$1" | grep -q "^rc=1$" && printf "%s\n" "$1" | grep -qiE "signature|PGP"' _ "$BAD"
HOSTED=$(isudo "sh -c 'rm -rf /tmp/hdb; mkdir -p /tmp/hdb; pacman --dbpath /tmp/hdb -Sy; echo rc=\$?'" 2>&1); echo "$HOSTED" | tail -6
if [ "$KEYFPR" = FD561EDBA8080AA625A935E075870B90E4C34AC8 ]; then
  assert "hosted [torchos] repo verifies with the production key" has '^rc=0$' "$HOSTED"
else
  # Test-key build: the hosted repo is signed by the production key, which this system does not trust.
  assert "hosted [torchos] (production key) is refused by this test-key build, not silently accepted" \
    sh -c 'printf "%s\n" "$1" | grep -q "^rc=1$" && printf "%s\n" "$1" | grep -iE "torchos" | grep -qiE "signature|PGP|trust|unknown"' _ "$HOSTED"
fi
kill $HTTP 2>/dev/null

echo "--- snapper and GRUB recovery entries"
SNAP=$(inst 'snapper -c root list; snapper -c root get-config'); echo "$SNAP" | grep -E 'fresh|NUMBER_LIMIT|TIMELINE_CREATE|ALLOW_GROUPS'
assert "snapper root config has the fresh-install snapshot" has 'TorchOS fresh install' "$SNAP"
assert "/.snapshots is the separate @snapshots subvolume" inst 'findmnt -no SOURCE /.snapshots | grep -qF "[/@snapshots]"'
GRUB=$(isudo 'cat /boot/grub/grub.cfg'); GBTRFS=$(isudo 'cat /boot/grub/grub-btrfs.cfg')
grep -nE "^menuentry|^submenu|^[[:space:]]+menuentry" <<<"$GRUB" | head -12
assert "grub.cfg loads the snapshot menu" has 'grub-btrfs\.cfg' "$GRUB"
assert "snapshot menu has a submenu with a snapshot entry" \
  sh -c 'printf "%s\n" "$1" | grep -q "^submenu" && printf "%s\n" "$1" | grep -q "@snapshots/[0-9]*/snapshot"' _ "$GBTRFS"
isudo 'efibootmgr' | tee "$OUT/A2-efibootmgr.txt"

echo "== A3 linux-lts and the linux fallback initramfs via grub-reboot ($(ts))"
for e in "Advanced options for TorchOS Linux>TorchOS Linux, with Linux linux-lts" \
         "Advanced options for TorchOS Linux>TorchOS Linux, with Linux linux (fallback initramfs)"; do
  title=${e#*>}
  assert "grub.cfg has entry '$title'" grep -qF "menuentry '$title'" <<<"$GRUB"
  isudo "grub-reboot '$e'" || fail "grub-reboot '$e'"
  reboot_wait || abort "rebooted into '$title'"
  base=$(inst 'cat /usr/lib/modules/$(uname -r)/pkgbase'); initrd=$(isudo 'dmesg' | sed -nE 's/.*Freeing initrd memory: ([0-9]+)K.*/\1/p' | head -1)
  echo "selected: $title -> kernel $(inst 'uname -r') ($base), initrd ${initrd}K, $(inst 'systemctl is-system-running')"
  case $title in
    *linux-lts) assert "'$title' booted the linux-lts kernel" test "$base" = linux-lts ;;
    *fallback*)
      assert "'$title' booted the linux kernel" test "$base" = linux
      # The kernel frees exactly the initrd GRUB loaded: at least the fallback image (plus any microcode image).
      assert "'$title' loaded the fallback initramfs (initrd ${initrd}K >= image $((FALLBACK_SIZE / 1024))K)" \
        test "$((initrd * 1024))" -ge "$FALLBACK_SIZE"
      assert "the default boot did not (initrd ${INITRD_DEFAULT}K < fallback)" test "$((INITRD_DEFAULT * 1024))" -lt "$FALLBACK_SIZE" ;;
  esac
  DOC=$(inst 'torch doctor >/dev/null; echo "rc=$?"'); assert "'$title': torch doctor exits 0" has '^rc=0$' "$DOC"
  # GRUB cannot write grubenv on btrfs, so it never clears next_entry itself: clear it from Linux.
  isudo 'grub-editenv /boot/grub/grubenv unset next_entry'
done

echo "== A4 checkpoint + change + rollback across a reboot ($(ts))"
reboot_wait || abort "rebooted into the default entry"
assert "default entry boots 'linux' again" test "$(inst 'cat /usr/lib/modules/$(uname -r)/pkgbase')" = linux
ROOT_BEFORE=$(isudo 'btrfs subvolume show /' | awk '$1 == "UUID:" {print $2}')
assert "torch snapshot create" inst 'torch snapshot create "install-correctness verification: checkpoint"'
N=$(inst 'snapper -c root list' | grep "install-correctness verification: checkpoint" | tail -1 | cut -d"|" -f1 | tr -d " *-")
echo "checkpoint number: $N"; assert "checkpoint is listed with a number" test -n "$N"
TOKEN=home-$RANDOM-$RANDOM
isudo "sh -c 'echo changed > /etc/torch-rollback-probe'"; inst "echo $TOKEN > ~/home-probe"
RB=$(inst "printf 'y\n' | torch snapshot rollback $N; echo rc=\$?"); echo "$RB"
assert "torch snapshot rollback $N exits 0" has '^rc=0$' "$RB"
reboot_wait || abort "rebooted after rollback"
ROOT_AFTER=$(isudo 'btrfs subvolume show /' | awk '$1 == "UUID:" {print $2}')
echo "root subvolume UUID before $ROOT_BEFORE, after $ROOT_AFTER"
assert "system change reverted (/etc/torch-rollback-probe gone)" inst 'test ! -e /etc/torch-rollback-probe'
assert "/home kept (~/home-probe = $TOKEN)" test "$(inst 'cat ~/home-probe')" = "$TOKEN"
assert "the booted root is a different subvolume than before the rollback" \
  sh -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]' _ "$ROOT_BEFORE" "$ROOT_AFTER"
SNAP=$(inst 'snapper -c root list')
assert "snapshots survived (fresh install + checkpoint $N listed)" \
  sh -c 'printf "%s\n" "$1" | grep -q "TorchOS fresh install" && printf "%s\n" "$1" | grep -q "install-correctness verification: checkpoint"' _ "$SNAP"
assert "still on the 'linux' kernel" test "$(inst 'cat /usr/lib/modules/$(uname -r)/pkgbase')" = linux
DOC=$(inst 'torch doctor; echo "rc=$?"'); echo "$DOC" > "$OUT/A4-doctor.txt"
assert "torch doctor exits 0 after rollback" has '^rc=0$' "$DOC"

echo "== A5 boot-chain verification cost on the installed system ($(ts))"
# Note: appends "verify:" lines to the installed system's install log and step record.
inst 'cat > /tmp/torch-target-verify && chmod +x /tmp/torch-target-verify' < image/calamares/usr/lib/torchos/torch-target-verify
inst "du -cb /boot/initramfs-* /boot/vmlinuz-* | tail -1"
for c in cold warm; do
  drop=; [ $c = cold ] && drop='sync; echo 3 > /proc/sys/vm/drop_caches;'
  V=$(isudo "sh -c '$drop systemd-run --wait --pipe -p IOAccounting=yes -p MemoryAccounting=yes /tmp/torch-target-verify / 2>&1'" 2>&1)
  echo "--- $c cache"; grep -E 'CHECK FAILED|boot chain|runtime|CPU time|Memory peak|IO bytes' <<<"$V"
  assert "$c run: boot chain verified, no failed check" sh -c 'printf "%s\n" "$1" | grep -qx "boot chain verified" && ! printf "%s\n" "$1" | grep -q "CHECK FAILED"' _ "$V"
done
inst 'sync'; stop_vm
mv "$BLANK" image/vm/A-installed.qcow2 && echo "kept image/vm/A-installed.qcow2 for the other scenarios"
echo "install took $T_INSTALL s"
finish
