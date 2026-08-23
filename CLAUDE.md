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
| Recovery | **Snapper + snap-pac + limine-snapper-sync + Btrfs Assistant** (CachyOS's own default stack) | grub-btrfs if GRUB instead of Limine |
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
- [ ] Phase 1 implementation plan written (`writing-plans`)
- [ ] Phase 1: VM provisioned (QEMU/KVM, virtio-gpu/virgl, ~3GB RAM)
- [ ] Phase 1: CachyOS installed in VM
- [ ] Phase 1: Omarchy-fork Hyprland desktop provisioned
- [ ] Phase 1: `torch` CLI skeleton scaffolded
- [ ] Phase 1: Btrfs snapshot + rollback verified inside VM
- [ ] Phase 1: basic structured diagnostics wired up
- [ ] Phase 2: `torchd` + polkit action set
- [ ] Phase 3: AI assistant (Agent SDK + MCP) wired to `torchd`
- [ ] Phase 4: `torch install` compatibility resolver
- [ ] Phase 5: Calamares installer fork
- [ ] Phase 6: real Intel-iGPU hardware validation

## Gotchas

*(Empty — this is a living, append-only list. Add entries here as Phase 1+ execution surfaces
non-obvious, hard-won facts: exact package names, systemd unit ordering quirks, Hyprland/PipeWire
version traps, Intel iGPU/Mesa driver footguns, CachyOS-specific deltas from vanilla Arch. Categorize
by subsystem — broker / snapshots / Hyprland / intel-gfx / ai-agent — once there's more than a handful,
per the VibeOS research: an uncategorized flat list gets unwieldy fast at TorchOS's surface area.)*

## Session record

No dedicated session-log files yet — git commit history is the decision record at this stage (each
commit states what changed and why). Revisit if/when commit messages stop being sufficient for context
continuity across sessions; don't build a logging system ahead of needing one.

## Environment notes (this dev/test machine)

Linux Mint 22.2, apt-based. Bare metal (not nested virtualization), Intel VT-x present, `/dev/kvm`
exists. As of 2026-08-24: no VM tooling installed, no passwordless sudo, 7.4GB RAM total and already
under real memory pressure (swap in active use) — budget VM allocations accordingly, don't assume v1's
old 8GB default applies.
