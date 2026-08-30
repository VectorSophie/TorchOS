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
| Branding | v1's palette hexes kept (`#ff4500`/`#ff6a00`/`#2b0a00`), but the mark itself redone 2026-08-26 — see Status checklist and `assets/branding/` | — |

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
- [x] Phase 1: Hyprland visually verified — owner ran `sudo usermod -aG kvm $USER`, `/dev/udmabuf`
      access confirmed, VM relaunched with blob-resource support, real `grim` screenshots captured
      showing a rendered desktop (wallpaper, cursor, waybar with live network/battery/clock). The
      actual working fix differs from the originally-planned one — see Gotchas.
- [ ] Phase 1 implementation plan formally written (`writing-plans`) — went straight to execution
      instead, per the `/goal` directive; worth writing retroactively if this needs to be resumed
      by a fresh session
- [x] Branding refresh (2026-08-26, design-only session, see **HANDOFF** below for what's next):
      new torch mark cropped/recolored from a reference image, then a full asset set built from it —
      badge + reversed badge, circle-only transparent variants, a 16→512px icon-size set, a standalone
      recolorable silhouette (`torch-mark.png`), and dark/light desktop wallpapers. All in
      `assets/branding/`, **not yet committed** — untracked, needs an explicit go-ahead before
      `git add`/`commit` (not done unprompted per this session's git rule).
- [x] Group A (desktop polish: app bundle, Hyprland/waybar/GTK theming, QoL keybinds, first-boot
      status dashboard, chezmoi dotfiles) — spec'd, planned, and executed via
      `subagent-driven-development`, all 6 tasks implemented and reviewed (real per-task reviews
      plus a whole-branch review with a fix pass). Plan: `docs/superpowers/plans/2026-08-27-group-a-desktop-polish.md`.
      Spec: `docs/superpowers/specs/2026-08-26-desktop-polish-design.md`. `dotfiles/` now exists and
      is deployed to the Phase 1 VM via chezmoi; `scripts/install-apps.sh` and
      `scripts/verify_palette.py` are real and verified end-to-end on the VM. Known open items, not
      blocking: (1) `torch`/`torch-welcome` are only on `$PATH` via a hand-made VM symlink, no repo
      step installs them there yet — see the `install` Gotcha below; (2) the branding
      wallpaper's real config (`hyprpaper.conf`) is shipped and correct but doesn't render on this
      VM due to a DRM/GBM permission issue — see the `gpu / hyprland-in-vm` Gotcha.
- [ ] Group B (Mint-style installer partitioning / Calamares fork) — not started, deliberately
      deferred until after Group A per the owner's own sequencing choice. Don't start this without a
      fresh `superpowers:brainstorming` pass — it hasn't had one yet.
- [ ] Phase 2: `torchd` + polkit action set
- [ ] Phase 3: AI assistant (Agent SDK + MCP) wired to `torchd`
- [ ] Phase 4: `torch install` compatibility resolver
- [ ] Phase 5: Calamares installer fork
- [ ] Phase 6: real Intel-iGPU hardware validation

## HANDOFF (2026-08-30): resume here for the next session

Group A (desktop polish) is done — spec'd, planned, executed task-by-task via
`subagent-driven-development` with real per-task review + fix loops, then a whole-branch review with
its own fix pass. See the Status checklist entry above for what shipped and its two known open items
(`torch`/`torch-welcome` not on `$PATH` from a fresh install; hyprpaper's wallpaper doesn't render on
this VM's GPU setup). This section is the handoff for whoever picks up next; delete/replace it once
acted on rather than letting it go stale.

**Immediate housekeeping, still outstanding:**
- `assets/branding/`, `scripts/branding/`, `docs/superpowers/specs/2026-08-26-desktop-polish-design.md`,
  `docs/superpowers/specs/2026-08-26-os-essentials-security-design.md`, and
  `docs/superpowers/plans/` are all still untracked as of this handoff — genuinely governing documents
  (the spec Group A implements, the plan that was executed, the branding assets `dotfiles/` now
  references a copy of) that haven't shipped in any commit yet. Asked the owner whether to commit them
  during the Group A execution session; **still pending an explicit answer as of this handoff** — don't
  commit them without one.

**What's next:**
- Group B (Mint-style installer partitioning / Calamares fork) — not started, deliberately deferred.
  Needs its own fresh `superpowers:brainstorming` pass before any implementation — it hasn't had one.
- A second spec, `docs/superpowers/specs/2026-08-26-os-essentials-security-design.md` (kernel/memory
  tuning, updates policy, firewall, backups, and a substantial `torchd` design grounded in real
  precedent research), was written and self-reviewed in an earlier session but **never got the
  owner's file-level review or a `writing-plans` pass** — still sitting as a spec only. Worth checking
  with the owner whether that's next, before Group B or Phase 2.
- Phase 2 (`torchd` + polkit action set) is the next phase-level item on the roadmap if the owner
  wants to go there directly instead.

## Gotchas

Categorized per subsystem, per the VibeOS research recommendation (a flat list gets unwieldy fast).

### branding
- The generation scripts for the logo/badge/icon set in `assets/branding/` (Python + pycairo +
  Pillow — crop/recolor the source reference, then procedural rays/gradients for the discarded
  wallpaper iterations) live only in that first session's scratchpad, **not in this repo** — gone
  once that session ended, nothing to resume from if those specific assets need regenerating.
  The wallpaper generator specifically *was* committed on the 2026-08-26 follow-up pass, though —
  see `scripts/branding/generate_wallpaper.py` (Pillow only, no pycairo/numpy dependency). Re-run
  it (`python3 scripts/branding/generate_wallpaper.py`) any time `torch-mark.png` changes or the
  ember effect needs retuning; it's deterministic (fixed seed) so a plain re-run reproduces the
  same output byte-for-byte.
- A low-alpha radial gradient built at full 1920×1080 resolution (one pixel loop, `(1-d)**2`
  falloff) visibly quantizes into concentric rings once composited — 8-bit alpha has too few steps
  for how subtle the gradient needs to be. Fix used in `generate_wallpaper.py`: build the gradient
  (and the horizontal shimmer bands) at a fraction of final resolution and upscale with
  `Image.BICUBIC` — the interpolation smooths past the banding, and it's faster too. Worth
  remembering for any future low-contrast procedural gradient in this repo, not just this one.
- A stock vector image the owner initially wanted to use directly (filename pattern matched Freepik's
  asset-ID convention) was **not** used as-is — recreated procedurally instead, since baking an
  unlicensed stock asset into a permanent, publicly-pushed brand identity is a real licensing risk,
  not just a style preference. Worth the same check (filename patterns, reverse-image-search if
  unsure) before directly incorporating any future "use this image" request into shipped branding.

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
- **RESOLVED 2026-08-24**: owner ran `sudo usermod -aG kvm $USER` + fresh session; `/dev/udmabuf`
  confirmed accessible (`cat` gives `Invalid argument`, not `Permission denied` — that's the expected
  result of a plain read on a udmabuf fd, not a failure). But the actually-working launch config turned
  out **different** from the plan above in two ways, both worth remembering:
  - `-device virtio-gpu-gl-pci,help` (and any use of that device on this specific host's QEMU 8.2.2
    Ubuntu package) fails to load: `undefined symbol: qemu_egl_display`. Root cause: this Ubuntu build
    splits GL support across separate modules (`ui-opengl.so` defines the symbol, `ui-egl-headless.so`
    and `hw-display-virtio-gpu-gl.so` both need it) with no dependency-driven load order — a `,help`
    query hits this every time, but a real launch can still work if `-display egl-headless` happens to
    load `ui-opengl.so` first. Separately, even when the module *did* load, `virtio-gpu-gl-pci` defaults
    virgl on, and `blob=true` + virgl is currently rejected outright: `blobs and virgl are not
    compatible (yet)`. `virtio-gpu-gl-pci` has no `virgl=` property to turn it off either.
  - **The fix that actually worked**: skip `-gl` entirely. Plain **`-device
    virtio-gpu-pci,blob=true,hostmem=256M`** (the *non*-GL device) has its own `blob`/`hostmem`
    properties, needs no `-display egl-headless`, and doesn't touch virgl at all — DMA-BUF/blob-resource
    sharing (what aquamarine's DRM/KMS layer actually needs) is independent of virgl 3D passthrough.
    `dmesg` confirms: `[drm] features: -virgl +edid +resource_blob +host_visible`. Hyprland's log now
    shows a real GBM/DRM EGL context (`Renderer: llvmpipe`, a full GL extension list) and **zero** `CRIT`
    lines. `grim` (run as `export XDG_RUNTIME_DIR=/run/user/1000
    HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1; grim
    /tmp/shot.png`) now exits 0 and produces a real rendered PNG (default Hyprland wallpaper, cursor,
    keybind-hint box) instead of hanging. Full launch command is in Environment notes below — still
    needs `-object memory-backend-memfd,...` + `-machine memory-backend=mem1`, just not `-gl`.
  - **Separately discovered while verifying**: the deployed `~/.config/hypr/hyprland.conf` on the VM was
    just Hyprland's own auto-generated stub (`# This config is a STUB! This should never be generated.`)
    — no `exec-once` lines, so waybar/hyprpaper/hypridle never actually autostarted despite being
    installed. This was never committed anywhere (dotfiles/chezmoi work is still Phase-1-deferred), so
    it was hand-typed once over SSH and is only real on the live VM disk, not reproducible from the repo
    yet. Fixed by appending `exec-once = hyprpaper` / `waybar` / `hypridle` to that file and adding a
    minimal `~/.config/hypr/hypridle.conf` (it has no default and hard-fails with `[CRITICAL]
    ConfigManager: No hypridle.conf file found` otherwise). `exec-once` only fires at Hyprland's initial
    launch, not on `hyprctl reload` — verify a config change to it by dispatching the programs manually
    (`hyprctl dispatch exec <cmd>`) into the running session rather than reloading and expecting them to
    appear. Confirmed working via a second `grim` capture: waybar rendering real live data (network
    `10.0.2.15/24` matching the actual QEMU NAT address, battery/clock modules) on both outputs. This
    config is real but VM-disk-only — worth formalizing into chezmoi-managed dotfiles once that phase
    starts, so it survives a VM rebuild.
- **`dwindle:pseudotile` is not a valid Hyprland 0.56.2 config option** (the version actually installed
  here) — it was removed/moved out of static config in this version; `hyprctl configerrors` reports
  `config option <dwindle:pseudotile> does not exist` and it shows as a persistent red warning banner
  across the top of every screenshot until removed. `preserve_split` under `dwindle {}` is still valid.
  Caught during Group A Task 5's keybind screenshots (the banner had been present, unnoticed, since
  Task 4's hyprland.conf first deployed) — worth checking `hyprctl configerrors` after any future
  hyprland.conf change, not just watching for exec-once/process-level failures.
- **QEMU 8.2.2's monitor `sendkey` rejects the literal key name `super`** — use `meta_l` instead to send
  the Super/Windows key. Extends the `sendkey` character-mapping Gotcha in the `qemu-vm` section above.
- **No working synthetic mouse-drag injection into the guest via this session's tooling** — blocks
  fully exercising anything that needs a click-drag (e.g. `slurp`'s region-select for the
  `SUPER SHIFT,S` screenshot keybind). Found during Group A Task 5. `grim`+`wl-copy` were verified to
  work independently of the drag step; the keybind's dispatch chain was confirmed via process/log
  correlation instead of a full visual capture. Worth solving properly (a real pointer-injection path)
  before any future task needs to test drag-dependent UI.
- **`swayosd`'s OSD bar never paints under this VM's software (llvmpipe) rendering** — a GTK4 layout
  bug (`GtkGizmo ... min width -2`), confirmed independent of the keybind/dispatch path (invoking
  `swayosd-client` directly, bypassing Hyprland's bind entirely, reproduces the same non-render). The
  bind itself fires correctly (server log timestamps match keypresses) — this is a swayosd/GTK4
  rendering issue on this specific VM, not a TorchOS keybind or config defect. Found during Group A
  Task 5; relevant again for any future swayosd-adjacent theming work.
- **`hyprpaper` crashes on launch in this VM** (`journalctl`/foreground run shows `KMS:
  DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied`, then `GBM: Failed to allocate a GBM buffer`,
  then a core dump) — so the TorchOS branding wallpaper (`dotfiles/dot_config/hypr/wallpaper.png` +
  `hyprpaper.conf`, both real and correctly deployed) never actually renders; the desktop falls back to
  Hyprland's own compositor-level default background instead. Root cause: on this VM's specific
  `virtio-gpu-pci,blob=true` setup (no virgl — see the blob/virgl note earlier in this section), only
  Hyprland itself, as DRM master, is permitted to create dumb GBM buffers; hyprpaper's own separate
  EGL/GBM allocation path doesn't have that privilege and fails outright. This is a distinct failure
  from the earlier-resolved aquamarine EGL_BAD_ALLOC issue (that one was fixed by the `blob=true`
  launch flag; this one is hyprpaper specifically trying to allocate its *own* buffers the same way
  Hyprland does, and not being allowed to). Not fixed — genuinely needs either a hyprpaper version/
  config that can render via wl_shm instead of EGL/GBM (unconfirmed whether one exists), or resolving
  the underlying DRM-master delegation, neither of which was pursued here to avoid a GPU/DRM
  rabbit hole disproportionate to Group A's scope. **`hyprpaper.conf`'s block syntax parses
  cleanly** under the installed hyprpaper 0.8.4 (the older `preload =`/`wallpaper = ,path` flat
  syntax from earlier versions does not) — hyprpaper crashes at backend/GBM init, *before*
  ever reaching wallpaper application, so this only confirms hyprlang accepted the keys, not
  that the config is fully correct end-to-end (e.g. whether `preload` is still required
  alongside the block form, or `fit_mode` is the right key name, is unverified). Worth keeping
  as-is for when this VM's GPU setup is revisited, or for real (non-VM) hardware where DRM
  permissions work normally — treat it as parses-not-proven-correct, not verified-working.

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
- **Neither `torch` nor `torch-welcome` is put on `$PATH` by anything in this repo.** Both are only
  reachable on the current VM because of a hand-run `sudo ln -sf ~/torch/target/{debug,release}/<bin>
  /usr/local/bin/<bin>` from Group A's own build/verification sessions — not reproducible from a
  fresh VM built off this repo. `hyprland.conf`'s `exec-once = torch-welcome` and
  `torch-welcome.desktop`'s `Exec=torch-welcome` both silently assume it's already on `$PATH`; a
  rebuilt VM gets no welcome window at all (not even a broken one). Needs a real step somewhere
  (`scripts/install-apps.sh`, or a dedicated small install script) that builds and symlinks both —
  not done yet, found during Group A's final whole-branch review.

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

### rust builds in the VM
- **`cargo build --release` gets SIGKILL'd (OOM) on this VM's 2GB RAM** (confirmed:
  `free -h` shows ~1.3GB available, 0B swap configured) — rustc's default `opt-level = 3` LTO/
  codegen work is too memory-hungry for a debug-vs-release build here, even though plain
  `cargo build` (debug profile) is fine. Workaround that's actually worked (`torch-welcome`, Group
  A Task 3): set `CARGO_PROFILE_RELEASE_OPT_LEVEL=1` in the environment for the build command,
  e.g. `CARGO_PROFILE_RELEASE_OPT_LEVEL=1 cargo build --release -p <crate>` — this is a build-time
  env var, not committed to any `Cargo.toml` (workspace member ownership boundaries in the Group A
  plan deliberately kept `Cargo.toml` out of individual tasks' file lists). Any future session
  running a plain `cargo build --release` on this VM will hit the same OOM until this is either
  baked into a `Cargo.toml`/`.cargo/config.toml` profile override or worked around the same way
  each time.

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
normal boots use `-boot order=c` with no `-cdrom`) — this is the **GPU-accelerated** form, working as
of 2026-08-24 now that the owning user is in the `kvm` group (needs a fresh login/session after that
group grant, see the `gpu / hyprland-in-vm` Gotcha for why plain `virtio-gpu-pci` with `blob=true` is
used instead of `virtio-gpu-gl-pci`):

```
qemu-system-x86_64 -name torchos-vm -enable-kvm -cpu host -smp 2 \
  -object memory-backend-memfd,id=mem1,size=2048M -machine memory-backend=mem1 \
  -drive file=image/vm/torchos-vm.qcow2,if=virtio,format=qcow2 -boot order=c \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \
  -device virtio-gpu-pci,blob=true,hostmem=256M -vnc :1 \
  -serial telnet:127.0.0.1:4555,server,nowait \
  -monitor unix:image/vm/monitor.sock,server,nowait
```

(If `/dev/udmabuf` isn't accessible — check with `ls -la /dev/udmabuf` and confirm `kvm` shows in
`groups` — drop `-object memory-backend-memfd,...`/`-machine memory-backend=mem1` and
`,blob=true,hostmem=256M` to fall back to the older non-accelerated `-device virtio-gpu-pci` form;
Hyprland still runs as a real process, just not visually verifiable via `grim`.)

SSH: `ssh -p 2222 torch@localhost` (password `torchos2026` — throwaway, local-NAT-only VM, no need to
harden). `sudo` works for `torch`. This host has no `sshpass`/passwordless-sudo path to install it, so
scripted SSH here unpacks it from an `apt download`'d `.deb` via `dpkg-deb -x` into a scratch dir rather
than installing system-wide — same no-root pattern noted for other tools above. Screenshot the VM
anytime via the monitor socket's `screendump`
command (writes a `.ppm`; `convert file.ppm file.png` to view with the Read tool) — this is the
actual way to verify GUI/desktop state later, not just serial/SSH text.
