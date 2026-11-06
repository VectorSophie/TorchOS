#!/usr/bin/bash
# One installer-step scenario, run INSIDE a disposable container (image/tests/run.sh starts one per
# scenario; never run this on a real system: it writes to /etc, /boot and /usr/lib/modules).
# The real torch-target-setup / torch-target-verify run against a fake target; the tools that would touch
# disks, the bootloader or systemd (findmnt, lsblk, mount, btrfs, snapper, pacman, mkinitcpio, systemctl,
# grub-*, efibootmgr) are stubs that log their calls and fail on demand.
#   install-steps-scenario.sh <scenario>
set -u
SCEN=${1:?scenario}
SRC=${SRC:-/src}
SETUP=$SRC/image/calamares/usr/lib/torchos/torch-target-setup
VERIFY=$SRC/image/calamares/usr/lib/torchos/torch-target-verify
ST=/stubstate; mkdir -p $ST /stubs; : > $ST/calls; : > $ST/fail
FPR=FD561EDBA8080AA625A935E075870B90E4C34AC8

# ---- stubs ----------------------------------------------------------------------------------------
cat > /stubs/_stub <<'STUB'
#!/usr/bin/bash
name=$(basename "$0"); ST=/stubstate
echo "$name $*" >> $ST/calls
while IFS= read -r f; do [ -n "$f" ] && case "$name $*" in "$f"*) exit 1 ;; esac; done < $ST/fail
build_images() {   # what mkinitcpio would produce for every preset
  [ -n "${T_MKINIT_NOOP:-}" ] && return 0
  for p in /etc/mkinitcpio.d/*.preset; do
    b=$(basename "$p" .preset)
    for img in /boot/initramfs-$b.img /boot/initramfs-$b-fallback.img; do
      if [ -n "${T_BAD_HOOKS:-}" ]; then printf 'hooks/\nhooks/udev\n' > $img
      else printf 'hooks/\nhooks/grub-btrfs-overlayfs\nhooks/udev\ninit\n' > $img; fi
    done
  done
}
case "$name $*" in
  "findmnt -no FSTYPE /sys/firmware/efi/efivars") [ -n "${T_BIOS:-}" ] && exit 1; echo efivarfs ;;
  "findmnt -no FSTYPE /") echo "${T_ROOTFS:-btrfs}" ;;
  "findmnt -no OPTIONS /") echo "rw,noatime,compress=zstd:1,subvolid=256,subvol=${T_SUBVOL:-/@}" ;;
  "findmnt -no SOURCE /") echo "/dev/vda2[/@]" ;;
  "findmnt -no FSTYPE /boot/efi") echo vfat ;;
  "findmnt -no SOURCE /.snapshots") echo "/dev/vda2[/@snapshots]" ;;
  "findmnt -no SOURCE /target") echo "/dev/vda2[/@]" ;;
  "findmnt -no UUID /target") echo 2f6b1c1e-0d5a-4c3e-9a51-7f0e8d1b2c3a ;;
  "lsblk -nso TYPE /dev/vda2") [ -n "${T_CRYPT:-}" ] && echo crypt; echo part; echo disk ;;
  "lsblk -nso PKNAME /dev/vda2") echo vda; echo ;;
  "lsblk -dno PTTYPE /dev/vda") echo "${T_PTTYPE:-gpt}" ;;
  "btrfs subvolume delete /.snapshots") rmdir /.snapshots ;;
  "snapper --no-dbus -c root create-config /") mkdir /.snapshots ;;
  "snapper --no-dbus -c root create -d "*) echo "$6" >> $ST/snapshots ;;
  "snapper --no-dbus -c root list") cat $ST/snapshots 2>/dev/null ;;
  "pacman -Rns "*) [ -n "${T_NO_HOOK:-}" ] || build_images ;;
  "mkinitcpio -P") build_images ;;
  "lsinitcpio "*) cat "$1" ;;
  "systemctl enable "*) touch "$ST/enabled.$2" ;;
  "systemctl is-enabled --quiet "*) test -e "$ST/enabled.$3" ;;
  "efibootmgr "*) [ -n "${T_NO_NVRAM:-}" ] || echo "Boot0008* TorchOS" ;;
  *) : ;;   # everything else (pacman -Q, pacman-key, mount, umount, mountpoint, grub-*) succeeds
esac
STUB
chmod +x /stubs/_stub
for c in findmnt lsblk mountpoint mount umount btrfs snapper pacman pacman-key mkinitcpio lsinitcpio \
         systemctl greetd tuigreet start-hyprland Hyprland grub-script-check grub-fstest efibootmgr; do
  ln -sf _stub /stubs/$c
done
export PATH=/stubs:$PATH
fail_on() { echo "$1" >> $ST/fail; }

# ---- a fake freshly unpacked target ---------------------------------------------------------------
mkdir -p /usr/lib/modules/7.2.7-arch1-1 /usr/lib/modules/6.18.54-1-lts /etc/mkinitcpio.d /etc/mkinitcpio.conf.d \
         /boot/grub /boot/efi/EFI/TorchOS /boot/efi/EFI/boot /usr/lib/initcpio/hooks /usr/share/pacman/keyrings \
         /etc/sudoers.d /etc/systemd/system/getty@tty1.service.d /.snapshots /etc/ssh /var/tmp /var/log
echo linux > /usr/lib/modules/7.2.7-arch1-1/pkgbase
echo linux-lts > /usr/lib/modules/6.18.54-1-lts/pkgbase
head -c 200000 /dev/urandom > /usr/lib/modules/7.2.7-arch1-1/vmlinuz
head -c 200000 /dev/urandom > /usr/lib/modules/6.18.54-1-lts/vmlinuz
mkdir -p /usr/lib/modules/extramodules-x                       # no pkgbase: must be skipped
touch /usr/lib/initcpio/hooks/grub-btrfs-overlayfs
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-torch-live
echo '[Service]' > /etc/systemd/system/getty@tty1.service.d/autologin.conf
echo 'HOOKS=(base archiso)' > /etc/mkinitcpio.conf.d/archiso.conf
echo "$FPR:4:" > /usr/share/pacman/keyrings/torchos-trusted
echo 'UUID=x /.snapshots btrfs subvol=/@snapshots,defaults,noatime 0 0' >> /etc/fstab
printf 'hooks/\nhooks/archiso\n' > /boot/initramfs-linux.img    # stale live-ISO image in the copied rootfs
touch -d 2020-01-01 /boot/initramfs-linux.img
useradd -m liveuser
useradd -r -s /usr/bin/nologin greeter
useradd -m -s /bin/bash tester && echo "tester:$(head -c 18 /dev/urandom | base64)" | chpasswd   # random per run: only needs to be a usable password

# ---- verify-step fixture (a mounted target at /target as seen from the live system) -----------------
verify_fixture() {
  mkdir -p /target/boot/grub /target/boot/efi/EFI/TorchOS /target/boot/efi/EFI/boot /target/etc/mkinitcpio.d /target/var/log
  printf "menuentry 'TorchOS Linux' {\n\tlinux\t/@/boot/vmlinuz-linux root=UUID=${T_GRUB_ROOT_UUID:-2f6b1c1e-0d5a-4c3e-9a51-7f0e8d1b2c3a} rw rootflags=subvol=@ loglevel=3\n}\nsubmenu 'TorchOS snapshots' { configfile \"\${prefix}/grub-btrfs.cfg\" }\n" > /target/boot/grub/grub.cfg
  echo "submenu '| 2026-11-02 | @snapshots/1/snapshot | single | TorchOS fresh install |' {}" > /target/boot/grub/grub-btrfs.cfg
  echo x > /target/boot/efi/EFI/TorchOS/grubx64.efi; echo x > /target/boot/efi/EFI/boot/bootx64.efi
  touch /target/etc/mkinitcpio.d/linux.preset /target/etc/mkinitcpio.d/linux-lts.preset
  # torch-target-verify checks that the root device is a block device; give it one.
  mknod /dev/vda2 b 7 200 2>/dev/null || true
}

# ---- run + assertions -------------------------------------------------------------------------------
fails=0
ok()   { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*"; fails=1; }
expect_exit() { [ "$RC" -eq "$1" ] && ok "exit $1" || bad "exit $RC, expected $1"; }
# Step records are "<class>\t<name>\t<result>"; names contain regex characters, so match exact lines.
has_line() { grep -qxF "$(printf '%s\t%s\t%s' "$2" "$3" "$4")" "$1"; }
step_is() { has_line /var/log/torchos-install-steps.tsv "$1" "$2" "$3" && ok "$1 $2 = $3" || bad "$1 $2 is not $3: $(grep -F "$2" /var/log/torchos-install-steps.tsv)"; }
called() { [ "$(grep -c -- "^$1" $ST/calls)" -eq "$2" ] && ok "'$1' called $2x" || bad "'$1' called $(grep -c -- "^$1" $ST/calls)x, expected $2"; }
no_step_after() { ! grep -qF "$(printf '\t%s\t' "$1")" /var/log/torchos-install-steps.tsv && ok "no '$1' step ran" || bad "'$1' ran after a required failure"; }
# The scripts log through `exec > >(tee ...)`; give tee a moment to drain before reading its output.
setup() { bash "$SETUP" > /tmp/out 2>&1; RC=$?; sleep 0.5; }
verify() { verify_fixture; : > /target/var/log/torchos-install-steps.tsv; bash "$VERIFY" /target > /tmp/out 2>&1; RC=$?; sleep 0.5; }
vstep() { has_line /target/var/log/torchos-install-steps.tsv "$1" "verify: $2" "$3" && ok "verify $2 = $3" || bad "verify '$2' is not $3"; }
live_untouched() { [ -e /etc/sudoers.d/99-torch-live ] && getent passwd liveuser >/dev/null && ok "live session not modified" || bad "target was modified before the layout check failed"; }

echo "== $SCEN"
case $SCEN in
  supported)
    setup; expect_exit 0
    ! grep -q FAILED /var/log/torchos-install-steps.tsv && ok "no failed step" || bad "a step failed"
    for s in target-layout remove-live-session kernel-images initramfs-config initramfs package-trust login core-services snapshots; do
      step_is required $s ok; done
    called "mkinitcpio" 0          # the pacman hook built the initramfs: no duplicate build
    [ ! -e /etc/sudoers.d/99-torch-live ] && ! getent passwd liveuser >/dev/null && ok "live session removed" || bad "live session left behind"
    cmp -s /usr/lib/modules/7.2.7-arch1-1/vmlinuz /boot/vmlinuz-linux && ok "kernel copied" || bad "kernel not copied"
    grep -q '^\[torchos\]' /etc/pacman.conf && ok "[torchos] repo configured" || bad "[torchos] missing"
    grep -q 'TorchOS fresh install' $ST/snapshots && ok "fresh-install snapshot" || bad "no snapshot"
    [ -e $ST/enabled.greetd.service ] && [ -e $ST/enabled.grub-btrfsd.service ] && ok "greetd + grub-btrfsd enabled" || bad "units not enabled"
    ;;
  bios)      export T_BIOS=1 ; setup; expect_exit 1; step_is required target-layout FAILED; live_untouched; no_step_after remove-live-session ;;
  ext4-root) export T_ROOTFS=ext4; setup; expect_exit 1; step_is required target-layout FAILED; live_untouched ;;
  wrong-subvolume) export T_SUBVOL=/ ; setup; expect_exit 1; step_is required target-layout FAILED; live_untouched ;;
  encrypted-root) export T_CRYPT=1 ; setup; expect_exit 1; step_is required target-layout FAILED; live_untouched ;;
  mbr-table) export T_PTTYPE=dos ; setup; expect_exit 1; step_is required target-layout FAILED; live_untouched ;;
  kernel-missing)
    rm /usr/lib/modules/6.18.54-1-lts/vmlinuz; setup; expect_exit 1; step_is required kernel-images FAILED; no_step_after initramfs ;;
  initramfs-hook-missed)    # installer removal failed, so the pacman hook never built the images
    fail_on "pacman -Rns"; setup; expect_exit 0
    step_is optional remove-installer-packages failed; called "mkinitcpio -P" 1; step_is required initramfs ok ;;
  initramfs-hook-noop)      # removal "succeeded" but built nothing: the stale live image must not pass
    export T_NO_HOOK=1 T_MKINIT_NOOP=1 ; setup; expect_exit 1; step_is required initramfs FAILED; no_step_after package-trust ;;
  initramfs-build-fails)
    fail_on "pacman -Rns"; fail_on "mkinitcpio -P"; setup; expect_exit 1; step_is required initramfs FAILED; no_step_after login ;;
  initramfs-without-overlay-hook)
    export T_BAD_HOOKS=1 ; setup; expect_exit 1; step_is required initramfs FAILED ;;
  keyring-populate-fails)
    fail_on "pacman-key --populate torchos"; setup; expect_exit 1; step_is required package-trust FAILED; no_step_after login ;;
  signing-key-missing)
    fail_on "pacman-key --list-keys $FPR"; setup; expect_exit 1; step_is required package-trust FAILED ;;
  greetd-enable-fails)
    fail_on "systemctl enable greetd.service"; setup; expect_exit 1; step_is required login FAILED; no_step_after snapshots ;;
  no-login-account)
    passwd -l tester >/dev/null; setup; expect_exit 1; step_is required login FAILED ;;
  torchd-enable-fails)
    fail_on "systemctl enable torchd.service"; setup; expect_exit 1; step_is required core-services FAILED ;;
  snapper-config-fails)
    fail_on "snapper --no-dbus -c root create-config"; setup; expect_exit 1; step_is required snapshots FAILED ;;
  first-snapshot-fails)
    fail_on "snapper --no-dbus -c root create -d"; setup; expect_exit 1; step_is required snapshots FAILED ;;
  optional-service-fails)
    fail_on "systemctl enable bluetooth.service"; setup; expect_exit 0
    step_is optional "enable bluetooth.service" failed; step_is required snapshots ok
    grep -q "WARN: optional step 'enable bluetooth.service' failed" /tmp/out && ok "warning printed" || bad "no warning" ;;
  verify-ok)
    verify; expect_exit 0; vstep required "grub.cfg parses (grub-script-check)" ok
    vstep required "default entry mounts this root (root=UUID=2f6b1c1e-0d5a-4c3e-9a51-7f0e8d1b2c3a rootflags=subvol=@)" ok
    vstep optional "firmware boot entry for TorchOS" ok ;;
  verify-grub-reads-short-kernel)   # the rsync -S sparse-tail bug: GRUB reads less than the file
    fail_on "grub-fstest /dev/vda2 cmp /@/boot/vmlinuz-linux "; verify; expect_exit 1
    vstep required "GRUB reads /boot/vmlinuz-linux completely" FAILED ;;
  verify-wrong-root)   # a kernel line that names another file system must not pass as "boots from @"
    export T_GRUB_ROOT_UUID=0b8e3f9a-1111-4222-8333-944455556666; verify; expect_exit 1
    vstep required "grub.cfg boots the linux kernel from @" ok
    vstep required "default entry mounts this root (root=UUID=2f6b1c1e-0d5a-4c3e-9a51-7f0e8d1b2c3a rootflags=subvol=@)" FAILED ;;
  verify-grub-cfg-invalid)
    fail_on "grub-script-check"; verify; expect_exit 1; vstep required "grub.cfg parses (grub-script-check)" FAILED ;;
  verify-no-fallback-loader)
    verify_fixture; rm /target/boot/efi/EFI/boot/bootx64.efi; : > /target/var/log/torchos-install-steps.tsv
    bash "$VERIFY" /target > /tmp/out 2>&1; RC=$?; expect_exit 1; vstep required "removable-media fallback EFI/boot/bootx64.efi" FAILED ;;
  verify-no-snapshot-menu)
    verify_fixture; : > /target/boot/grub/grub-btrfs.cfg; : > /target/var/log/torchos-install-steps.tsv
    bash "$VERIFY" /target > /tmp/out 2>&1; RC=$?; expect_exit 1; vstep required "snapshot menu lists a snapshot" FAILED ;;
  verify-no-nvram-entry)   # optional: the removable-media path still boots
    export T_NO_NVRAM=1 ; verify; expect_exit 0; vstep optional "firmware boot entry for TorchOS" failed ;;
  *) echo "unknown scenario $SCEN"; exit 2 ;;
esac
if [ "$fails" -ne 0 ]; then echo "--- output"; tail -40 /tmp/out; echo "--- steps"; cat /var/log/torchos-install-steps.tsv 2>/dev/null; fi
exit $fails
