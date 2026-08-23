# TorchOS v2 — Snapshot/Rollback & Dotfiles Tooling Research

Researched 2026-08-23. Priority frame: **Convenience > Compatibility > Reliability > Recoverability > Security > Elegance > Novelty.**

---

## 1. Snapshot/rollback tooling on Btrfs + Arch-family + systemd

### The tools

| Tool | Role | Maintenance status (checked 2026-08-23) |
|---|---|---|
| **Snapper** (openSUSE) | Snapshot manager: create/list/delete/diff, retention/cleanup, `rollback`/`undochange` | Very active — pushed 2026-08-19, 1169★. De facto standard on Arch/openSUSE. |
| **snap-pac** | Pacman hooks calling Snapper automatically pre/post every transaction | `wesbarnett/snap-pac`, last pushed 2022-01, 231★ — low churn but feature-complete, still the current Arch package. |
| **snap-pac-grub** | Refreshes grub-btrfs boot entries after snap-pac snapshots | Small companion AUR package. |
| **grub-btrfs** | "Btrfs snapshots" GRUB submenu; `grub-btrfsd` watches `/.snapshots` via inotify | Active — pushed 2026-08-05, 1148★, in Arch `extra`. |
| **limine-snapper-sync** | Same job for the **Limine** bootloader; provides restore/rollback helpers | GitLab, 674 commits, 61 releases, actively developed. Packaged directly in CachyOS repos — what CachyOS and Omarchy ship by default. |
| **Timeshift** | Standalone GUI/CLI snapshot tool, rsync+hardlink or Btrfs mode | Original archived Oct 2022; maintenance moved to Linux Mint, pushed 2026-04-08. Btrfs mode only supports Ubuntu-style layout, no pacman-hook integration, no first-class Arch boot-menu rollback. |
| **Btrfs Assistant** | GUI front-end for Snapper + Btrfs maintenance | `garuda-linux/btrfs-assistant`, packaged in Fedora/CachyOS/Garuda — the "no terminal" layer on top of Snapper. |

### How boot-time rollback actually works

1. A broken update happens. snap-pac's pre/post snapshots plus grub-btrfsd/limine-snapper-sync's inotify watcher mean the bootloader menu **already has an entry for the pre-update snapshot**, no extra action needed.
2. User reboots, picks the snapshot entry. Boots read-only via an overlay — usable but not persistently writable.
3. To make it stick, run `snapper rollback [number]` — creates a read-only backup of the abandoned state and a new read-write snapshot that becomes the default `@` subvolume on the *next* normal boot.
4. CachyOS/Omarchy wrap the last step in convenience commands (`limine-snapper-restore`) so the loop doesn't require raw `snapper`/`btrfs` incantations.

**Yes, a user can boot straight into a prior snapshot after a broken update**, but "boot into it" and "make it permanent" are two distinct steps by design (inspect first, commit second) — a safety feature, not a gap, matching "always have a way back" well since it prevents an accidental snapshot-boot from silently becoming permanent.

### Retention / pruning and disk space

- Snapper cleanup is per-config, driven by two algorithms that can run together: `number` (count cap) and `timeline` (hourly/daily/weekly/monthly/yearly), enforced by `snapper-cleanup.timer`.
- Snapshots tagged `--userdata important=yes` at creation land in a **separate, more conservative retention bucket** — directly useful for pinning AI-initiated checkpoints so routine cleanup can't prune them.
- Copy-on-write means near-zero space at creation; growth is proportional to divergence. Favorable for "snapshot before every privileged change" as a default posture, but the cleanup timer needs to actually be enabled/tuned, not left on generous defaults.
- Real Arch-specific risk: kernel/driver snapshots pin old kernel modules, inflating `/boot`/module storage over time. CachyOS's real-world default (last-5, hourly timeline disabled) is a sane reference retention policy for a daily-driver box.

### Recommendation
**Snapper + snap-pac + limine-snapper-sync + Btrfs Assistant** — mirrors what CachyOS itself already ships by default, the path of least packaging friction for a CachyOS-family distro. Use grub-btrfs instead of limine-snapper-sync only if TorchOS ends up on GRUB rather than Limine — functionally interchangeable, both healthy. Skip Timeshift (redundant, non-Arch-native, would create a second history to reconcile). Btrfs Assistant as an optional GUI raises the convenience floor at near-zero cost.

---

## 2. Named/manual checkpoints (distinct from automatic transaction snapshots)

Snapper already supports this natively — no extra tooling needed:

```
sudo snapper -c root create -d "before AI: enabling nvidia-open driver" -u important=yes
```

- `-d/--description` gives a human-readable label (vs. snap-pac's auto-generated pacman-transaction descriptions).
- `-u/--userdata key=value,...` attaches structured metadata (e.g. `agent=torchos-ai,action=driver-swap`); `important=yes` **exempts the snapshot from routine `number`-algorithm pruning**.
- Snapshots also support `single` type (a standalone checkpoint, no paired pre/post) — the right primitive for "one manual checkpoint," vs. snap-pac's `pre`/`post` pair.
- Composes cleanly for TorchOS's AI-assistant requirement: before any privileged modification, run one `snapper create -d "<what and why>" -u important=yes,agent=torchos-ai` call, get back a snapshot number to reference in logs/undo, and the label is visible to a human via `snapper list`/Btrfs Assistant without parsing pacman transaction logs.

No wrapper tool is required — a thin `torchos-checkpoint "label"` helper setting these two flags with sane conventions is enough.

---

## 3. Declarative, versioned, rollback-friendly config management ("ricing as system state")

### Options compared

| Tool | Model | Git-native? | Safety for automated/AI edits | Maintenance |
|---|---|---|---|---|
| **GNU Stow** | Symlink farm manager | Files are plain git content, Stow just symlinks | No dry-run/diff layer of its own | `aspiers/stow`, pushed 2025-12-03, 1096★ — stable, low-churn |
| **yadm** | Git wrapper: bare repo with `--work-tree=$HOME`; real files not symlinks; templating, encryption, bootstrap hooks | Fully git-native | Files live at their real target path — **no separation between "source" and "live"**; revert is `git checkout`/`git revert` in place, no pre-apply diff gate | `yadm-dev/yadm`, pushed 2026-04-13, 6395★ — active |
| **chezmoi** | Source-of-truth dir + explicit `chezmoi apply` computing/applying a minimal diff; Go templating; built-in secrets integration | Git-backed source dir | **Best fit for an AI editor**: `chezmoi diff` previews exactly what would change before touching real files; `chezmoi apply` is the only write path; `chezmoi cat` renders without applying | `twpayne/chezmoi`, pushed 2026-08-23 (today), 21264★ — by far the most active |
| **Home Manager (standalone)** | Fully declarative Nix module compiled to a generation; atomic activation, rollback via generations | Config is Nix; rollback unit is a generation, not a git commit | Strongest atomicity, but requires a second package manager (Nix) and re-expressing rice config *as* Nix — a large translation layer for an AI to reason through | Actively maintained upstream |

### Recommendation: **chezmoi**

- **Preview-before-write is the deciding factor** — `chezmoi diff` gives a dry-run before any real dotfile is touched. Stow and yadm both write straight to the live file/symlink with no equivalent gate.
- Config lives as plain (or lightly templated) files, readable/editable with ordinary file tools — unlike Home Manager's Nix round-trip.
- Git-backed source dir: "undo the desktop changes from yesterday" is `git log`/`git revert` inside `~/.local/share/chezmoi`, then `chezmoi apply`.
- No second toolchain (Nix) to install/learn.
- Most active project of the three by a wide margin — better long-term support, more prior art for edge cases.

### Separating rice/config from generated/cache state
Standard **XDG Base Directory** separation: chezmoi manages `$XDG_CONFIG_HOME`; `$XDG_CACHE_HOME`/`$XDG_DATA_HOME` runtime artifacts stay untracked — opt-in by construction since chezmoi only version-controls what's explicitly added to its source dir.

---

## 4. Overlap/conflict between Btrfs snapshots and dotfiles versioning

**Deliberately separate mechanisms — do not conflate them.**

- **Different granularity and intent.** A Btrfs/Snapper snapshot is a whole-subvolume, point-in-time freeze — coarse, atomic, blind to *why* something changed. A chezmoi git commit is a targeted, labeled, diffable change to one config concern. Using Btrfs snapshots to undo one rice tweak would roll back *everything*, including unrelated system state — a blast-radius mismatch that works against "always have a way back" by making recovery all-or-nothing.
- **Different subvolume, different lifecycle.** `$HOME` is conventionally its own Btrfs subvolume (`@home`) with its own (often tighter) Snapper retention, already on a separate cadence from root/package snapshots. Dotfiles' git history rides *inside* that subvolume as a second, finer-grained layer.
- **Where they usefully overlap**: a Btrfs/Snapper snapshot of `@home` is still the right backstop for catastrophic cases a git revert can't fix — a corrupted chezmoi source dir, a raced `chezmoi apply`, disk-level damage, or the git repo itself being deleted.
- **Practical implication**: don't route dotfiles changes through Snapper checkpoints (too coarse, no per-change labels a user recognizes), and don't make chezmoi responsible for system-level rollback (no concept of packages/kernels/drivers). Reserve `snapper create -d "..." -u important=yes` for privileged/system-level AI actions; use chezmoi's own git history for config-level "what changed and why" — two distinct undo commands for two distinct kinds of "way back."

---

## Cross-cutting takeaways for TorchOS

- **Snapper is the load-bearing engine for everything system-level** — pick it regardless of any other decision.
- **snap-pac + limine-snapper-sync (or grub-btrfs if GRUB) gives automatic pre/post snapshots and boot-menu rollback for free** — CachyOS's own default stack, least packaging friction.
- **Boot-time rollback is a two-step "inspect, then commit" flow by design** — build UX/docs around that distinction rather than promising one-click permanent rollback from the boot menu.
- **Skip Timeshift** — duplicates Snapper's job with a non-Arch-native model and no pacman-hook integration.
- **Use Snapper's built-in `-d` description + `-u important=yes` userdata for AI/manual checkpoints** — no new tooling needed.
- **chezmoi for dotfiles/rice** — mandatory diff-before-apply is the single best safety property for an AI editing live config; most actively maintained of the compared tools.
- **Skip standalone Home Manager** — atomic generation rollback is elegant but forces rice/config through a Nix DSL and a second package manager.
- **Keep Btrfs snapshots and dotfiles git history as two deliberately separate undo mechanisms.**
