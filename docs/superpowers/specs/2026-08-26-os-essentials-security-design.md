# TorchOS v2 — OS-Essentials & Security — Design

Status: **approved by user 2026-08-26**, pending written self-review below.
Author: Claude (Sonnet 5), in conversation with the project owner.
Parent doc: `docs/superpowers/specs/2026-08-24-torchos-v2-architecture-design.md` (locked architecture —
this **extends** §7 `torchd` and §8 the AI boundary with implementation-ready detail; it does not
re-litigate either). Sources verified directly against upstream, not assumed — fetched and read, not
summarized from memory: `github.com/CachyOS/CachyOS-Settings`, `github.com/CachyOS/CachyOS-PKGBUILDS`,
`github.com/alibaba/anolisa`, the owner's own private `github.com/VectorSophie/A3V`, and Linux Mint
(Update Manager, ufw/gufw, the Mint installer, `mintBackup`) via web research.

## 1. Scope

Six areas, user-requested to be researched against real prior art rather than designed from scratch:
kernel/memory tuning, updates policy, firewall, disk encryption, personal-data backups, and a concrete
refinement of `torchd`'s already-locked design (autonomy tiers, a danger model, an audit-log format) —
plus one small verification-only item (PQC). Disk encryption is recorded here as a **Phase 5 decision**,
not actionable against the already-installed Phase 1 VM — flagged explicitly so it isn't silently
dropped, not because it needs more design.

## 2. Kernel & memory tuning

**Decision**: adopt `cachyos-settings` and `cachyos-ksm-settings` as-is. This is very likely closing a
gap, not adding new tuning — Phase 1's VM was built via manual `pacstrap` after `archinstall` was killed
early (see the `install` Gotcha in `CLAUDE.md`), which means it almost certainly never got the tuning a
normal CachyOS install ships by default. Same reasoning the locked spec used to pick CachyOS in the
first place (§2: prefer mature, already-maintained infrastructure over reinventing it).

- **`cachyos-settings`** — real content verified from `usr/lib/sysctl.d/70-cachyos-settings.conf` and
  `usr/lib/udev/rules.d/30-zram.rules`: `vm.swappiness=100`, `vm.vfs_cache_pressure=50`, dirty-page/
  writeback tuning (`vm.dirty_bytes=268435456`, `vm.dirty_background_bytes=67108864`,
  `vm.dirty_writeback_centisecs=1500`), `vm.page-cluster=0`, NMI watchdog off, `kernel.printk=3 3 3 3`
  (quieter boot), `kernel.unprivileged_userns_clone=1` (needed for rootless containers/Distrobox, per
  the compat ladder), `kernel.kptr_restrict=2` (kept as-is — this is CachyOS's own hardening default,
  **not being loosened** here), plus a udev rule bumping `vm.swappiness` to 150 specifically once zram
  activates. Also pulls in `ananicy-cpp` + `cachyos-ananicy-rules` — an auto-nice daemon that reprioritizes
  known apps by a rules database, genuinely "personal usage performance" with zero manual tuning.
- **`cachyos-ksm-settings`** — enables Kernel Samepage Merging at boot via a oneshot `ksmd.service`
  (`WantedBy=multi-user.target`), plus `MemoryKSM=yes` service overrides that include `getty@.service.d`
  and `user@.service.d` — both apply directly to TorchOS's actual tty1-autologin setup (no display
  manager). Memory-page deduplication is a direct, low-risk answer to this project's own recurring
  "tight RAM" constraint.

**Explicitly not adopted**: `cachyos-hyprland-settings` — it's a competing opinionated Hyprland bundle
(pulls in `swaylock`/`bemenu`/a Nord GTK theme, conflicting with Group A's Omarchy-forked stack and the
locked orange/light palette) — and no sysctl loosening beyond what `cachyos-settings` itself already
ships (e.g. `kptr_restrict=0`, relaxed `ptrace_scope`) — that direction is a security trade, not a
performance one, and isn't bundled in silently.

**Optional/stretch, not core**: CachyOS's default kernel has `CONFIG_SCHED_CLASS_EXT` built in, so
`scx_*` CPU schedulers are swappable at runtime without a reboot via CachyOS's own Kernel Manager.
Real and available; ranked low per the locked priority order (Novelty is last) — worth a follow-up
`torch` subcommand later, not part of this spec's core deliverable.

## 3. Updates policy

Mint's Update Manager tiers packages by risk and deselects risky/kernel-adjacent tiers by default. TorchOS
doesn't need that machinery: **snap-pac's automatic pre/post-transaction snapshots (locked, §4) already
cover the failure mode Mint's tiering exists to prevent** — a bad update is a rollback away regardless of
which tier it was in. What's worth keeping from Mint, translated to pacman's own native mechanisms rather
than reinvented:

- `torch update` = `pacman -Syu`, wrapped with the mandatory pre-update snapshot (already the trust-
  boundary rule, not new here) and a plain heads-up when a kernel package is part of the transaction —
  still the single highest-impact package class even with rollback available.
- A blacklist via pacman's own `IgnorePkg`/`IgnoreGroup` in `pacman.conf` (wildcards included natively),
  not a parallel TorchOS-specific mechanism.
- Worth noting: GRUB (already the bootloader, per the `bootloader` Gotcha) plus CachyOS shipping kernel
  packages that coexist rather than replace in-place means an older kernel is still selectable from the
  boot menu if a new one regresses — strictly better recoverability than Mint's opt-in-tiering for the
  kernel case specifically, with no extra work needed to get it.

## 4. Firewall

Real, verified Mint behavior: `ufw`/`gufw` ship pre-installed but **not enabled by default** — their own
stated reasoning is that a system with no listening services has nothing for a firewall to protect yet,
and enabling-by-default just adds friction without a matching risk reduction. That reasoning transfers
directly: `torchd`'s socket is Unix-domain (§7, not network-facing at all), and Phase 3's AI daemon/MCP
server is local-only per the locked design (§8) — TorchOS introduces no new listening surface either.

**Decision**: mirror Mint exactly — `ufw` + `gufw` installed, a default-deny-incoming/default-allow-
outgoing profile pre-loaded, the service left **off** by default. One deliberate improvement over Mint,
not a deviation from its reasoning: surface firewall state (`ufw status`) in `torch doctor` and
`torch-welcome` so it's visible rather than silently forgotten — Mint's own tooling doesn't do this.

## 5. Disk encryption

**Recorded for Phase 5, not actionable now.** Mint's installer offers LUKS as an opt-in checkbox
(whole-disk or partition) at install time — Calamares, TorchOS's already-chosen installer fork target
(§9 of the locked spec), has the exact same opt-in-checkbox flow built in as a standard module. The
current Phase 1 VM is already installed unencrypted and can't be retrofitted without a reformat, so
there's nothing to do today. This section exists so the decision (mirror Mint: opt-in, not on-by-
default, via Calamares's own module — no custom encryption UI needed) is on record and doesn't get
dropped by the time Phase 5 actually starts.

## 6. Backups (personal data)

Distinct from Snapper, which is already locked (§4) and covers whole-subvolume, same-disk, system-state
rollback — deliberately not conflated with this, the same way the locked spec already separates Snapper
from chezmoi (§4: "Btrfs snapshots and dotfiles/rice git history are deliberately separate mechanisms").
This section is about **personal data** (documents, projects, anything the user would actually mourn),
and specifically about a copy that survives the *disk itself* dying — something no same-disk Btrfs
snapshot can ever protect against.

Mint's real tool here (`mintBackup`) is simple by design: tar the home directory to a user-chosen
destination, plus a separate "software selection" export (the list of explicitly-installed packages,
for an easy reinstall). TorchOS translation, CLI-first rather than GUI-only (matching the project's own
CLI-first philosophy, and pacman's own native mechanism rather than a custom one):

- `torch backup <destination>` — tars user-selected directories (default: `$XDG_DATA_HOME` and anything
  else the user names) to `<destination>`, plus writes `pacman -Qqe` output (the explicit-package list)
  alongside it.
- No automatic enforcement that `<destination>` is actually off-disk — that's on the user. A
  `torch doctor`/`torch-welcome` nudge if no backup has ever been run is a reasonable low-cost addition,
  not a blocker for this spec.

## 7. `torchd` refinement (extends locked §7/§8 — Phase 2/3 implementation-ready detail)

Grounded in two real references, not one: **ANOLISA** (Alibaba Cloud Linux 4 Agentic Edition, the
locked spec's own "study before finalizing" reference, actually done now) and the owner's own **A3V**
(Agent Attack & Abuse Adversarial Vaccine) — a real, working AI-agent-security benchmarking and defense
project, directly on-topic for "denying agents."

**Autonomy tiers** (from ANOLISA's `cosh` shell, verified from `docs/.../shell/approval.md`): three
modes — **Recommend** (explain/suggest only, no `torchd` calls emitted), **Auto** (default; low-risk
operation classes run without asking, risky ones ask first), **Trust** (mutating operations run
automatically after one-time session confirmation). In all three, **the hard denylist from the locked
spec still always wins** — ANOLISA enforces exactly this same invariant for its own irrecoverable-command
list (`reboot`/`shutdown`/`halt` require approval even in Trust mode), which is real-world validation of
what §7 already specified, not a new claim.

**Danger-tier ladder** (from the owner's own A3V, `docs/threat_model.md` — A3V's "Tool Escalation"
category): `memory.read → memory.write → file.read → file.write → file.delete → shell.exec`. This is
the concrete answer to a question ANOLISA's own docs leave unstated (what actually counts as "low-risk"
vs. "risky" for the Auto tier) — mapping this ladder onto `torchd`'s actual typed operation classes
(`system.service.restart`, `package.install`, `snapshot.rollback`, `network.dns.set`, …) gives Auto mode
a principled, named criterion instead of an ad hoc one. The exact per-operation-class mapping is a
Phase 2 implementation-plan detail (§9), not fully enumerated here, since it depends on `torchd`'s final
operation-class list.

**Canary values** (from A3V's Vaccine Guard, `docs/vaccine.md`): synthetic values — fake credentials,
fake tokens — that should never legitimately appear in any `torchd` operation-class argument or MCP tool
output. `torchd` watching for them at the point of execution is a hard, binary signal of a compromised or
injected session, not a heuristic judgment call. This is a genuinely new addition beyond what the locked
spec currently has, not a restatement of it. Where planted canaries live and exactly what checks for them
is a Phase 2 implementation-plan detail (most likely `torchd` itself, at the same point it validates any
operation-class call).

**Audit log format**: JSONL, one event per line, append-only — matching A3V's own
`.a3v/vaccine.jsonl` convention (simple, greppable, trivially tail-able). This pins the concrete format
for the audit log the locked spec already requires (§8) but didn't specify a format for.

**Persistent AI-daemon memory — new consideration, Phase 3**: A3V's threat model names "Memory
Poisoning" (category 2) and "Delayed Trigger" (category 5) as distinct attack classes — content read
during one interaction becoming a standing instruction that fires later, without the user repeating it.
The locked spec's "provenance-tag untrusted content" principle (§7) already anticipated this in spirit,
but Phase 3's daemon is explicitly long-lived with its own session/memory state (§8) — meaning whatever
it persists across sessions needs the *same* provenance discipline already applied to a single request,
not just at the point of first reading untrusted content. Flagged here as a Phase 3 design requirement,
not solved in this spec.

**Deliberately retained, not changed**: `torchd` exposes zero raw shell/command execution — only a
closed, enumerable set of typed operation classes. ANOLISA, by contrast, still pattern-classifies
*arbitrary* sandboxed shell commands (`CommandClassifier`, deny/sandbox/allow by risk pattern). `torchd`'s
approach is narrower and arguably stronger — there's no "unclassified command" gap that can exist in a
closed operation-class model the way it can in a pattern-matched one. This is a deliberate departure from
the reference architecture, recorded explicitly so it doesn't read as an oversight later.

## 8. PQC (verification only)

OpenSSH 10.0+ (April 2025) defaults to `mlkem768x25519-sha256` hybrid post-quantum key exchange with no
configuration needed; CachyOS is rolling-release and almost certainly already ships it. **Decision**: add
an `openssh_pqc` check to `torch doctor` (OpenSSH version ≥ 10.0, confirms PQC-hybrid KEX is actually
negotiated, not just installed) — a verification item, not new cryptographic code. `torchd`'s own socket
is local Unix-domain, not network, so it has no PQC surface at all. **QKD is ruled out** — it requires
photonic hardware no PC has access to; recorded here so it isn't re-raised later without new information
changing that fact.

## 9. Risks / open items

- The VM wasn't running during this brainstorm, so `cachyos-settings`'s actual absence is inferred from
  the install method (manual `pacstrap`, not a full CachyOS install), not directly confirmed. First real
  implementation step must check (`pacman -Q cachyos-settings`) before assuming it's missing.
- The danger-tier-ladder-to-operation-class mapping (§7) is a first-pass adaptation of a generic tool
  taxonomy (A3V's) to `torchd`'s specific operation classes — worth a real second look once Phase 2's
  implementation plan finalizes that class list, not treated as final here.
- Canary-value placement/checking mechanism (§7) is named but not fully specified — where they live and
  what checks for them is left to the Phase 2 implementation plan.
- `torch backup`'s destination has no automatic off-disk enforcement (§6) — a `torch doctor` nudge is
  proposed but not a hard requirement; acceptable given the priority order (Convenience first).
- This spec assumes Phase 2 (`torchd`) is the next phase to actually implement, since §7's refinements
  are what make it implementation-plan-ready — but §2–§6 (kernel tuning, updates, firewall, backups) are
  VM-provisioning-level work that could reasonably run alongside or before Group A's own implementation
  plan. Sequencing across the resulting implementation plans is a decision for after this spec is
  reviewed, not fixed here.

## Self-review (brainstorming skill checklist)

- **Placeholder scan**: no TBD/TODO markers. The three items in §9 flagged as "left to the Phase 2
  implementation plan" are genuine implementation-level decisions (exact operation-class danger mapping,
  canary placement mechanism) — the design constrains their outcome (must reuse the named ladder; must be
  checked at `torchd`'s point of execution) without over-specifying mechanism, matching how the Group A
  spec treated its own open items.
- **Internal consistency**: §6 explicitly cross-references its boundary with the locked §4 (Snapper) the
  same way the locked spec cross-references chezmoi/Snapper — no silent overlap. §2's exclusions (no
  `cachyos-hyprland-settings`, no further sysctl loosening) are stated with reasons, not just declared.
  §7's "deliberately retained" note explicitly reconciles `torchd`'s design against ANOLISA rather than
  leaving the divergence implicit.
- **Scope check**: §5 (disk encryption) is explicitly marked not-actionable-now rather than either being
  silently dropped or over-designed for a phase that hasn't started. §7 is scoped to refining the already-
  locked `torchd`/AI-boundary sections, not redesigning them from zero.
- **Ambiguity check**: §3's "blacklist" and §4's "firewall profile" both name the exact real mechanism
  (`IgnorePkg`/`IgnoreGroup`; ufw default-deny-incoming/default-allow-outgoing) rather than a vague
  category, removing the "which mechanism exactly" ambiguity for whoever writes the implementation plan.

## Next steps

1. Owner reviews this file (alongside the still-pending Group A spec).
2. Invoke `writing-plans` — likely two plans (Phase 2 `torchd` per §7; a VM-provisioning plan for
   §2–§6), sequencing decided at that point, not here.
3. Execute, with the trust-boundary/verification rules enforced throughout, not just stated.
