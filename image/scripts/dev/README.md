# VM test harness (Linux host, QEMU/KVM only)

Drive and inspect the TorchOS VM without a display. Everything targets the VM started by
`../run-qemu.sh` (VNC :1 = 5901, monitor socket `image/vm/monitor.sock`, SSH forwarded to 2222).
Dev-only: none of this ships in the ISO. Build a dev ISO with `DEV_SSH_PUBKEY=key.pub ../build-iso.sh`
(bakes in sshd + your key + a serial console; never distribute that ISO).

| file | purpose |
|---|---|
| `qmon.py` | QEMU monitor: `sendkey` with a long key hold, `screendump` -> PNG (needs ImageMagick `convert`), `quit` |
| `vnc.py` | minimal RFB client: type text (handles Shift), press keys, click, `shot out.png` (works with any display backend) |
| `vmssh.sh` | run a command over SSH in the live/installed VM (uses `$TORCH_VM_KEY`, default `~/.ssh/torchos_vm`) |
| `drive_install.py` | drive Calamares from Welcome to Install in the live session, then wait for it |

## Hard-won gotchas
- **`grub-reboot` cannot select a grub-btrfs snapshot entry**: those entries only exist once the *TorchOS snapshots*
  submenu has loaded its own config file, so a `submenu>entry` path does not resolve (GRUB falls back silently).
  Drive the menu with keys instead: after `BdsDxe: starting Boot...` appears in `serial.log`, `End` (the snapshots
  submenu is last), `Enter`, arrows, `Enter`; check each step with `vnc.py shot`. `grub-reboot` does work for the
  normal *Advanced options* entries (e.g. `"Advanced options for TorchOS Linux>TorchOS Linux, with Linux linux-cachyos"`).
- **`screendump` fails with `-display gtk,gl=on`** (RENDER=virgl): the monitor writes nothing. Use `vnc.py shot`, or
  `grim` inside a running Hyprland session.
- **WSL2**: processes backgrounded inside a `wsl.exe` call die when it returns; run long jobs in the foreground of one
  call. Don't `pkill -f` a pattern that your own command line contains.
- **QEMU monitor `sendkey` needs a hold time in GRUB/OVMF**: `sendkey ret` (default ~100 ms) is silently
  ignored for Enter/F10/Ctrl-X while arrows and letters work. Use `sendkey ret 600`. This cost a long
  false trail ("GRUB ignores Enter" was really "GRUB errors and returns to the menu").
- **VNC key events do not auto-Shift**: `&`, `|`, `:` and capitals must be sent with Shift held (`vnc.py` does).
- **Pointer events do not move the cursor** (neither monitor `mouse_move` nor VNC absolute); use keyboard
  and `hyprctl dispatch` (over SSH) instead.
- **`screendump` can look frozen** after a kernel hand-off; do not trust it alone. Use the serial log
  (`image/vm/serial.log`, add `console=ttyS0,115200` to the kernel line) or SSH.
- **OVMF NVRAM remembers the installed OS**: to boot the ISO again against an already-installed disk,
  delete `image/vm/OVMF_VARS.fd` first or the disk's GRUB wins.
- **sudo lockout**: a few failed non-tty `sudo` attempts trigger pam_faillock (10 min lockout).
  Feed the password (`sudo -S`) instead of running bare `sudo` over SSH.
