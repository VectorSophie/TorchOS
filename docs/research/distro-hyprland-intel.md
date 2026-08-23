# TorchOS v2 Base-Platform Research — Distro, Hyprland, Intel iGPU, Installer

Research date: 2026-08-23. Priority order: **Convenience > Compatibility > Reliability > Recoverability > Security > Elegance > Novelty.**

---

## 1. Base distro choice

### Candidates evaluated
Vanilla Arch · CachyOS · EndeavourOS · Fedora Kinoite (+ Bazzite) · openSUSE Tumbleweed · NixOS

### Findings per axis

**Install/bootstrap ease** — Vanilla Arch: `archinstall`, functional but leaves Btrfs layout/snapper/bootloader-hooks/Hyprland/theming as DIY. CachyOS: two installers (Calamares GUI, lays out Btrfs the way snapper expects out of the box; and a CLI installer). EndeavourOS: also Calamares-based, minimal-but-friendly. Fedora Kinoite/Bazzite: image-based, very turnkey. openSUSE Tumbleweed: mature YaST/Calamares, Btrfs+snapper is the *default* layout. NixOS: installer exists, but the real "install" is learning the Nix language/module system.

**AUR availability** — CachyOS/EndeavourOS/vanilla Arch: full native AUR. Fedora Kinoite: none (Flatpak/rpm-ostree layering/toolbox). openSUSE Tumbleweed: none (OBS home repos are a partial, far-less-discoverable analog). NixOS: no AUR, but nixpkgs reports 80k+ packages (different mental model — derivations/flakes).

**Rolling-release stability track record** — EndeavourOS rated most stable of the Arch family (closest to upstream, fewest moving parts). CachyOS trades some stability for performance — its own repos/kernels are "an extra layer to manage during upgrades." Vanilla Arch stable if disciplined. openSUSE Tumbleweed has an actual openQA gating pipeline before packages hit the repo. NixOS unstable channel is rolling; stability is more about workflow friction than breakage.

**Btrfs support / snapshot-rollback maturity** — **openSUSE Tumbleweed**: native, decades-refined default, turnkey rollback flow. **CachyOS**: Btrfs is the "non-negotiable recommended filesystem," ships `snap-pac` by default plus `limine-snapper-sync` for boot-menu-integrated rollback — materially more convenient than stock Arch/EndeavourOS, which need this wired up manually. **EndeavourOS/vanilla Arch**: Btrfs offered at install but snapper+bootloader integration is not automatic. **Fedora Kinoite**: rpm-ostree image deployments instead of snapshots — arguably more bulletproof for whole-system rollback but far more restrictive for a hand-tuned Hyprland desktop. **NixOS**: generations-based rollback, most deterministic recovery model of all.

**Package manager performance** — Pacman is fastest of the mainstream managers; DNF5 has closed much of the gap; Zypper had a major 2026 speed upgrade; pacman remains the practical leader.

**Community size / longevity** — Arch/EndeavourOS/CachyOS benefit from the ArchWiki, the largest and most-cited Linux documentation resource — a major asset for both human troubleshooting and LLM-assisted repair. Community norms are actively resistant to AI-generated wiki edits (2026 "LLM pollution" concerns) — a signal the human-curated quality bar stays high, good for an LLM *consuming* it as ground truth. CachyOS community "tripled in size in 2025." Fedora: very large, Red Hat-backed. openSUSE: large, SUSE-backed, deep Btrfs/snapper institutional history. NixOS: large but specialized audience.

**Hardware compatibility** — Rolling releases get new kernels/Mesa fastest (matters for tracking Intel Xe). CachyOS additionally ships a custom-patched kernel with scheduler/latency tweaks (extra variable to debug if something regresses). Fedora praised for "just working" hardware support and fast firmware/codec packaging.

### Fit for "install once, largely self-maintaining, AI-repairable"
Two things matter most: unattended recoverability given for free, and how well an LLM can diagnose/fix breakage using existing documentation/precedent.

- **CachyOS** wins on both: boot-menu Btrfs rollback + auto pre/post-transaction snapshots out of the box; inherits ~95% of ArchWiki/AUR-trained LLM knowledge (its custom-repo/kernel delta is the ~5% gap needing TorchOS-authored notes).
- **EndeavourOS** nearly as good once snapper is wired up manually; more predictable since it changes less, but no default convenience win.
- **Vanilla Arch** best-documented for AI-repair (it *is* the ArchWiki's subject) but weakest "self-maintaining out of the box."
- **openSUSE Tumbleweed** most mature native Btrfs/snapper story, legitimate #2 choice; weaker AUR-equivalent breadth and Hyprland-on-Tumbleweed precedent.
- **Fedora Kinoite** strongest whole-system atomic-rollback guarantee, but the immutable-base model fights a hand-rolled AUR-flexible Hyprland desktop.
- **NixOS** most rigorous reproducibility (the whole system, Hyprland config included, is one pinnable/rollback-able generation) — philosophically the best "AI-repairable" match in the abstract, but the Nix learning curve taxes Convenience and Nix-specific fixes are a narrower body of knowledge than ArchWiki-style imperative fixes.

### Recommendation
**CachyOS**, with **EndeavourOS** as the credible fallback and **openSUSE Tumbleweed** as the strongest non-Arch alternative if the CachyOS-specific layer ever becomes a liability.

### Comparison table

| | Install ease | AUR | Rolling stability | Btrfs/snapshot out-of-box | Pkg mgr speed | Community/docs | Fit for "AI-repairable" |
|---|---|---|---|---|---|---|---|
| **CachyOS** | GUI/CLI, Btrfs+snapper pre-laid-out | Full | Good, occasional friction | **Best** (auto snapshots + boot-menu rollback by default) | Fastest (pacman) | Large, fast-growing, inherits ArchWiki | **Best overall** |
| Vanilla Arch | Manual | Full | Good if disciplined | Manual setup | Fastest | Largest docs | Best raw docs, worst turnkey convenience |
| EndeavourOS | GUI | Full | **Best** | Manual setup | Fastest | Good, Arch-adjacent | Very good, less pre-wired |
| Fedora Kinoite/Bazzite | Turnkey image | None | Very good (image-based) | N/A — rpm-ostree instead | DNF5 | Very large | Strong rollback, weak AUR/Hyprland fit |
| openSUSE Tumbleweed | GUI, native Btrfs+snapper | None | Very good (openQA-gated) | **Native reference impl.** | Zypper (improved) | Large, SUSE-backed | Strong #2 |
| NixOS | Steep | None (nixpkgs) | Good | N/A — generations | N/A | Large but specialized | Most rigorous, worst onboarding |

---

## 2. Hyprland fit (2026)

**Stability & cadence** — stable line at 0.55–0.56 as of mid-2026 (0.56.0 → 0.56.1 one week later with 14 regression fixes → 0.56.2 with 16 backported fixes). Fast, aggressive development; practical risk is config/API migration friction, not runtime crashes — patches land quickly.

**Multi-monitor** — solid core support; real tooling around it (`nwg-displays`, `kanshi`, `hyprmon`, `HyprDynamicMonitors` for profile-based switching).

**Laptop support** — native lid-switch handling, `hypridle` for idle/lock. **Known open issue directly relevant to the Intel-iGPU-laptop target**: lid-suspend/resume on Intel i915 can leave the panel "wedged" (blank) on Hyprland 0.55.1/aquamarine 0.11.0; `AQ_NO_ATOMIC=1` + disabling hardware cursors mitigates but doesn't fully resolve it.

**Plugin/ecosystem maturity** — Hyprland's own official ecosystem (hypridle/hyprlock/hyprpaper/xdg-desktop-portal-hyprland) covers the basics; third-party shells go further — Omarchy 4 replaced the traditional waybar/walker/mako/hyprlock/swayosd stack with a single unified **Quickshell**-based process with IPC and a plugin manifest, materially more "product-grade" than assembling loose components.

### Pre-built Hyprland shells evaluated

| Project | Approach | Maturity signal | Notes for TorchOS |
|---|---|---|---|
| **Omarchy** (basecamp/omarchy, DHH) | Full opinionated Arch+Hyprland distro-on-top-of-Arch; own ISO installer (Limine+Snapper, LUKS mandatory, auto-login); v4 unified shell into Quickshell | 28.4k★/2.9k forks, MIT, very active | **Closest existing precedent to what TorchOS wants**: opinionated, single-vendor-feel, snapshot-rollback baked into the installer. Needs de-Omarchy-ing/rebrand, but architecturally the best reference to fork from. |
| **HyDE** | Dotfiles/config framework layered onto existing Arch; 70+ theme library, one-command switch | 8.8k★, actively maintained, XDG-compliant | Lighter-weight; better as a theming/config layer than a full distro replacement. |
| **JaKooLit/Hyprland-Dots** | Install-script-driven, multi-distro (Arch/Fedora/Ubuntu/Debian/openSUSE) | Large, long-running community | Most portable if the base distro changes; more power-user toolkit than polished shell. |
| **end-4/dots-hyprland** | Material You theming, AI widgets, live previews | Most visually advanced | Heaviest footprint, most idiosyncratic — mine for ideas, don't adopt wholesale. |
| **ML4W** | GUI-driven, beginner-friendly | Lightweight | Flagged as the "beginner GUI" option. |

### Recommendation
**Adopt, don't build from scratch.** Use **Omarchy's architecture as the foundation** (ISO-build tooling, Limine+Snapper install flow, Quickshell-based unified shell), **fork and rebrand** rather than depend on it upstream. Mine **HyDE** for theming-layer patterns, **JaKooLit** for portability reference if the base distro ever changes.

---

## 3. Intel integrated graphics on Wayland/Hyprland (2026)

**Driver maturity: i915 vs Xe** — Two coexisting drivers: legacy **i915** (mature, default almost everywhere pre-Meteor-Lake) and **Xe** (rewritten, default only for Lunar Lake/Battlemage-class hardware). Distros install with i915 by default even on Core Ultra hardware. Forcing Xe still requires manual steps as of March 2026 sources even with recent Mesa — not yet "it just works." **Design implication**: don't hard-pin one driver; default i915 for broad coverage, document/screen for newer hardware where switching to Xe is worth it; keep the kernel/Mesa stack current (favors a rolling-release base).

**Known Hyprland+Intel iGPU issues** — Tearing support explicitly still experimental (fullscreen sole-visible app only). VRR: open issues around framerate tracking, and VRR+tearing simultaneously causes stutter (KDE reportedly handles the combination cleanly; less relevant to a typical Intel-iGPU productivity box). Idle GPU usage: reported high Render/3D engine usage tied to mouse movement — battery-relevant. Suspend/resume: the aquamarine lid-wedge bug (above) is Intel-i915-specific and directly on-target. Video decode/hw accel: no Hyprland-specific breakage found; standard VA-API setup (`intel-media-driver`/`libva-intel-driver`) is compositor-agnostic.

**What to design around vs. AMD/NVIDIA** — No proprietary-driver problem (strength for a rolling-release/self-maintaining product — no DKMS rebuilds to break on kernel updates). But two active driver stacks in transition (i915/Xe) vs. AMD's one settled `amdgpu` — real added complexity to test/document. Compositor-level rough edges are being actively patched upstream — expect to track Hyprland point releases fairly closely on Intel hardware, reinforcing the rolling-base-distro case.

---

## 4. Installer/ISO strategy precedent

**Arch's official path**: `archinstall` — official, terminal-driven, on the stock ISO.

**Calamares** — de facto standard GUI installer across the Arch-derivative world: distribution-agnostic, explicitly designed for downstream rebranding without patching, current stable 3.4.2 (March 2026).

- **CachyOS**: customized Calamares build (`cachyos-calamares`) as default GUI path + a CLI installer alternative; already lays out Btrfs subvolumes the way snapper/limine-snapper-sync expect, so rollback works with zero extra manual steps post-install. `cachyos-hello` is a separate first-boot welcome utility, not the installer.
- **EndeavourOS**: also Calamares-based.
- **Omarchy 2.0+**: built its own ISO pipeline (`omarchy-iso`, Docker-based reproducible builds) producing a bootable Arch-based ISO with an interactive configurator and automated post-install setup (Limine+Snapper+LUKS+auto-login-to-Hyprland by default); still supports "install vanilla Arch via archinstall, then layer Omarchy on top" as an alternative.

### Recommendation
Do **not** repeat the old TorchOS Cubic/manual-ISO approach. Two-layer split:
1. **Base path**: Fork CachyOS's Calamares configuration (`cachyos-calamares`) — already solves Btrfs subvolume layout matched to snapper/limine-snapper-sync; Calamares is explicitly designed to be rebranded without patching core code.
2. **Reference/inspiration**: Study Omarchy's `omarchy-iso` pipeline as the model for the *post-install provisioning* layer — once Calamares lays down CachyOS+Btrfs+snapper, an Omarchy-style scripted step installs/configures Hyprland/the shell/dotfiles/theming.

This cleanly separates "partition and base OS" (Calamares' job) from "opinionated desktop provisioning" (TorchOS's actual product surface).

---

## Cross-cutting takeaways for TorchOS

- **Base distro: CachyOS.** Best out-of-the-box Recoverability of any evaluated option short of NixOS/atomic, while keeping full AUR compatibility and the fastest package manager — serves Convenience + Compatibility + Recoverability in one choice.
- **Fallback: EndeavourOS.** Same Calamares/AUR/Arch-family story, more upstream-faithful; requires manually wiring snapper+bootloader integration CachyOS gives free.
- **Non-Arch fallback: openSUSE Tumbleweed.** Most mature native Btrfs/snapper implementation, at the cost of AUR breadth and the mature Hyprland-on-Arch ecosystem.
- **Hyprland foundation: fork Omarchy's architecture, not its branding.** Mine HyDE for theming patterns, JaKooLit for portability reference.
- **Installer: Calamares (via CachyOS's existing config), not a custom installer.** Layer an Omarchy-style scripted provisioner on top for Hyprland/desktop setup.
- **Intel iGPU: default to i915, plan for Xe as opt-in.**
- **Watch-list bugs on target hardware**: i915 lid-suspend/resume panel-wedge (open), idle-time GPU usage during mouse movement, VRR+tearing-simultaneous stutter.
- **AI-repairability is quantifiable, not just a vibe**: CachyOS/Arch-family inherits the largest LLM-training-represented Linux doc corpus; CachyOS's own custom-repo/kernel delta isn't covered by it and deserves TorchOS-authored troubleshooting notes.
