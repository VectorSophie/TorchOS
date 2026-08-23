# TorchOS v2 — Architecture Design

Status: **approved by user 2026-08-24**, pending written self-review below.
Author: Claude (Sonnet 5), in conversation with the project owner.
Research appendix: `docs/research/*.md` (7 files, see links throughout).

## 1. Product definition

TorchOS is being rebuilt from scratch. The old repository (now `legacy/v1/`) was an AI-research-lab
distro built around disposable Btrfs-snapshotted "labs." TorchOS v2 is a different product: **a personal
operating environment built for convenience, compatibility, recovery, and a polished daily desktop —
not a research distro.** AI is a maintenance/control layer, not the product's identity.

Target experience: install once, boot into a finished Hyprland desktop, almost anything a normal Linux
user wants installs and runs without ceremony, a Claude Code–style assistant is always nearby, and when
something breaks the assistant diagnoses it, fixes what it safely can, and rolls back what it can't.

**Priority order, always**: Convenience > Compatibility > Reliability > Recoverability > Security > Elegance > Novelty.

**Hard non-goals**: an AI-themed Linux skin, a custom kernel, a from-scratch distro for ideological
purity, a NixOS-config clone, a chatbot overlay, an experimental container OS, a developer-only
environment, a dotfiles collection, a Linux tutorial generator, a security product that blocks its own
owner, a custom package ecosystem. Prefer integrating mature Linux infrastructure over reinventing it.

## 2. Base distro: CachyOS

**Decision: CachyOS** (Arch family). Fallback if its custom repo/kernel layer causes update friction:
**EndeavourOS** (same Calamares/AUR/Arch-family story, more upstream-faithful, requires manually wiring
the snapshot integration CachyOS gives free). Non-Arch fallback if the AUR trust model itself ever
becomes the problem: **openSUSE Tumbleweed** (most mature native Btrfs/snapper implementation,
openQA-gated rolling QA, at the cost of AUR breadth and Hyprland-on-Arch ecosystem depth).

**Rationale**: CachyOS is the only Arch-family distro shipping `snap-pac` (automatic pre/post-pacman
Btrfs snapshots) and boot-menu rollback (`limine-snapper-sync`) *by default* — zero-setup Recoverability
on day one. Full AUR compatibility, fastest package manager (pacman), rolling kernel/Mesa (needed to
track the Intel i915→Xe driver transition). Inherits the ArchWiki's documentation depth — the largest,
most LLM-training-represented Linux doc corpus — which materially helps both human and AI-assisted
troubleshooting; the one gap is CachyOS's own custom-repo/kernel delta, which isn't covered by that
corpus and needs TorchOS-authored troubleshooting notes over time.

**Ruled out**: Fedora Atomic/Bazzite, openSUSE Aeon/Kalpa, Vanilla OS, NixOS as the *base* — all trade
away Convenience/Compatibility (AUR, mutable-package workflows) for a Reliability guarantee TorchOS gets
more cheaply another way (§4). None are Arch/Hyprland-native in spirit.

Full comparison table and per-axis findings: `docs/research/distro-hyprland-intel.md` §1.

## 3. Desktop stack: Hyprland, forking Omarchy's architecture

**Decision**: Hyprland (stable 0.55/0.56 line), built by **forking Omarchy's architecture — not its
branding**. Omarchy's Quickshell-unified shell (replacing the traditional waybar/walker/mako/hyprlock
pile with one IPC'd process + plugin manifest) and its Limine+Snapper install flow are the closest
existing product to "polished, opinionated, snapshot-recoverable Hyprland OS." Mine **HyDE** for modular
theming-layer patterns, **JaKooLit** for portability reference if the base distro ever changes.

**GPU driver**: default **i915** (Xe is only the default on Lunar Lake/Battlemage-class hardware as of
2026); treat Xe as opt-in, tracked via the rolling base distro's current kernel/Mesa.

**Watch-list bugs for the Intel-iGPU target** (none are blockers, all need explicit test coverage):
i915 lid-suspend/resume panel wedge on Hyprland/aquamarine (open upstream issue), idle GPU usage during
mouse movement, VRR+tearing-simultaneous stutter.

Full detail: `docs/research/distro-hyprland-intel.md` §2-3.

## 4. Recovery model

**Decision: Snapper + snap-pac + limine-snapper-sync + Btrfs Assistant** — literally CachyOS's own
default stack. TorchOS's job here is verification/tuning, not new plumbing:

- Automatic pre/post-pacman-transaction snapshots (snap-pac), zero configuration.
- Boot-menu rollback (limine-snapper-sync) — a deliberate **two-step "boot into read-only snapshot,
  then `snapper rollback` to commit" flow**, not one-click. This is a safety feature (inspect before
  commit prevents an accidental snapshot-boot from silently becoming permanent) and should be reflected
  in the UX/docs rather than fought.
- Named checkpoints need no new tooling: `snapper create -d "<label>" -u important=yes` (the
  `important=yes` flag exempts it from routine pruning) — this is the exact call the AI assistant makes
  before any mutating privileged action.
- Btrfs snapshots and dotfiles/rice git history (§5) are **deliberately separate mechanisms** — coarse
  whole-subvolume safety net vs. fine-grained labeled config history. Conflating them either makes
  config-undo too blunt or makes Snapper responsible for things it can't express.

Timeshift is explicitly not used (redundant, non-Arch-native subvolume assumptions, no pacman-hook
integration — would create a second history to reconcile).

Full detail: `docs/research/snapshot-rollback-dotfiles.md` §1-2, 4.

## 5. Configuration/state model ("ricing as system state")

**Decision: chezmoi** for dotfiles/rice, kept deliberately separate from Btrfs snapshots (§4). The
deciding factor for an AI-editable rice: `chezmoi diff` is a **mandatory preview** before anything
touches a real dotfile — no compared alternative (GNU Stow, yadm, standalone Home Manager) gates writes
like this. Config lives as plain/lightly-templated files an AI can read/grep/edit with ordinary file
tools, unlike Home Manager's Nix-DSL round-trip. Git-backed source dir makes "undo yesterday's rice
tweak" a two-command, inspectable operation (`git revert` + `chezmoi apply`).

**User-data vs. system-state separation**: standard XDG Base Directory conventions — `$XDG_CONFIG_HOME`
is chezmoi-managed, `$XDG_CACHE_HOME`/`$XDG_DATA_HOME` stay untracked. No custom `/torch`-branded
filesystem layout (explicitly ruled out — conventional Linux paths make compatibility easier and don't
serve branding at the cost of confusing every other tool that expects XDG).

Full detail: `docs/research/snapshot-rollback-dotfiles.md` §3.

## 6. Compatibility model — the `torch install` resolver

**Decision**: a fixed, explainable priority ladder, modeled on Bazzite's documented install hierarchy
(the closest real precedent found — though no existing tool does this exact cross-ecosystem
auto-arbitration as a runtime decision engine, making it genuine TorchOS differentiation, not
reinvention):

1. **pacman** (official repos) — always first when present.
2. **Flatpak (Flathub)** — default landing zone for GUI apps not in core repos.
3. **AUR, gated** — only when neither above has it; mandatory PKGBUILD diff against last-known-good,
   orphan/maintainer-change flagging, never silent/`-noconfirm`. This is not theoretical caution: a 2026
   campaign ("Atomic Arch") hijacked 400+ *orphaned* AUR packages via the AUR's normal ownership-transfer
   process to plant credential-stealing malware. AUR can never be a silent or first-choice path.
4. **Distrobox/toolbx** — foreign package manager, incompatible toolchain/glibc, or isolation need.
5. **AppImage** — only when distributed solely that way; torch handles desktop integration.
6. **Wine ecosystem** — triggered by "this is a Windows binary," not chosen among Linux options. Bottles
   for general apps, Proton/Steam for Steam-library games, Lutris for community-scripted installs,
   isolated per-app prefixes.

Every install decision is logged with source + reason — doubles as UX explanation and audit trail.
Known edge cases to design around (Flatpak theming under Hyprland, AUR trust decay, duplicate installs
across sources, GUI/CLI split apps, gaming-performance-sensitive Wine placement): see appendix.

Full detail: `docs/research/compat-privilege-broker.md` Part 1.

## 7. Privilege boundary: `torchd`

**Decision**: `torchd` is a **polkit-actions-shaped daemon**, not a sudo/doas wrapper. Typed operation
classes (`system.service.restart`, `package.install`, `snapshot.rollback`, `network.dns.set`, …) served
over a Unix domain socket (`root:torch-agent`, mode 0660, **SO_PEERCRED-verified** as a second layer
beyond file permissions — a world-connectable socket with only SO_PEERCRED trust is a real, exploited
CVE pattern, not a hypothetical). Wraps existing D-Bus surfaces rather than reimplementing them:
systemd (`org.freedesktop.systemd1`/`network1`/`resolve1`) and PackageKit for package operations. The
one confirmed gap with no existing D-Bus API anywhere: **Btrfs snapshot rollback** — `torchd` hand-builds
and most carefully validates that one operation class, since no existing daemon layer is already doing
that validation.

`torchd` itself is hardened as the standing privileged target it is: `NoNewPrivileges=true`,
`ProtectSystem=strict`, `PrivateTmp=true`, a minimal per-operation `CapabilityBoundingSet` (not a
blanket root service), scored against `systemd-analyze security`. PwnKit (CVE-2021-4034) and a 2026
Debian polkitd regression are treated as reminders that the broker is also just software that gets CVEs.

**Reference to study directly before finalizing**: Alibaba Cloud Linux 4 "Agentic Edition" (ANOLISA,
open-sourced 2026) — a near-exact precedent for this whole premise (NL shell + security-policy core +
observability/audit layer + rollback + multi-level approval), open source at `github.com/alibaba/anolisa`.

**Structural anti-injection design** (enforcement lives in `torchd`'s policy logic, never in "the model
decided to be careful" — anchored directly in the Replit production-database-deletion incident, whose
lesson is "prompts are not access controls"):
- A **denylist that always wins** regardless of any autonomy/confidence setting (Warp's pattern) —
  bootloader/partition changes, deleting the last-known-good snapshot, disabling the broker itself: always
  human-gated, no exceptions.
- Untrusted content (logs, package metadata, filenames, web content the assistant reads) is
  provenance-tagged/screened before it re-enters the assistant's context.
- The operation surface itself is the enforcement boundary (per the ActPlane paper's argument) — even a
  fully-injected assistant session should be structurally unable to exceed what an operation's own policy
  allows.

Full detail, including systemd D-Bus specifics and the Docker-socket anti-pattern to avoid: `docs/research/compat-privilege-broker.md` Part 2.

## 8. AI / Claude boundary

**Decision**: Claude Agent SDK, run as a long-lived local daemon, with a custom MCP server exposing
`torchd`'s operation classes as typed tools. Not shelling the Claude Code CLI per invocation (cold-start
latency and lost session context on every `SUPER+SPACE` press is unacceptable), not a hand-rolled
Messages-API loop (reinvents what the SDK already provides). Deterministic requests (open Firefox) never
reach the model — the HUD routes those directly.

**Auth/billing** (verified against primary source, not assumed): the Agent SDK can run under the user's
existing Claude Code subscription rather than console/API-key billing. This draws from a **separate
monthly credit specific to Agent-SDK/`claude -p` usage** — distinct from, and not competing with, normal
interactive coding-session usage. That credit is finite: it "drains first," and the article documenting
this does not state whether exhaustion falls back to metered billing or simply stops requests until the
monthly refresh. **Design requirement**: degrade gracefully on credit exhaustion (tell the user plainly,
with the reset date, rather than silently switching to metered billing or failing opaquely). Exact
authentication setup steps and whether there's any restriction specific to *unattended/background* use
(as opposed to a human running `claude -p` interactively) are unconfirmed by any source found — **open
item to verify directly against current docs at Phase 3**, not before.

**Verification discipline** (directly informed by the FableOS and Antigravity research): the agent that
proposes or writes a fix is never the sole judge that it's correct and complete. Borrow the
builder/reviewer/adversarial-auditor separation — actual non-LLM checks (service health, boot success,
snapshot diff) are the mechanism of record; LLM review is a supplement, not the verification itself. This
matters doubly for TorchOS: once for the assistant's live system repairs, and once for how Claude Code
sessions building TorchOS itself should be reviewed (see `docs/research/fableos-antigravity.md`,
whose lesson — that Google's own Reviewer/Critic/Auditor split still didn't stop agents from "appearing
to cheat" — is that role-separation alone is not sufficient without grounded, non-LLM verification).

**Audit log**: structurally separate from assistant narration (mirroring FableOS's one genuinely strong
idea) — `torchd` emits its own append-only log of what it actually did, in a format the assistant's own
chat output can never spoof, suppress, or be confused with.

Full detail: `docs/research/claude-code-integration.md`.

## 9. Installer strategy

**Decision**: two-layer split, avoiding both v1 failure modes (a fragile manual Cubic remaster, and a
from-scratch installer reinventing partition/bootloader/encryption logic that already exists, hardened,
elsewhere).

1. **Disk/base-OS layer**: fork CachyOS's own `cachyos-calamares` configuration. It already lays out
   Btrfs subvolumes matched to snapper/limine-snapper-sync's expectations, and Calamares is explicitly
   designed for downstream rebranding without patching core code.
2. **Desktop-provisioning layer**: an Omarchy-style scripted provisioner, studied directly from
   `omarchy-iso`'s Docker-based reproducible build pipeline, installs/configures Hyprland/shell/dotfiles/
   theming on top once Calamares finishes.

Full detail: `docs/research/distro-hyprland-intel.md` §4.

## 10. Repo discipline going forward

Adopted directly from the VibeOS research (the one genuinely reusable finding from that project — not
its kernel): `CLAUDE.md` opens with hard trust-boundary imperatives before any technical content, keeps
a "locked" decisions table (this document) separate from exploratory history, a living checkbox status
list, and a gotchas list — lightly categorized by subsystem from the start (broker / snapshots /
Hyprland / Intel-gfx / AI-agent), since TorchOS's surface area is broader than a single kernel project.
Session/iteration logs are terse decision records (goal → tried → broke → resolved), not prose. The one
explicit anti-pattern to design against: VibeOS's own session-log index file silently drifted out of
sync with the per-session files it summarized — any index TorchOS keeps must be checked/regenerated, or
skipped in favor of linking straight to a log directory.

Full detail: `docs/research/simpleos-vibeos.md`.

## 11. Legacy v1 disposition

Whole v1 tree moved to `legacy/v1/` via `git mv` (preserves history) as part of this same change.
Retain/discard rationale recorded in `legacy/v1/README.md`; summary:

| Retained (as reference/pattern) | Discarded (superseded) |
|---|---|
| "CLI is the source of truth, GUI wraps it, no independent state" principle | Raw `btrfs.rs` subvolume shell-outs → superseded by Snapper/snap-pac |
| `torch-cli`'s clap project layout as a starting skeleton for the new `torch` binary | GTK Labs GUI/HUD → Labs-specific, superseded by a Quickshell-based HUD forked from Omarchy |
| `docs/` writing style/structure | Cubic ISO scripts → superseded by the Calamares fork (§9) |
| `assets/logo.png` + `ui/theme/` orange/ember palette — **kept as-is for now** (user decision, 2026-08-24) | Docker devcontainer approach → superseded by the QEMU/KVM VM target |
| | `gpu_detect.rs`'s raw `nvidia-smi` shelling → wrong vendor (Intel target) and superseded by the structured diagnostics layer |

## 12. Risks / open items

- **Agent SDK unattended-use behavior** (§8) is unconfirmed by any source — verify before Phase 3, design
  the daemon to fail visibly/gracefully rather than assume either outcome.
- `torchd`'s hand-built `snapshot.rollback` validation (§7) is the single highest-scrutiny piece of code
  in this design — no existing daemon layer to lean on for it.
- CachyOS's custom-repo/kernel delta isn't covered by the ArchWiki corpus an LLM would otherwise lean on
  for troubleshooting — needs TorchOS-authored notes over time, not a one-time gap to close.
- Flatpak theming under Hyprland (no portal-integrated theme daemon outside GNOME/KDE) is a known,
  recurring rough edge `torch install` needs to actively paper over.
- This machine's RAM is tight (7.4GB total, observed already under real memory pressure with active
  swap use) — the Phase 1 VM must use a conservative allocation (~3GB), not v1's old `-m 8G` default,
  and Phase 1 execution should be mindful of host memory headroom throughout.

## 13. Staged plan

Phase 0 (this document) → **Phase 1 (next)**: VM bootstrap milestone — CachyOS in QEMU/KVM with
virtio-gpu/virgl acceleration, Omarchy-fork Hyprland desktop, a `torch` CLI skeleton, Btrfs snapshot
wiring verified, basic structured diagnostics, no `torchd`/AI yet → Phase 2: `torchd` + polkit action set
→ Phase 3: AI assistant (Agent SDK + MCP) wired to `torchd`, with the auth/billing open items from §8
resolved → Phase 4: `torch install` compatibility resolver → Phase 5: Calamares installer fork →
Phase 6: real Intel-iGPU hardware validation.

---

## Self-review (brainstorming skill checklist)

- **Placeholder scan**: no TBD/TODO markers; every decision above has a stated rationale and a named
  fallback where one exists (§2, §3 GPU driver, §4 bootloader tooling).
- **Internal consistency**: §4 (Btrfs snapshots) and §5 (chezmoi) explicitly cross-reference their
  boundary rather than leaving it implicit; §7 (`torchd`) and §8 (AI boundary) explicitly agree on where
  enforcement lives (the broker, never the model). No section contradicts another.
- **Scope check**: this document covers the whole v2 architecture (as requested), but §13 explicitly
  scopes the *next* implementation plan to Phase 1 only — the VM bootstrap milestone — matching the
  project owner's own stated "first usable milestone is not a custom ISO" framing. Appropriately focused
  for a single implementation plan to follow.
- **Ambiguity check**: the one item that could read two ways — whether Agent SDK unattended use is safe
  — is explicitly flagged as unverified in both §8 and §12, not silently assumed either direction.

## Next steps

1. A brief owner glance at this document (checkpoint, not a hard multi-day gate).
2. Invoke `writing-plans` for a Phase 1 implementation plan scoped to §13's first phase.
3. Execute it.
