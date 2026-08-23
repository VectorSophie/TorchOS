# TorchOS v1 (legacy)

This is the original TorchOS: an experimental, disposable AI-research-lab Linux environment built
around Btrfs-snapshotted "labs" (`torch lab create/enter/reset/commit/delete`), a Rust CLI
(`torch-cli/`), a GTK Python GUI/HUD (`ui/`), and Docker/Cubic-based ISO/VM build scripts.

It was rebooted from scratch on 2026-08-24 into a different product: a personal daily-driver Hyprland
desktop with an AI system-mechanic assistant, not a research distro. See
`../../docs/superpowers/specs/2026-08-24-torchos-v2-architecture-design.md` for the full v2 design and
why the reboot happened.

Git history for everything here is preserved (moved via `git mv`, not deleted and recreated) — `git log
--follow` on any file in this tree still shows its full history.

## What was retained (as reference/pattern, not as code that keeps running)

- **"CLI is the source of truth, GUI wraps it, no independent state."** v1's GTK GUI/HUD
  (`ui/src/torch-labs-gui.py`, `ui/src/torch-hud.py`) got this right — every button just shells out to
  `torch` and parses its stdout. v2's HUD should follow the same principle even though the
  implementation (Quickshell, forked from Omarchy) is entirely different.
- **`torch-cli`'s clap-based project layout** (`commands/` / `system/` / `types/` / `ui/` module split)
  as a starting skeleton for the new `torch` binary — the structure was sound, even though the specific
  commands (`lab create`, `dataset list`, ...) are Labs-specific and don't carry forward.
- **`docs/` writing style** — short, example-driven, one file per topic. v2's `docs/` follows the same
  convention (see `docs/research/` and `docs/superpowers/specs/`).
- **`assets/logo.png` and `ui/theme/gtk-3.0/gtk.css`** (the torch-orange `#ff4500` / flame `#ff6a00` /
  dark-ember `#2b0a00` palette) — kept as-is for now, owner's explicit decision (2026-08-24). Not
  relocated out of `legacy/v1/` yet since no v2 phase needs branding assets before Phase 5
  (installer) at the earliest; pull directly from here when that need arrives.

## What was discarded (superseded, not carried forward)

- **Raw `btrfs.rs` subvolume shell-outs** (`torch-cli/src/system/btrfs.rs`) → superseded by
  Snapper/snap-pac/limine-snapper-sync, which already solve pre/post-transaction snapshotting and
  boot-menu rollback more robustly than hand-rolled `btrfs subvolume create/snapshot/delete` calls.
- **The Labs concept itself** (disposable per-experiment Btrfs snapshot environments,
  `torch-cli/src/commands/lab.rs`, `system/isolation.rs`'s `systemd-nspawn` wrapping) → v2 repurposes
  Btrfs snapshots for whole-system rollback ("the system may change, the user should always have a way
  back"), not disposable research environments. Nothing in the Labs command surface maps directly onto
  that.
- **The GTK Labs GUI/HUD** (`ui/src/torch-labs-gui.py`, `ui/src/torch-hud.py`) → Labs-specific UI,
  superseded by a Quickshell-based HUD forked from Omarchy's shell architecture.
- **Cubic ISO scripts** (`scripts/build-iso.sh`, `scripts/cubic/setup-iso.sh`,
  `scripts/install-cubic-mint.sh`) → manual, semi-interactive Cubic chroot workflow; superseded by
  forking CachyOS's `cachyos-calamares` config plus an Omarchy-style scripted provisioner (v2 Phase 5).
- **Docker devcontainer approach** (`docker/Dockerfile`, `docker/build.sh`) → built a whole
  Cinnamon+Btrfs+Rust dev environment inside a container as the primary dev workflow; superseded by
  targeting a real QEMU/KVM VM directly (v2 Phase 1), which is what actually needs validating (a real
  Hyprland desktop rendering, real Btrfs snapshots, real systemd).
- **`gpu_detect.rs`'s raw `nvidia-smi` shelling + `scripts/mock-gpu/nvidia-smi`** → wrong vendor for
  v2's first target hardware (Intel integrated graphics, not NVIDIA), and superseded by a structured
  diagnostics layer (v2 Phase 1) rather than parsing CLI text output.
- **`setup-mint.sh` / Linux Mint (Cinnamon) as a base** → v2 targets CachyOS (Arch family) +
  Hyprland instead; Mint/Cinnamon was v1's "install directly on an existing PC" path and doesn't apply
  to v2's base-distro decision.

## What was never fully realized in v1 (worth knowing about, not a retain/discard call)

- `torch-cli/src/commands/init.rs` had a duplicated directory/subvolume-creation code block (copy-paste
  artifact, ran the same steps twice) — a real bug that never got fixed. Not being fixed here since none
  of it carries forward, but noted so it isn't mistaken for intentional design if anyone reads the code.
- `torch-cli/src/ui/dashboard.rs` (`torch top`) showed real host CPU/memory via `sysinfo` but hardcoded,
  fake per-lab rows ("lab-1: Running [PID: 4521] - GPU: 45% VRAM") — never wired to real per-lab data.
  A useful reminder for v2: the FableOS/Antigravity research (`docs/research/fableos-antigravity.md`)
  is explicit that this exact failure mode — a plausible-looking but fake status display — is exactly
  what v2's structured-diagnostics-over-scraped-text approach and verification discipline are meant to
  prevent.
