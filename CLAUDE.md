# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Trust-boundary rules — read before touching anything

- **Never bypass `torchd`** (once it exists, Phase 2+) to run a privileged operation directly. If a
  task seems to need raw `sudo`/root outside `torchd`'s operation classes, stop and say so — don't
  improvise a workaround.
- **Always snapshot before a mutating privileged action** once Btrfs/Snapper is wired up (Phase 1+):
  `snapper create -d "<what and why>" -u important=yes` before, not after.
- **A "looks safe" repair is not pre-approved.** Verification (service health, boot success, snapshot
  diff) happens with real checks, not by the same agent that made the change declaring it fine.
- **This machine is a server and is off-limits for OS conversion.** All bring-up/testing targets a
  QEMU/KVM VM (~3GB RAM — this host is memory-constrained, see Gotchas). Never touch the host OS.
- **No passwordless sudo on this host.** Any privileged one-time setup step needs the owner to run it
  themselves (suggest `! <command>`) — don't attempt to route around this.

## Status: reboot in progress, Phase 1 in flight

TorchOS v2 is a from-scratch rebuild, approved 2026-08-24. Full rationale for every decision below:
**`docs/superpowers/specs/2026-08-24-torchos-v2-architecture-design.md`** (the locked spec) and its
research appendix in `docs/research/*.md` (7 files — prior-art review of SimpleOS/VibeOS/FableOS/
Antigravity/EasyOS + a 2026 landscape survey, base-distro/Hyprland/Intel-iGPU validation, snapshot &
dotfiles tooling, compatibility & privilege-broker precedents, Claude Code integration shape).

v1 (the old AI-research-lab/Btrfs-labs distro) lives at **`legacy/v1/`** — retained as reference, not a
foundation. See `legacy/v1/README.md` for what was kept vs. discarded and why.

## Locked decisions (do not re-litigate without a new spec)

| Area | Decision | Fallback if it doesn't work out |
|---|---|---|
| Base distro | **CachyOS** (Arch family) | EndeavourOS, then openSUSE Tumbleweed |
| Desktop | **Hyprland**, forking Omarchy's architecture (not branding) | — |
| GPU driver | **i915** default, Xe opt-in (Lunar Lake/Battlemage-class hw only) | — |
| Recovery | **Snapper + snap-pac + grub-btrfs + Btrfs Assistant** (fallback triggered — see Gotchas) | — |
| Dotfiles/rice | **chezmoi** (mandatory diff-before-apply) | — |
| Compatibility | `torch install`: pacman → Flatpak → gated AUR → Distrobox → AppImage → Wine/Bottles/Proton/Lutris | — |
| Privilege broker | **`torchd`**: polkit-actions-shaped daemon over a Unix socket (SO_PEERCRED-verified), wraps systemd D-Bus + PackageKit, hand-builds only `snapshot.rollback` | — |
| AI integration | **Claude Agent SDK** (long-lived daemon) + custom MCP server over `torchd`; auth via Claude Code subscription's Agent-SDK credit, not console API billing | — |
| Installer | Fork CachyOS's `cachyos-calamares` + an Omarchy-style provisioner layer | — |
| Branding | Keep v1's `assets/logo.png` + orange/ember palette as-is for now (owner decision, 2026-08-24) | Revisit once the OS itself works |

Priority order, always: **Convenience > Compatibility > Reliability > Recoverability > Security > Elegance > Novelty.**

## Status checklist

- [x] Architecture design written, self-reviewed, approved
- [x] v1 migrated to `legacy/v1/`
- [x] Phase 1: VM provisioned (QEMU/KVM via system qemu, virtio-blk/virtio-net/virtio-gpu, 2GB RAM —
      see Gotchas for why 2GB not 3GB, and for the RAM headroom story on this specific host)
- [x] Phase 1: CachyOS installed in VM (manual pacstrap, not archinstall — see Gotchas), boots reliably
      via GRUB from the persistent disk, SSH-accessible sudo user (`torch`/`torchos2026` — throwaway
      local-only VM credentials, fine to leave as-is)
- [x] Phase 1: Btrfs snapshot + rollback verified inside VM — Snapper installed, `.snapshots` subvolume
      created correctly (nested under `@`, see Gotchas), a labeled checkpoint→change→`snapper status`
      diff cycle ran end-to-end and correctly showed the change. grub-btrfs boot-menu integration and
      Btrfs Assistant GUI not yet installed (CLI recovery path is proven; boot-menu path is not yet).
- [x] Phase 1: Hyprland desktop packages installed and provisioned (Hyprland, hypridle, hyprlock,
      hyprpaper, waybar, wofi, kitty, xdg-desktop-portal-hyprland, polkit-gnome, pipewire stack),
      tty1 auto-login + auto-start configured, process confirmed running (`ps` shows `Hyprland` +
      `waybar` alive, real `hyprctl monitors` output, correct seat0 session via `loginctl`). **Visual
      verification blocked** by a QEMU/host permission gap, not a Hyprland problem — see Gotchas
      (`/dev/udmabuf` needs one more one-time sudo command). Omarchy's actual Quickshell-based shell
      not yet forked in — this is a plain Hyprland+waybar baseline, polish/Omarchy-parity is follow-up.
- [x] Phase 1: `torch` CLI skeleton scaffolded — real Rust binary at `torch/` (clap-based), not a stub:
      `status`, `doctor`, `gpu`, `snapshot list/create`, `diagnose` (structured JSON). Every command
      shells out directly (snapper/systemctl/lspci/uname) as a deliberate Phase 1 stopgap — see the
      note at the top of `torch/src/main.rs` — to become a `torchd` client in Phase 2. Built and run
      successfully both on this dev host (correctly reports it's *not* a TorchOS box) and natively
      inside the VM (`doctor` fully green, `snapshot create` produced a real verified checkpoint).
- [x] Phase 1: basic structured diagnostics wired up — `torch diagnose` emits JSON (kernel, hostname,
      root fstype, GPU, failed systemd units, available memory), validated as parseable JSON and
      cross-checked for correct values on both the dev host and the VM.
- [x] Phase 1: grub-btrfs installed + boot-menu snapshot entries verified — `grub-mkconfig` genuinely
      found and added all 6 real snapshots from this session's actual pacman transactions,
      `grub-btrfsd` watcher enabled+active for future ones (auto-refreshes the menu on new snapshots,
      no manual `grub-mkconfig` re-run needed going forward)
- [ ] Phase 1: Hyprland visually verified (blocked on the `/dev/udmabuf` permission gap — needs
      `sudo usermod -aG kvm $USER` + fresh session, see Gotchas)
- [ ] Phase 1 implementation plan formally written (`writing-plans`) — went straight to execution
      instead, per the `/goal` directive; worth writing retroactively if this needs to be resumed
      by a fresh session
- [ ] Phase 2: `torchd` + polkit action set
- [ ] Phase 3: AI assistant (Agent SDK + MCP) wired to `torchd`
- [ ] Phase 4: `torch install` compatibility resolver
- [ ] Phase 5: Calamares installer fork
- [ ] Phase 6: real Intel-iGPU hardware validation

## Gotchas

Categorized per subsystem, per the VibeOS research recommendation (a flat list gets unwieldy fast).

### qemu-vm
- **QEMU usermode networking (`-netdev user`) advertises a non-functional IPv6 default route**
  (`fe80::/64` via router advertisement shows up in `ip -6 route` and looks real) — DNS resolves AAAA
  records fine, but outbound IPv6 connections just hang/silently fail. If a mirror's DNS returns
  IPv6-only or IPv6-preferred (e.g. `mirror.cachyos.org` did), pacman/curl will stall for a long time
  before falling back, if it falls back at all. Fix: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` (and
  `.default.disable_ipv6=1`) in the guest before doing any network-heavy work.
- **Always `sync` (and ideally clean `umount`) inside the guest before sending `quit` to the QEMU
  monitor.** Writes sitting in the guest's own page cache are lost on an abrupt `quit` — the qcow2
  file itself is fine, but anything the guest hadn't flushed yet silently vanishes on next boot. This
  cost two full lost config files (a `limine.conf`, then a `grub.cfg`) before the pattern was caught.
- **QEMU monitor `sendkey` silently drops any character with no explicit key-name mapping** — it
  doesn't error, the keystroke just never happens, producing confusing partial/garbled typed commands
  (e.g. `.` dropped turns `sshd_config.d` into `sshd_configd`). Full mapping needed for scripted typing:
  space→`spc`, `-`→`minus`, `_`→`shift-minus`, `.`→`dot`, `/`→`slash`, `>`→`shift-dot`, `(`→`shift-9`,
  `)`→`shift-0`, `=`→`equal`, `:`→`shift-semicolon`, `'`→`apostrophe`, `%`→`shift-5`, uppercase→
  `shift-<lowercase>`. Prefer driving the guest over SSH once it's reachable — far less error-prone
  than character-by-character `sendkey`.
- **VT switches and shell-prompt readiness are timing-sensitive over the monitor.** A `ctrl-alt-f2`
  sent before that VT's getty is ready lands on a blank screen (needs a retry + an `Enter`); text typed
  before a shell prompt has actually rendered gets buffered and shows up as garbled leftover input once
  the prompt does appear — usually self-recovers on the next real prompt, but don't trust the first
  screendump after a boot/login as ground truth without one more check.
- Host RAM is genuinely tight even with nothing VM-related running (this is a shared dev/desktop
  machine, not dedicated) — 2GB for the VM is the realistic ceiling, not the earlier-assumed 3GB.

### gpu / hyprland-in-vm
- **Hyprland runs but fails to actually render** in this VM (`ps` shows it alive, but `hyprctl monitors`
  detects both virtual outputs correctly, `screendump`/VNC show solid black, and `grim` — an in-session
  screenshot tool — hangs indefinitely rather than producing a file). The guest's `hyprland.log` fills
  with a repeating `CRIT from aquamarine: [EGL] Command eglCreateImageKHR errored out with
  EGL_BAD_ALLOC: createImageFromDmaBufs failed`. This is aquamarine's DRM/KMS buffer-sharing layer, not
  Mesa's GL dispatch — `LIBGL_ALWAYS_SOFTWARE=1` and `cursor { no_hardware_cursors = true }` both had
  no effect, confirming that.
- **Root cause, actually diagnosed (not guessed)**: `dmesg` on the guest shows
  `[drm] features: +virgl +edid -resource_blob -host_visible` — the virtio-gpu device is missing the
  `resource_blob`/blob-resource feature DMA-BUF sharing depends on. Fixing this means launching QEMU
  with `-device virtio-gpu-gl-pci,blob=true,hostmem=256M` (plus a `memory-backend-memfd` object) instead
  of plain `virtio-gpu-pci`.
- **That fix needs one more thing this host can't self-grant**: `blob=true` requires the QEMU process to
  open `/dev/udmabuf`, which is `crw-rw---- root:kvm` with **no ACL** (unlike `/dev/kvm`, which already
  has one granting direct access — see Environment notes). The owning session's user isn't in the `kvm`
  group, so this fails with a clean `Permission denied` — genuinely blocked on a one-time sudo action,
  not something to keep working around. **Exact unlock, when the owner is available to run it**:
  `sudo usermod -aG kvm $USER` (then a fresh login/new session — group changes don't apply retroactively
  to an already-open session, same as the original `/dev/kvm` ACL lesson). Once granted, relaunch with
  `-object memory-backend-memfd,id=mem1,size=2048M -machine memory-backend=mem1 -device
  virtio-gpu-gl-pci,blob=true,hostmem=256M -display egl-headless` and re-verify with `grim` from inside
  the session (`export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1; grim
  /tmp/shot.png`) rather than QEMU's own `screendump`, which does not reflect the `egl-headless` render
  path reliably even when rendering itself is healthy.
- Current VM launch therefore reverted to plain `-device virtio-gpu-pci` (no `-gl`, no `egl-headless`)
  — boots and runs Hyprland as a real process, just not visually verifiable until the `kvm`-group unlock
  above happens. Not a regression from the working boot state established earlier in this doc; a
  separate, later layer on top of it.
- **This is a real, currently-open upstream issue, not just a local misconfiguration** — confirmed via
  [hyprwm/aquamarine#109](https://github.com/hyprwm/aquamarine/issues/109), same exact symptom (black
  screen, no errors, Hyprland 0.45+/aquamarine 5.0+ specifically inside a QEMU VM). The only reported
  workaround there is downgrading to aquamarine 0.4.3 + Hyprland 0.45.0 — many major versions behind
  what CachyOS currently ships (0.56.2/0.14.0 here), and reported as a personal workaround pending an
  upstream fix, not a confirmed universal one. **Deliberately not attempted**: a downgrade that deep
  risks dependency conflicts across the whole freshly-installed Hyprland ecosystem (waybar, portal,
  wayland libs all built against current versions) for an unconfirmed payoff — the `kvm`-group +
  `blob=true` path above is the lower-risk, higher-confidence fix and should be tried first.

### bootloader
- **Limine 12.6.0 `bios-install` fails against this exact QEMU+virtio-blk combination** — throws
  repeated `device_cache_block(): set_pos(): Invalid argument` and produces a boot sector that hangs
  silently at "Booting from Hard Disk..." forever, *despite* printing "Limine BIOS stages installed
  successfully" at the end. Reproduced identically both inside an arch-chroot and running directly
  against `/dev/vda` from the live environment — not a chroot-indirection issue. Root cause not fully
  diagnosed. **Switched to GRUB** (`grub-install --target=i386-pc`), which installed and booted cleanly
  on the identical disk — this is the documented interchangeable fallback, now actually exercised.
- **GRUB with a separate `/boot` partition can embed a prefix that fails to auto-find `grub.cfg`**,
  dropping to a `grub>` rescue prompt instead of the menu on boot, even though `grub-mkconfig` ran
  clean and the file is genuinely present and correct (`configfile (hd0,msdos1)/grub/grub.cfg` loads
  it manually with no error). In this specific case the *actual* cause turned out to be the sync-before-quit
  issue above (the freshly-written `grub.cfg` was never flushed to disk before the next reboot) — once
  a clean `umount -R /mnt; sync; sync` preceded the `quit`, a plain `grub-install` + `grub-mkconfig`
  redo booted straight to the menu with no prefix workaround needed. Worth remembering as a possible
  explanation before assuming a "real" GRUB prefix bug next time this happens.

### install
- **`archinstall --silent` can hang forever inside the live ISO** polling
  `archlinux-keyring-wkd-sync.timer`'s `ActiveEnterTimestamp` via systemd D-Bus (waiting for it to
  become non-empty) as part of its keyring-readiness gate — that timer never fires in a live-boot
  context, so the wait never ends. `pacman -S <pkgs>` on the live system itself works fine in the same
  session, proving the keyring is actually usable — this is archinstall's own extra gate, not a real
  keyring problem. Worked around by killing archinstall after disk partitioning succeeded and finishing
  the install manually (`pacstrap` + `arch-chroot` + `genfstab`), which is what actually landed the
  working system.
- `archinstall`'s `network_config.type` must be one of `iso` / `nm` / `nm_iwd` / `iwd` / `manual` —
  **not** `NetworkManager` (fails validation instantly, easy to fix, but worth not re-guessing).
- `archinstall`'s user-credentials JSON schema (verified from actual source,
  `archinstall/lib/models/users.py`): `{"users": [{"username": ..., "!password": "<plaintext>" (or
  "enc_password": "<hash>"), "sudo": bool, "groups": [...]}]}`. No separate top-level root-password
  field in the model — root login stays disabled by default unless a sudo user is created instead.

### accounts / ssh
- A single big **nested-heredoc chroot script run over SSH** (outer `arch-chroot ... <<CHROOT_EOF`
  containing an inner `<<LIMINECFG` for a config file) silently corrupted partway through — `useradd`
  + `chpasswd` for the `torch` user, the sudoers wheel-uncomment, the `systemctl enable` calls, and the
  limine.conf write *looked* like they all ran (no visible errors in the captured output at the time)
  but several didn't actually take effect: the account ended up **locked** (`passwd -S` showed `L`,
  and `passwd -u` refused to unlock a "passwordless" account), sudoers was never actually updated, and
  services weren't enabled. Redoing the exact same commands **individually** (not nested in one big
  heredoc) worked cleanly every time. Lesson: for anything that matters, prefer several small,
  independently-verified commands over one large nested-heredoc script, and verify state
  (`passwd -S user`, `systemctl is-enabled`, `visudo -c`) rather than trusting a script's own "no error
  shown" as proof it worked.
- **Arch's OpenSSH ships `PasswordAuthentication` commented out** in `/etc/ssh/sshd_config` (defaults
  to effectively no interactive password login). Also note `Include /etc/ssh/sshd_config.d/*.conf`
  runs near the *top* of the main config — since sshd uses first-match-wins per directive, anything set
  in a drop-in there beats a directive appended at the *end* of the main file. The Arch-shipped drop-in
  (`99-archlinux.conf`) does *not* itself set `PasswordAuthentication` (only
  `KbdInteractiveAuthentication no`, `UsePAM yes`, `PrintMotd no`), so appending
  `PasswordAuthentication yes` to the end of the main file is sufficient here — but check for drop-ins
  before assuming an appended override will actually win.
- `useradd -m` did not reliably leave a populated, correctly-owned home directory in this session
  (possibly entangled with the nested-heredoc issue above, and with fixing it *before* the real
  target subvolume was mounted — see the Btrfs note below). Verify with `ls -la /home/<user>` after
  the fact, don't assume `-m` was sufficient.

### btrfs / snapper
- **A mounted subvolume's mountpoint directory looks identical to a real subvolume from the outside**,
  but once *unmounted* it reverts to being just an empty regular directory at that path — the actual
  subvolume lives elsewhere in the filesystem's subvolume tree. `btrfs subvolume delete <path>` on it
  while unmounted fails with `Not a Btrfs subvolume: Invalid argument`. To actually delete it: mount the
  top-level volume elsewhere (`mount -o subvolid=5 /dev/vdaX /mnt/topvol`) and delete it from there
  (`btrfs subvolume delete /mnt/topvol/<name>`).
- **`snapper -c root create-config /` refuses to run if *anything* already exists at `.snapshots`**,
  even an empty leftover directory with no subvolume backing it — not just an existing subvolume. Fully
  `rmdir` the path first (after confirming nothing real is mounted there), then retry.
- Snapper's `create-config` creates `.snapshots` as a subvolume **nested inside the target subvolume**
  (`top level 256 path .snapshots`, i.e. `@/.snapshots`), not as a top-level sibling of `@`/`@home`/etc.
  the way this repo's own archinstall config had pre-created it. The correct fstab `subvol=` reference
  is therefore `/@/.snapshots`, not `/@snapshots` — these are genuinely different subvolumes with
  different paths, easy to conflate.
- Fixing a user's home-directory contents (or anything else under a subvolume mountpoint) **before**
  that subvolume is actually mounted writes into whatever's underneath at that path instead (usually
  the parent subvolume's own empty placeholder directory) — the fix silently "disappears" the moment
  the real subvolume gets mounted there later. Always confirm `findmnt <path>` shows the expected
  `subvol=` before writing anything meant to persist on that subvolume.
- `sed -i` against a small file over a fragile remote-typed session is risky — a single bad
  pattern/delimiter mismatch wiped this repo's guest `/etc/fstab` down to its header comments in one
  shot. Prefer rewriting the whole file via heredoc (or `cat > file` with the full intended content)
  over trying to surgically edit one line with `sed` when the stakes are "the system won't boot/mount
  correctly if this is wrong."

## Session record

No dedicated session-log files yet — git commit history is the decision record at this stage (each
commit states what changed and why). Revisit if/when commit messages stop being sufficient for context
continuity across sessions; don't build a logging system ahead of needing one.

## Environment notes (this dev/test machine)

Linux Mint 22.2, apt-based. Bare metal (not nested virtualization), Intel VT-x present, `/dev/kvm`
exists with an ACL granting the owner direct rw access (no `kvm` group membership needed). No
passwordless sudo — the owner installed `qemu-system-x86`/`qemu-utils`/`virt-manager`/`libvirtd`
themselves at some point via a real terminal (not the `!`-relay, which can't supply a sudo password).
7.4GB RAM total, genuinely shared with normal desktop use (VS Code, browser, Cinnamon) — budget VM
RAM at ~2GB, not the 3GB originally planned or v1's old 8GB default.

The Phase 1 VM lives at `image/vm/torchos-vm.qcow2` (40GB sparse, gitignored) with the CachyOS ISO
alongside it. Launch command (adjust `-cdrom`/`-boot order=d` only when re-installing from scratch;
normal boots use `-boot order=c` with no `-cdrom`):

```
qemu-system-x86_64 -name torchos-vm -enable-kvm -cpu host -m 2048 -smp 2 \
  -drive file=image/vm/torchos-vm.qcow2,if=virtio,format=qcow2 -boot order=c \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \
  -device virtio-gpu-pci -vnc :1 \
  -serial telnet:127.0.0.1:4555,server,nowait \
  -monitor unix:image/vm/monitor.sock,server,nowait
```

SSH: `ssh -p 2222 torch@localhost` (password `torchos2026` — throwaway, local-NAT-only VM, no need to
harden). `sudo` works for `torch`. Screenshot the VM anytime via the monitor socket's `screendump`
command (writes a `.ppm`; `convert file.ppm file.png` to view with the Read tool) — this is the
actual way to verify GUI/desktop state later, not just serial/SSH text.
