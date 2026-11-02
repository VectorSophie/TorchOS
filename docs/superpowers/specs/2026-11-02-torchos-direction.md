# TorchOS — Direction for the next development cycle

Status: **proposed, awaiting owner approval** (2026-11-02). Planning only: nothing in this document has
been implemented. Where it disagrees with `2026-08-24-torchos-v2-architecture-design.md` or the
"Locked decisions" table in `CLAUDE.md`, this document records why, and the locked table should only be
updated once this is approved.

Author: Claude (Opus 5.5), working from the repository at `e39ac7b` and the sources listed at the end.

---

## 0. The short version

TorchOS today is a working, installable Arch Linux desktop. It has been demonstrated end to end in exactly
one environment, a QEMU/OVMF virtual machine. Its most original part is not the desktop. It is a small
privileged broker (`torchd`) plus a recovery path that was verified across a reboot. Everything else is
careful integration of existing tools.

The strongest direction is to make that original part the reason Torch exists:

> **Every change to the system is a plan you can read before it happens and a record you can read after.
> Recovery starts from understanding what changed.**

This is a narrow, Wasabi-sized goal for a distribution. It doesn't need a new kernel, a new package
manager or a new shell. It does need `torchd`, the installer and the recovery tooling to share one
discipline: **plan → confirm → apply → verify → record**. The desktop's job is to make that discipline
pleasant. The optional local agent's job is to help explain it. Neither should replace it.

What should change, in order of importance:

1. Several things the installer offers today (LUKS, manual partitioning, ext4/xfs, BIOS) are untested.
   At least one, encryption, is very likely to produce an unbootable system. Hide them until they're tested.
2. `torchd` confirmation is self-attested: the client that asks is handed the token that confirms. Some
   mutating operations don't ask at all under the fixed `Auto` tier. That's fine for a human at a terminal
   and not fine for any automated client. The privileged contract needs daemon-generated plans and an
   authorization step bound to the exact plan (§4.2). Polkit can supply part of that, not all of it.
3. Snapshot retention has unbounded paths: manual checkpoints are never cleaned up, and pre-rollback roots
   are invisible. Rolling back *from* a booted snapshot, which `torch doctor` recommends, almost certainly
   fails.
4. `torchd` records what it did only after it finishes. An interrupted operation leaves no trace.
5. Then real hardware, then the visual redesign, then the agent.

---

## 1. Where TorchOS actually is

### 1.1 What has been demonstrated

Everything below was observed in QEMU/OVMF on a blank virtual disk, driven by `image/scripts/dev/`, with no
manual patching inside the guest (`docs/handoff.md` §1, `docs/known-issues.md`). None of it has run on
physical hardware.

| Area | What was shown |
|---|---|
| Build | Package manifests resolve against Arch; split PKGBUILD builds 7 packages; repo signed with an ed25519 key; ISO build refuses unsigned or stale repos |
| Live ISO | UEFI boot, Hyprland + Waybar + `torch-welcome`, Calamares opens, `torch doctor` green |
| Install | Calamares erase-disk to Btrfs (`@ @home @log @cache @snapshots`), GPT, GRUB; ~5 min |
| Installed system | Boots without ISO, greetd/tuigreet login, GRUB defaults to `linux`, `linux-lts` fallback, doctor exit 0 |
| Updates | `torch update` through `torchd` against the signed `[torchos]` repo; hosted repo on GitHub Releases verified with a clean-container `pacman -Sy` |
| Packages | `torch install` via repo, AUR (`--aur`, PKGBUILD shown), AppImage, Distrobox |
| Snapshots | snap-pac pre/post pairs on every pacman transaction through `torchd`; manual checkpoints |
| Recovery | checkpoint → change → `torch snapshot rollback N` → reboot → change gone, `/home` kept |
| Boot recovery | GRUB *TorchOS snapshots* submenu boots a snapshot on a temporary overlay |
| Kernel layer | `torch kernel add linux-cachyos` installs and boots the CachyOS kernel |

The verification discipline deserves credit. Claims were checked by observing outcomes (file reverted,
`pacman -Q`, `ActiveEnterTimestamp` changed), not by exit codes, and `docs/known-issues.md` doesn't
overclaim. Keep doing it that way.

### 1.2 Written but not demonstrated

- Flatpak install (only name resolution was exercised), `.exe/.msi` via Wine, `.rpm` via a Fedora box.
- Anything on physical hardware: suspend/resume, Wi-Fi, audio, brightness, batteries, external displays.
- NVIDIA, Secure Boot, BIOS installs, LUKS, manual partitioning, dual boot, non-English installs (Korean
  input packages are in the manifest; never exercised).
- Rolling back *from inside* a booted snapshot (see 1.4).
- Long-term behavior: weeks of real updates, snapshot growth, Arch manual-intervention news items.

### 1.3 Decisions that changed during implementation

All but one of these were recorded honestly when they happened. The "Locked decisions" table in
`CLAUDE.md` hasn't caught up with most of them.

| Original intent (2026-08-24 spec) | What was built | Assessment |
|---|---|---|
| CachyOS base | Signed Arch repos + `[torchos]`; CachyOS kernel as an opt-in layer (`docs/decisions/0001`) | **Keep.** Honest lineage (`ID_LIKE=arch`), fewer moving parts, kernel layer verified |
| Limine + limine-snapper-sync | GRUB + grub-btrfs (`docs/decisions/bootloader.md`) | **Keep.** Snapshot boot verified; Limine reproduced a real install failure |
| Fork `cachyos-calamares` | Own Calamares config + `torch-target-setup`, no fork | **Keep** |
| torchd wraps systemd D-Bus + PackageKit | Shells out to `pacman`/`systemctl`/`snapper`/`btrfs`, isolated in `torchd/src/ops/` | **Keep.** PackageKit on Arch is a weak abstraction; shell-outs are explicit and testable |
| `ProtectSystem=strict`, minimal capabilities | Partial hardening, every omission documented in the unit | **Keep**, rescore with `systemd-analyze security` after changes |
| `snapper rollback` | Hand-built `@` swap (`snapper rollback` assumes SUSE's default-subvolume layout) | **Keep and harden** (§4.3) |
| Omarchy-fork Quickshell shell | Plain Hyprland + Waybar + Wofi + Mako | **Open** (§4.6). Omarchy has since moved to Quickshell |
| Claude Agent SDK + MCP | Not started | **Replaced** by an optional local agent (§4.7) |
| `cachyos-settings` sysctl bundle, `ufw` firewall (os-essentials spec) | Neither implemented | Sysctl bundle **rejected**: unmeasured. Firewall: **open**, small |
| chezmoi "mandatory diff-before-apply" | Dotfiles copied into `/etc/skel` by `torch-config`; chezmoi source shipped but not used by anything | **Replace the mechanism** (§4.6). The decision is nominal today |

### 1.4 Defects and gaps found in this audit

These come from reading the code. None were reproduced, because this session ran no VMs. Each needs a
reproduction before it's fixed, and the fix needs the same kind of test.

1. **Encrypted installs are very likely unbootable.** `partition.conf` sets
   `enableLuksAutomatedPartitioning: true`, so Calamares shows an encryption checkbox. But
   `torch-target-setup` writes `HOOKS=(… block filesystems fsck grub-btrfs-overlayfs)` with no `encrypt`
   hook. `/boot` lives inside the encrypted `@`, and nothing sets `GRUB_ENABLE_CRYPTODISK`. There is no
   tested encrypted-boot path at all, whatever GRUB's LUKS capabilities are (see §4.4). Manual
   partitioning and ext4/xfs are also offered. ext4/xfs installs silently skip Snapper (the script checks
   `findmnt -no FSTYPE /`), so they ship without the product's main recovery feature. The ISO also boots
   BIOS (`bios.syslinux`), but no BIOS install has ever been tested.
2. **Self-attested confirmation.** `torchd` returns `confirm_token` to the same client that made the
   request, and `torchd_client.rs` resubmits it after a stdin `y`. Binding the token to op, args and uid
   stops a client confirming something it wasn't shown. It doesn't show that a *human* saw anything. Any
   member of `torch-agent`, which `users.conf` gives to every user, can script a rollback or a root package
   install. That's acceptable while the only client is a person at a shell who could also type `sudo`. It
   has to change before any non-interactive client exists.
   Separately, `torchd` assigns every caller the fixed `Auto` tier (`main.rs`: `let tier = Tier::Auto`).
   Under it, `snapshot.create`, `package.install` (which runs a full `pacman -Syu`) and `system.upgrade`
   run with **no confirmation at all**. A future agent or any other non-human client must not inherit this
   authority. The tier has to be derived by `torchd` from who is calling, never requested by the caller,
   and agent-originated requests must never auto-approve a mutating operation.
3. **`torchd` can be stalled by one idle connection.** It serves one client at a time (deliberate:
   operations must not interleave), but `read_line` has no timeout. A client that connects and sends
   nothing blocks every other request indefinitely.
4. **Manual checkpoints are never cleaned up.** `snapshot.create` and the `kernel.install` checkpoint call
   `snapper create -d … -u important=yes` without `--cleanup-algorithm`. Snapper's cleanup only processes
   snapshots that have an algorithm set (snapper(8)), so these accumulate forever. snap-pac's pairs do get
   the `number` algorithm. `SPACE_LIMIT` also needs quota, which isn't set up, so space-aware cleanup is
   inactive (`FREE_LIMIT` doesn't need it). The effective config should be checked in the VM.
5. **Pre-rollback roots are invisible and unbounded.** Every rollback leaves `@.pre-rollback-<time>` on the
   top level. It doesn't appear in `torch snapshot list`, no operation deletes it, and doctor doesn't
   mention it. Each one pins a whole root's worth of extents.
6. **Rollback from a booted snapshot almost certainly fails.** Booted from GRUB's snapshot menu, `/` is an
   overlay. `rollback()` takes the device from `findmnt -no SOURCE /`, and the unit test itself asserts
   that `"overlay"` yields `None`, so the operation stops with "cannot determine the root device". Yet
   `torch doctor` in that state tells the user `Keep this state: torch snapshot rollback N`, and
   `docs/recovery.md` §5 repeats it. The verified part of §5 covers booting the snapshot, not this step.
7. **The `@` swap is not atomic and has no crash recovery.** It's a snapshot followed by two separate
   `rename(2)` calls (`@` → `@.pre-rollback-*`, then `@.rollback-new` → `@`). It is *not* one transaction.
   If a Btrfs transaction commit lands between the renames and power is lost, no `@` exists, and GRUB
   (prefix `/@/boot/grub`) drops to a rescue prompt. Nothing at boot detects or repairs that state. The
   window is small, but this is the one operation whose whole point is to be safe. There's also no
   explicit sync after "prepared" (a crash shortly after may silently undo the swap, which is the safe
   direction but is reported to nobody), and a stale `@.rollback-new` from an interrupted attempt makes
   the next rollback fail. This stays an open defect until §4.3's crash states each have a tested
   recovery.
8. **`grub.cfg` is regenerated in place.** `kernel.install` runs `grub-mkconfig -o /boot/grub/grub.cfg`
   directly. A failed or partial generation replaces the only menu. Libertix's lesson applies directly:
   generate a candidate, validate it, then atomically replace the last known good one.
9. **The audit log is after-the-fact only.** `torchd` writes one line after the operation completes. A
   crash or power loss mid-`pacman` leaves no record that anything was attempted. Request ids come from the
   client. The log has no rotation.
10. **Install steps fail soft.** `torch-target-setup` turns most failures into `echo WARN` and exits 0:
    services not enabled, Snapper config failed, keyring not populated. Calamares then reports success.
    That's the "success because the exit code was zero" pattern the project otherwise avoids. The fix is
    not "fail on everything". Some failures leave a system that won't boot, can't log in, can't trust its
    package repos, or lacks the advertised recovery path; those must fail the install. Others leave a
    working, recoverable system missing one convenience (Bluetooth, printing, zram), and should be
    recorded and reported, not fatal.
11. **No polkit authentication agent runs in the session.** `polkit-gnome` is in `desktop.txt`, but
    nothing autostarts it (no match anywhere in `dotfiles/` or the live profile). GUI apps that ask polkit,
    such as GNOME Disks or mounting internal drives in Nautilus, likely fail with "not authorized". That's
    unverified, and it also blocks fix 2.
12. **Torch's default configs never update after install.** `torch-config` copies the dotfiles into
    `/etc/skel`, which only applies when a user is created. A package update to the bar or keybinds never
    reaches an existing user.
13. **Contrast failures in the shipped theme.** White text on `#ff4500` (Waybar active workspace) measures
    3.44:1. `#ff6a00` on white (battery warning) measures 2.87:1. Both fail WCAG AA for 13px text.
    `#ff4500` on `#2b0a00` passes (5.33:1).
14. **No CI.** About 24 Rust unit tests and the VM harness, all run by hand.

### 1.5 What we reuse

Nearly everything. The repository is small (≈2,150 lines of Rust, plus shell and config) and coherent:

- `torch/torchd/` — the broker, policy table, name validation, token binding, audit writer and rollback.
  The base for Layer I; extended, not rewritten.
- `torch/src/` — CLI, `doctor` (typed checks, real exit codes), `diagnose` (JSON), `hardware`, the
  `install` resolver.
- `torch/torch-welcome/` — the GTK4 status window. It already follows the "GUI renders CLI JSON" rule
  (it parses `torch diagnose`), which is the pattern Layer II generalizes. Today only `torch diagnose`
  (always JSON) and `torch doctor --json` are machine-readable; every other command prints text and
  prompts on stdin. A stable structured interface across all commands is a **proposal** (§4.1), not
  existing functionality.
- `image/` — the Archiso profile, Calamares config, `torch-target-setup`, the build/sign/publish scripts,
  and the VM harness (`image/scripts/dev/`), which is the foundation of the verification plan.
- `packages/` + `scripts/check-manifests.sh`, `pkg/torchos/PKGBUILD`, the keyring.
- `docs/decisions/` (all three records stand), `docs/recovery.md`, `docs/known-issues.md`.
- `assets/branding/` — the mark and its size set survive the visual redesign; the palette is reconsidered.

---

## 2. What Torch is for

**TorchOS is an Arch-based personal desktop where you can always answer three questions: what changed,
why, and how do I get back.**

It serves people who want a finished-feeling Linux desktop they can actually change: install anything,
try a kernel, break their theme, update on a Tuesday. They want to do that without learning snapper's
subvolume model or reading the ArchWiki at 1 a.m. It also serves the experienced user who *does* want to
read the model. Every Torch action has a visible equivalent command, every record is plain JSON in a
known place, and nothing stops you from using `pacman` directly. Torch notices, and its records say so.

Why choose it over the alternatives?

- **Over plain Arch:** you get the same packages and wiki, and the same freedom. On top you get a tested
  install, recovery that works on day one, and a broker that won't run a destructive operation without
  showing you its plan.
- **Over CachyOS:** CachyOS optimizes for speed and ships the Snapper stack. Torch optimizes for
  *understanding*: plans, records, verified known-good states, a recovery UI that diffs before it rolls
  back. The CachyOS kernel is one command away.
- **Over Omarchy or HyDE:** those are excellent opinionated *desktops*, and their recovery and privilege
  story is "it's Arch". Torch is opinionated about the *system's behavior under change*. Its desktop
  matters, but it isn't the differentiator.
- **Over Bluefin, Aurora or Bazzite:** image-based systems buy reliability by narrowing what you can
  change. Torch keeps a mutable system with the AUR and gets recoverability from checkpoints and records.
  That's a different trade, chosen deliberately.

What Torch will not become: a kernel project, a package ecosystem, an immutable image distribution, a
theme collection, a chatbot with an OS attached, or a security product that blocks its owner. It also
won't be a list of borrowed features. If a mechanism doesn't serve "what changed, why, how back", it needs
a strong reason to be here.

**Proposed amendment to the priority order.** The old order (`Convenience > Compatibility > Reliability >
Recoverability > Security > Elegance > Novelty`) ranks security as something tradeable for convenience.
The owner's new framing says otherwise, and I agree: **security is a constraint every feature must
satisfy, not a rank.** Proposed: *Convenience > Compatibility > Reliability > Recoverability > Coherence >
Novelty, with security and owner control as constraints on all of them.* "Coherence" replaces "Elegance"
because the goal is one designed system, not prettiness.

---

## 3. What we can learn from elsewhere

The test for each reference: does a mechanism here solve a problem Torch actually has, and what would it
cost to keep?

### 3.1 Projects

**Wasabi** (`hikalium/wasabi`, MIT) is "a toy web browser + OS in Rust". The lesson isn't its code. It
picked one end-to-end goal (render a page) and implemented exactly enough OS to reach it, so every
component has an obvious reason to exist. For Torch, the equivalent goal is the three questions in §2.
That's why this plan keeps asking whether a feature serves them. **Adopt the discipline; nothing to code.**

**Scarlet** (`petitstrawberry/Scarlet`, MIT, 1.0 "Akane") is a multi-ABI Rust kernel plus a reference
distribution composed by `cargo scarlet` from reusable "bundles". The interesting mechanism is
composition: the image is declared from bundles rather than assembled by scripts. Torch already has a
light version in `packages/*.txt` + the validator. A small, cheap step in that direction: treat the
optional app sets (compatibility, creative, development) as named bundles that `torch install` can add
later, instead of shipping all of them in every install (§5.3). **Adopt the idea at manifest level; no
build-system rewrite.**

**SerenityOS and skiftOS** show what one design language across the whole system looks like: same
widgets, same metaphors, from boot to apps. Torch can't own every app the way they do, since it runs
ordinary GTK and Qt software. It *can* own the surfaces it ships: shell, launcher, Settings/Recovery,
installer, greeter, GRUB theme. That's the realistic scope of "coherent" (§4.6).

**Haiku/BeOS** shows that system behavior can be legible: the Deskbar, Tracker's file attributes, and
replicants make state visible and direct. The useful idea is visible state, not the retro look. Torch's
recovery ledger is the same instinct applied to system changes.

**Omarchy** (`omacom/omarchy`, MIT) is the closest working precedent for an opinionated Arch + Hyprland
desktop. Two current facts matter. Its package list now includes `quickshell` and no Waybar, so it has
consolidated its shell. And it ships its own snapshot tool (`omasnap`). Its config approach (system
defaults sourced from a managed location, user overrides kept separate) is the fix for gap 12. **Borrow
the config layering. Don't take the package list or the branding.**

**HyDE, COSMIC, Niri, Quickshell.** HyDE's theming layer is a reference for generating many app configs
from one palette; Torch needs the same "one token file → many outputs" step (§4.6). COSMIC shows a desktop
whose shell, settings and apps share a toolkit, at a maintenance cost Torch can't afford. Niri's scrolling
model is an interaction idea to *try*, not a reason to leave Hyprland. Quickshell is the one real
candidate for replacing Waybar/Wofi/Mako and gets a time-boxed prototype (§4.6).

**Bluefin, Aurora, Bazzite** (bootc/ostree images) offer three transferable ideas: separate apps from the
OS (Flatpak by default for GUI apps, which `torch install` already prefers after the repos); make the
known-good state explicit (the previous image deployment); and give maintenance tasks names (`ujust`
recipes). Torch adopts the first and third directly. For the second, it marks snapshots as known-good
after a verified boot (§4.3) instead of switching to images. Image-based A/B is rejected for the base
(§4.3).

**Libertix** (`ekimiateam/libertix`, **GPL-3.0**) is the most directly useful reference, and its
`docs/ARCHITECTURE.md` is worth reading in full. The mechanisms:

- *A typed installation plan, published atomically before any disk mutation*, with immutable user choices
  and only two runtime-resolved fields, each revalidated on every write.
- *One ordered step catalogue* restated in every runtime (C#, PowerShell, Python, shell), with CI comparing
  the copies. Only the next step may start, and success requires every required step.
- *Compensation only for completed, compensable steps*, each proving ownership of its target by disk
  identity and exact geometry before it touches anything.
- *Rollback success is defined by verified conditions*, not by the compensation scripts exiting cleanly.
  A BitLocker state mismatch prevents a "fully verified rollback" claim.
- *First-boot evidence:* the installed system publishes durable proof (boot chain, filesystem, account,
  packages) that is cross-checked against the plan.
- *A guarded `update-grub`* that validates a candidate config before atomically replacing the last known
  good one.
- *A signed catalogue*, with local artifacts accepted only after their hash matches it.

Most of this fits Torch at much smaller scale: Torch's current install wipes a blank disk, so there's
nothing to compensate. What carries over now is plan-before-mutation, revalidation immediately before the
first destructive step, a step journal with required versus optional steps, first-boot evidence, and the
guarded GRUB update. Ownership-proven compensation becomes essential the day Torch installs *alongside*
another OS (Group B / dual boot), and the Windows-side bridge belongs to that future too. **Licensing:
Libertix is GPL-3.0 and Torch is MIT.** Copying its code would put the copied parts under GPL-3.0, and
the owner's own contributions don't license other contributors' code. Reimplement the mechanisms from
the architecture document; don't port files.

**ANOLISA** (`agentic-os-org/ANOLISA`, Apache-2.0; formerly `alibaba/anolisa`), the earlier spec's
reference for autonomy tiers, is still a useful precedent for audit and approval levels. Its
cloud-agent assumptions don't fit an optional local agent.

**QwenPU** (`divagr18/QwenPU`) compiles a RISC-V CPU and vector unit into Qwen3.5-4B's weights.
Execution is exact because a compiler computes the weights; nothing is learned. The relevant lesson for
Torch is the boundary it dramatizes: when an operation must be exact, make it exact by construction, not
by hoping the model gets it right. Torch's version is ordinary. The model may *select* among typed
operations and argue for one; deterministic code validates, plans and executes it (§4.7). **Inspiration
only.**

### 3.2 Papers, and what each one actually changes here

- **Saltzer, Reed & Clark, "End-to-End Arguments in System Design" (1984).** Checks done in intermediate
  layers can only be optimizations; correctness has to be verified at the endpoints. Concretely: an
  install is correct when the *installed system* boots and passes its checks, not when Calamares exits.
  A rollback is correct when the *rebooted* system has the expected packages, not when `rename` succeeds.
  And a model's proposal is valid only when `torchd`, the endpoint that executes it, validates it, however
  well the agent formatted it. This argument is behind the first-boot verifier, post-operation
  verification, and "the validator lives in `torchd`".
- **Mohan et al., ARIES (1992).** Torch needs two ideas from it, not the database engine. First,
  *write-ahead intent*: record what you're about to do, durably, before you do it, so recovery after a
  crash knows what was in flight. Second, *compensation records*: undoing a completed step is itself a
  logged action, and undo is idempotent. That's the shape of the `torchd` journal and the installer step
  journal (§4.2).
- **Pillai et al., "All File Systems Are Not Created Equal" (OSDI 2014).** Applications routinely get
  crash consistency wrong by assuming `rename` ordering and persistence guarantees the filesystem doesn't
  give them. This is exactly gap 7, and it's why the swap needs an atomic exchange or an explicit barrier,
  plus a fault-injection test, rather than an argument that the window is small.
- **Provos, Friedl & Honeyman, "Preventing Privilege Escalation" (USENIX Security 2003, OpenSSH privilege
  separation).** Keep the privileged part small, with a narrow, typed interface, and treat everything the
  unprivileged side sends as hostile. `torchd` already follows this. It also explains why confirmation
  belongs to a trusted path (polkit) rather than the unprivileged client.
- **Xie et al., OSWorld (2024).** Agent evaluation has to run in a real environment and score with
  execution-based checks: did the system end up in the right state? That's the template for Layer III's
  evaluation, and Torch's QEMU harness is already most of the infrastructure.
- **Debenedetti et al., AgentDojo (2024),** plus the same group's **CaMeL, "Defeating Prompt Injections
  by Design" (2025).** AgentDojo provides the method: test with injections planted in tool outputs. Torch's
  equivalents are log lines, package descriptions, filenames, SSIDs and PKGBUILDs. CaMeL provides the
  design rule: untrusted data must never determine *which* privileged action runs, only fill typed
  arguments that are checked independently. Torch's version of that rule is in §4.7.
- **Patil et al., Berkeley Function Calling Leaderboard (2024–25).** Small models' tool-call accuracy
  varies a lot by task shape, so pick the model size by measuring on Torch's own operation schema, not
  from generic benchmarks.
- **Loghub (He et al.)** and **NL2Bash (Lin et al., 2018)** are existing datasets for log understanding and
  natural-language-to-shell. They're useful for *evaluation probes*. Neither matches Torch's actual task,
  which is choosing a typed operation from structured observations, so neither justifies fine-tuning on
  its own (§4.7).

---

## 4. Architecture

### 4.1 The picture

```
 ┌───────────────────────────── user-facing (unprivileged) ─────────────────────────────┐
 │  Desktop shell: Hyprland + bar / launcher / notifications (Waybar·Wofi·Mako today)   │
 │  Torch apps (GTK4): Welcome · Settings · Recovery · Software                        │
 │        │  call                                                                      │
 │        ▼                                                                            │
 │  torch CLI ── (proposed) stable JSON contract ── the only system-management API     │
 │        ▲                                                                            │
 │        │ proposals only (never executes)                                            │
 │  torch-agent (optional, Layer III) ── llama.cpp, local model, observation collectors │
 └────────┼────────────────────────────────────────────────────────────────────────────┘
          │ requests over /run/torchd/torchd.sock (SO_PEERCRED; torchd assigns op ids)
 ┌────────▼──────────────────────────── privileged ──────────────────────────────────────┐
 │  torchd: op catalogue · validation · plan · policy ── authorization (polkit + plan)  │
 │          journal: intent → steps → outcome → verification   (/var/log/torchd, @log)  │
 │          executes: pacman · snapper/btrfs · systemctl · grub-mkconfig (guarded)       │
 └────────┼──────────────────────────────────────────────────────────────────────────────┘
          ▼
   Arch base (linux, linux-lts, optional linux-cachyos; Mesa; systemd; NetworkManager; PipeWire)
   Storage: Btrfs  @ (incl. /boot)  @home  @log  @cache  @snapshots      Boot: GRUB + grub-btrfs
   Install: live ISO → torch preflight → Calamares → torch-target-setup (journal) → first-boot verifier
```

There are three boundaries, and each has a rule:

1. **A structured contract between UI and CLI (proposed).** GUIs never reimplement system logic; they
   run `torch` and render its structured output, as `torch-welcome` already does with `torch diagnose`.
   **This doesn't exist yet beyond `torch diagnose` and `torch doctor --json`.** The proposal is a
   versioned JSON output mode for every command, plus a non-interactive plan/apply form for the mutating
   ones, so no GUI has to scrape text or answer stdin prompts. This is v1's one rule that survived, and
   it's what lets the desktop be redesigned without touching recovery. A shared Rust library is a later
   optimization, if process spawning ever becomes measurable. That isn't a reason now.
2. **The socket between unprivileged code and `torchd`.** Only typed operations cross it. `torchd`
   validates arguments itself, generates the plan itself, performs authorization itself, and assigns the
   operation id itself. Nothing the client says about confirmation, identity, tier or ids is trusted.
3. **The proposal boundary for the agent.** The agent outputs a *proposal*, which is data. A proposal
   becomes a request only through the same authorization path a human uses. The agent's own identity can
   never authorize, and its requests never receive the auto-approval today's fixed `Auto` tier gives
   every caller.

User-level operations (Flatpak `--user`, AppImage, Distrobox, AUR *builds*) stay outside `torchd`, as they
do now. Only the steps that need root cross the socket.

### 4.2 One discipline: the privileged execution contract

Every mutating privileged operation, whether it comes from the CLI, a GUI, the installer or the agent,
goes through the same sequence. Today's `torchd` implements only parts of it: argument validation, token
binding and an after-the-fact audit line.

1. **Daemon-generated plan.** `torchd`, not the client, computes a deterministic, read-only description of
   what will happen. Examples: the package set before and after (`checkupdates`/`pacman -Sp`/`pacman
   -Rsp`); the files and packages a rollback would revert, from diffing the snapshot's
   `var/lib/pacman/local` against the current one; which GRUB entries will change. The plan gets a
   `torchd`-assigned id and a digest over its exact operation and arguments, and it records the *state
   revision* it was computed against. A client may display a plan; it may never author one.
2. **Verified preconditions.** Immediately before execution, `torchd` re-checks what the plan assumed:
   the state revision still matches (otherwise the plan is stale and must be regenerated and
   re-authorized), there's enough free space, no pacman lock, the network is up where needed, and the
   snapshot to roll back to still exists.
3. **Explicit authorization, bound to the plan.** The policy decides per operation *and per caller class*
   whether authorization is needed. Agent-originated requests always need it, for every mutating
   operation. Authorization covers exactly one plan digest and is consumed by its execution.
4. **Durable intent record.** Before the first side effect, `torchd` appends an *intent* record (op id,
   plan digest, caller, authorization result, state revision) and fsyncs it.
5. **Execution.** Steps run in order, each with its own journal record, so an interruption can be located
   precisely.
6. **Independent verification.** A check that doesn't trust the step's exit code: `pacman -Q` matches the
   plan; the unit's `ActiveEnterTimestamp` moved; the candidate `grub.cfg` passed `grub-script-check` and
   lists the expected kernels. For a rollback, verification happens after the next boot: a check
   confirms which `@` is running and that doctor passes.
7. **Recorded outcome.** The journal is append-only JSONL under `/var/log/torchd/` (on `@log`, so it
   survives rollbacks). The outcome line records success, failure or "interrupted", the state revision
   after, the verification result, and links to any snapshots created.

**What authorization does and doesn't prove.** Four different things are easy to conflate:

- *Process authorization:* the requesting process's uid is allowed to request this action class. Socket
  permissions, SO_PEERCRED and a polkit `yes` result answer this.
- *Interactive authentication:* someone at the session typed a password or touched a key that the
  account's credentials accept. Polkit's `auth_self`/`auth_admin` answer this. It shows a credential
  holder was present, not what they meant.
- *User intent:* the person wanted the outcome. No mechanism proves this. A clear plan and an honest
  default (Cancel) make it likely.
- *Approval of the exact operation and arguments:* the person accepted *this* plan, with *these* package
  names and *this* snapshot id. That needs the authorization bound to the plan digest, with the
  plan-describing text shown by the privileged side (`torchd` can pass a message to polkit as a root
  caller). It also needs `torchd` to refuse to execute anything other than the authorized digest.

Polkit is a good mechanism for the second, and it's already installed. On its own it doesn't provide the
fourth, and nothing provides the third. Torch's contract therefore needs both: polkit-backed interactive
authentication plus `torchd`-side binding of that authentication to one plan digest. The UI also has to
stay honest that a password prompt is not a guarantee anyone read the plan. Until that's implemented,
today's token flow and the fixed `Auto` tier are explicitly limited to the interactive CLI.

A **state revision** is a small hash of the facts that make a plan stale: the booted subvolume, the newest
snapshot id, the pacman local database, and the last journal sequence number. It's cheap, deterministic
and comparable, and it's the same thing the agent protocol needs (§4.7).

On startup `torchd` scans the journal for operations with an intent and no outcome, and reports them.
`torch doctor` turns that into a plain-language line ("an update was interrupted at 14:02; the pre-update
snapshot is #41"). That's the ARIES idea at the scale Torch needs: detect what was in flight, then tell
the human. Don't automatically redo or undo, because automatic destructive decisions need far more
evidence than a journal line.

### 4.3 Recovery: different problems, different mechanisms

| Problem | Mechanism | Status | Proposed |
|---|---|---|---|
| Undo a config/app change in `~/.config` | Layered config: Torch defaults read-only in `/usr/share`, user overrides separate | Missing (gap 12) | `torch config diff/reset <area>`; optional user tools stay optional (chezmoi, git) |
| Undo a package transaction | snap-pac pre/post + whole-root rollback | Works | Plan view shows *everything* the rollback reverts, not just that transaction |
| Restore a bootable system | GRUB fallback kernel; snapshot boot; rollback | Works except rollback-from-snapshot (gap 6) | Fix gap 6; mark snapshots *known-good* after a verified boot |
| Recover from a failed installation | Erase-disk install: nothing to restore | Install journal missing | Journal + first-boot evidence now; compensation only with non-destructive install modes |
| Recover personal files | **Not snapshots.** Backups to another device | Missing | Doctor reports "no backup configured"; recommend a tool, don't build one (§5.3) |

Being honest about limits belongs in the UI, not only in docs. A rollback keeps `/home`, which means an
app's data in `~/.local/share` may now be *newer* than the app that reads it. That's usually fine and
occasionally not (database schema migrations, some browsers' profiles after a downgrade). The rollback
plan should say this in one line. `/var/lib` is rolled back with `@`, so container images, VMs and
databases there go back too. That's untested (`btrfs-layout.md`) and should appear in the plan when those
directories are non-trivial.

**Hardening the current model.** These are proposed changes, each with a test:

- **Crash-safe swap.** Today's swap is a snapshot plus two separate renames. That is not a transaction,
  and the "no `@`" state it can leave is unhandled (gap 7). Btrfs supports
  `renameat2(RENAME_EXCHANGE)`, including between subvolumes (with restrictions; a 2021 fix covered
  exchanging a subvolume with a directory). Proposed sequence: create `@.rollback-new`, exchange it with
  `@`, rename the exchanged-out old root to `@.pre-rollback-*`, then `btrfs filesystem sync`. Only the
  exchange step is atomic. The whole sequence still isn't one transaction, so every intermediate crash
  state needs a defined recovery:
  - crash before the exchange is durable: the old `@` is still in place, plus a leftover
    `@.rollback-new`, which the next attempt must detect and remove;
  - crash after the exchange but before the rename: the new root is `@` and the *old* root sits under
    the name `@.rollback-new`, which must not be mistaken for a fresh copy and deleted;
  - crash before the sync: the swap may silently not have happened, and the journal must show it
    unconfirmed.

  The intent journal (§4.2) is what lets `torchd` tell these states apart after reboot. Exchange needs a
  real test on the shipped kernel before it's adopted (open choice O4). If it doesn't work on subvolume
  roots, keep the two renames, add the sync and the journal, and document the manual recovery from
  GRUB's rescue prompt when `@` is missing. Until one of these is implemented and fault-tested, the crash
  window remains an open, documented defect.
- **Booted-snapshot rollback.** Find the device from `/.snapshots`' mount source, or from `root=UUID=`
  via `blkid -U`, not from `/`. Then verify across a reboot.
- **Retention.** Pass `--cleanup-algorithm number` for Torch checkpoints. Add `snapshot.delete` and
  `rollback.discard-previous` operations with policy: the denylist forbids deleting the current
  known-good snapshot and the snapshot currently booted. List pre-rollback roots in `torch snapshot list`.
  Doctor reports snapshot count and approximate exclusive space (`btrfs subvolume show` / `btrfs
  filesystem du`; qgroups stay off, since they have known performance costs). Decide whether to enable
  `FREE_LIMIT`, after the 30-day replay test (§7) shows real growth.
- **Known-good.** After a boot reaches the graphical target and `torch doctor` passes, a oneshot unit tags
  the newest snapshot (snapper userdata `torch_known_good=yes`). "Last known good" then becomes an
  evidence-based fact rather than a label, which also gives the old spec's denylist item a precise
  meaning.
- **GRUB.** Generate to a temp file, `grub-script-check`, confirm the expected kernels appear, then
  atomically `rename` over `grub.cfg`. Keep the previous one as `grub.cfg.prev`. Separately, decide when
  `grub-install` may run at all. The ESP core image loads modules from `/@/boot/grub`, so rolling back
  across a `grub-install` can mismatch core and modules. Arch doesn't run `grub-install` on package
  updates. Torch should only run it as an explicit, journaled operation whose plan warns about this.

**Alternatives considered for the model itself:**

- *SUSE-style default subvolume + upstream `snapper rollback`.* This replaces custom code with upstream
  code, but it means changing the subvolume layout, fstab, kernel command lines and grub-btrfs on every
  existing install, for the same result. **Not now.**
- *Transactional updates* (install into a new snapshot via chroot; the running root is never touched;
  switch on reboot). The real benefit is that a power cut mid-update can't damage the running system. The
  cost is a substantial new mechanism with no Arch-native tool, plus pacman hooks running in a chroot.
  Today's model already recovers from that case: the pre-snapshot exists and GRUB can boot it. **Postpone.
  Revisit if the 30-day replay or real use shows interrupted or partial upgrades are frequent.**
- *A/B images (bootc/ostree).* Incompatible with a mutable Arch + AUR system without becoming a different
  product. **Rejected.**

### 4.4 Installer

Keep Calamares (configuration only). There's no evidence a replacement would justify its maintenance, and
the install works. The changes are about honesty and evidence:

1. **Offer only what's tested.** Set `allowManualPartitioning: false`,
   `enableLuksAutomatedPartitioning: false`, and `availableFileSystemTypes: ["btrfs"]`, and refuse BIOS
   boots in preflight. Re-enable each option when it has a passing VM test, and hardware evidence where
   relevant.
2. **Revalidation before mutation.** Calamares 3.4.2 constrains how this can work. Its
   `GlobalStorage["partitions"]` is filled by `FillGlobalStorageJob`, which runs *after* the destructive
   partition jobs (`PartitionCoreModule::jobs`). So no job can inspect the planned layout before the disk
   changes. What the show phase *does* store beforehand is `firmwareType`, `partitionChoices.install`
   (erase/alongside/replace/manual), `luksPassphrase` (non-empty when encryption was chosen) and
   `defaultFileSystemType`. After a failed job the queue skips every later non-emergency job
   (`JobQueue.cpp`), so a small Python job module placed first in the exec sequence can reject an
   unsupported choice before `partition` runs. That gate is implemented in the installation-correctness
   slice. A richer live-session preflight (Secure Boot state, existing data on the target disk) remains
   future work.
3. **Required versus optional steps.** Each step in `torch-target-setup` is classified. A required step
   is one without which the installed system won't boot, can't log in, can't trust its package
   repositories, or lacks the advertised snapshot/rollback/snapshot-boot recovery. An optional step only
   loses one convenience. Steps verify their own results (`cmp` for kernels, `lsinitcpio` for initramfs
   contents, `systemctl is-enabled`, `snapper list`). After the bootloader is installed, a separate check
   verifies the boot chain (`grub-script-check`, `grub-fstest cmp` of the kernel and initramfs as GRUB
   reads them, EFI binaries). Required failures exit non-zero so Calamares shows a failed install instead
   of a degraded one. Each step's result is recorded in the target's `/var/log/`.
4. **First-boot evidence.** A oneshot unit on first boot compares the running system with what the install
   journal claimed: subvolumes and mount options, the EFI boot entry, kernels, snapshot 1, the `[torchos]`
   repo and keyring. It writes `/var/lib/torchos/install-evidence.json`, marks snapshot 1 known-good, and
   `torch-welcome` shows the result. This is Libertix's evidence idea scaled to a single-OS install.
5. **Later (Group B):** dual boot and install-alongside. This is where Libertix's plan, ownership-proven
   compensation and verified-rollback contract become mandatory, and where installation rollback becomes
   a real feature distinct from system rollback. It deserves its own brainstorm and spec, as `CLAUDE.md`
   already says. The USB-less Windows bridge lives there too, with the GPL-3.0 question decided first.

**LUKS needs a decision, not just a test.** `/boot` inside `@` is what makes kernels roll back
consistently with modules. Encrypting `@` therefore means GRUB unlocks the disk itself. That isn't
supported today by *any* tested path. The installer offered the checkbox, but neither the initramfs
(`encrypt` hook) nor GRUB (`GRUB_ENABLE_CRYPTODISK`) nor a keyfile is configured, so encryption is
disabled in the installer slice that follows this plan. The earlier claim that GRUB can't unlock LUKS2
volumes using Argon2 is out of date: GRUB 2.14 added Argon2 KDF support, and Arch's `core` repo ships
`grub 2:2.16-1` (2026-09-24). Before relying on that, verify the GRUB version and build options in an
actual Torch install, and test unlock time on real hardware. GRUB's userspace Argon2 runs before the
kernel and can be slow on weak CPUs. Other open sub-questions: the double prompt (GRUB, then the
initramfs) versus an embedded keyfile, and whether the alternative, an unencrypted `/boot` partition that
breaks kernel-in-snapshot consistency, is ever worth it. This is open choice O6. It also needs its own VM
test and a security review before the installer offers it again. The WSL working clone holds uncommitted
2026-09-28 experiments in this direction (an `encrypt` hook and Calamares' `luksbootkeyfile`), which this
document neither adopts nor discards.

### 4.5 Packages, updates, hardware and performance

**Updates.** `torch update` stays a full `pacman -Syu`; partial upgrades are unsupported on Arch, and the
current code is right about that. The new parts are a preflight and a postflight inside `torchd`'s plan
step:

- Preflight: free space for the download plus snapshot headroom; AC power, or battery above a threshold;
  no pacman lock; `archlinux-keyring` upgraded first when it's in the set; and **Arch news since the last
  upgrade**, shown and acknowledged before applying, because news items are how Arch announces manual
  interventions.
- Postflight: `.pacnew` files listed; reboot-needed detection (the running kernel's modules directory is
  gone); the guarded GRUB regeneration; doctor.

`package.install` currently auto-approves a full system upgrade in order to install one package. That's
correct for Arch, but the plan should say so ("installing firefox also upgrades 213 packages") so the user
isn't surprised.

**Default package set.** Every install currently gets Wine, Lutris, LibreOffice, OBS, Docker, Rust, Node
and more. That's a large first download and a big snapshot footprint, and it contradicts "unobtrusive
when you don't need it". Proposal (open choice O3): a lean default plus named bundles (`torch install
@creative`, `@development`, `@windows-apps`), offered on the welcome screen and recorded in the journal
like any other change.

**Hardware.** Target x86-64 Intel and AMD, and let Mesa and the kernel do the work. Support claims get
three tiers, recorded in `docs/hardware/` with one file per tested machine:

- *Verified*: a named machine passed the checklist in §7.2, with the date, kernel and firmware recorded.
- *Expected*: Intel/AMD graphics with Mesa, standard Wi-Fi/audio, untested here.
- *Separately verified opt-in*: NVIDIA (`nvidia-open` packages plus the Hyprland environment variables),
  added as a `torchd` operation with a checkpoint only after an NVIDIA machine passes the checklist. Not
  before Intel and AMD do.

CPU features are detected (`torch hardware` already reports the x86-64 level), never assumed. The generic
image stays `x86-64`. CachyOS's v3/v4 repos remain rejected, for the reasons in `0001`.

**Performance profiles.** `power-profiles-daemon` is already installed and enabled. **Quiet / Balanced /
Performance map directly to its power-saver / balanced / performance.** That's the whole first version,
and it uses a native mechanism rather than inventing one. Anything beyond it (systemd-oomd under memory
pressure, `sched-ext` schedulers on kernels that have them, zram size) is an opt-in experiment that must
show a measured improvement on the §7.2 metrics before it ships, and must be reversible through the same
journaled path. The os-essentials spec's plan to adopt `cachyos-settings` wholesale is **withdrawn**: it
was never implemented, and adopting an unmeasured sysctl bundle is exactly what the owner asked to avoid.

What's already configured and reasonable: zram (`ram/2`, zstd), `compress=zstd:1`, `noatime`,
`fstrim.timer`, `discard=async` on SSDs (redundant with the timer but harmless). There's no swap file, so
no hibernation. That's a known limitation to state, not to fix yet.

### 4.6 Experience: shell, configuration, and the design language

**Configuration layering (fixes gap 12).** Torch's defaults move to package-owned files under
`/usr/share/torchos/` (Hyprland `source =`, Waybar `include`, CSS `@import`). The user's
`~/.config/<app>` files then contain an include line plus their own overrides. Package updates improve the
defaults for everyone. Rollbacks revert defaults together with the system, because they live in `@`. And
"what did I change versus what does Torch ship" becomes a mechanical diff (`torch config diff`).
Migrating existing installs is a one-time journaled operation that keeps the old files as `.torch-old`.
chezmoi stays recommended for people who want their own dotfile history; it stops being described as a
system mechanism.

**The shell question (open choice O1).** Omarchy's move to Quickshell, a QML shell toolkit, shows a
unified bar, launcher, notifications, OSD and overlays can work. A single design-token pipeline fits
Torch's coherence goal better than styling four programs in four config formats. The cost is a QML
codebase Torch owns and has to keep working across Quickshell and Hyprland releases. **Recommendation: a
one-week prototype** of the bar and launcher in Quickshell against restyled Waybar + Wofi, compared on
idle memory, startup time, keyboard-only use, scaling at 1.25×/1.5×/2×, and how much code the design
needs. Decide on evidence. Until then, nothing is replaced.

**Toolkit reality.** Torch doesn't own most app windows. libadwaita apps follow the color scheme and
accent through the settings portal and resist arbitrary theming. GTK3 apps can use `adw-gtk3`. Qt apps
can use `qt6ct` with a matching palette. Torch sets those three and doesn't fight libadwaita. The
surfaces Torch *does* own are shell, launcher, Torch apps, Calamares (QML branding), greeter, GRUB theme
and Plymouth if adopted. Those are where the identity lives.

**Four visual directions**, compared on the surfaces that matter:

| | Desktop | Launcher | Settings | Installer | Recovery |
|---|---|---|---|---|---|
| **A. Ambient editorial** — warm neutrals, generous space, Geist Serif for page titles only, one accent | Quiet bar, wallpaper-led, no chrome noise | Large type, few results, recent-first | Reads like a well-set document; sections with serif heads | Calm, one decision per page, plain sentences | Checkpoints as a dated, captioned list |
| **B. Modular workstation** — tight grid, Geist Mono for data, visible structure | Dense bar with modules; status first | Keyboard-first, command palette | Dense two-pane, everything visible | Efficient, but intimidating for beginners | Table of snapshots with sizes and diffs |
| **C. Selectively spatial** — layers and depth only where they explain hierarchy | Overview with workspaces as physical sheets | Results float above context | Mostly flat; depth for drill-down | Steps as stacked cards | Time as depth: checkpoints as layers you peel back |
| **D. Experimental: "the ledger"** — the system as an annotated record; every change has a caption | Notifications phrased as ledger entries | Can launch *and* answer "what changed?" | Each setting shows when and why it last changed | The install itself becomes the first ledger entries | The recovery UI *is* the ledger, with plan view before any reversal |

**Recommendation:** use A as the base language, B's discipline inside dense tools (diagnostics, the
recovery diff view), C only for the workspace overview and recovery's time axis, and D as the *content
model* rather than a visual style. D is Torch's thesis (§2) made visible, it adds no new visual effects,
and it gives the identity a reason that a theme alone can't. Motion is functional only, with
`prefers-reduced-motion` / Hyprland `animations:enabled` honored from a single setting.

**Color.** The orange is history, not a constraint. Measured: `#ff4500` works as an accent *on dark*
(5.33:1 on `#2b0a00`) and fails behind white text (3.44:1). A coherent palette keeps one ember accent,
tuned per mode so it passes 4.5:1 where it carries text, on warm neutrals. Tokens are defined once and
generated into GTK CSS, Hyprland, the bar, Mako, Calamares QML and the GRUB theme. `scripts/verify_palette.py`
already exists and grows a WCAG check that fails the build.

**Typography.** All OFL-1.1 (`vercel/geist-font`):

- *Geist Serif:* display only. Page titles in Torch apps, the installer's step headings, the welcome
  screen. Upstream calls it "a high-contrast display serif with fine, saw-toothed serifs and sharp
  hairlines". Hairlines fall apart at small sizes and low DPI, so set a floor of ~24px. It was released
  in v1.9.0 on **2026-10-30, three days ago**: pin the version and expect fixes. It isn't on Google Fonts
  yet; package from the GitHub release with a checksum.
- *Geist Sans:* all interface text. *Geist Mono:* commands, ids, sizes, diagnostics, the ledger's
  technical column.
- *Korean (open choice O2):* Geist has no Hangul. Candidates to test: **Pretendard** (OFL) as the Sans
  fallback, and **Noto Serif KR**, **MaruBuri** and **Hahmlet** for serif headings. A quieter option is
  to set Korean headings in Pretendard SemiBold rather than force a serif pairing. Test with a fixture
  page of mixed strings at 13/15/24/40px: baseline alignment, apparent weight at the same numeric weight,
  x-height versus Hangul size, line-height in mixed paragraphs. Configure through fontconfig `prefer`
  lists so GTK and Qt follow. Keep Noto CJK for Chinese and Japanese coverage.

**Icons.** The division is deliberate, so the rules are what make it one system:

- **Colloid** (GPL-3.0) is the XDG icon theme: *objects* such as applications, folders and file types.
  It ships as its own package with its license. A recolored variant is a modified GPL work, and its
  sources (the SVGs) ship with it.
- **MingCute** (Apache-2.0) is for *controls* at 16–20px: buttons, navigation, inline actions, bar
  glyphs. MingCute also ships an icon font, which suits the bar. Ship its LICENSE (and NOTICE if any).
- **Solar** (CC BY 4.0) is for *meaning* at 24px and up: settings categories, empty states, recovery and
  diagnostic illustrations. Duotone only at 32px and above, with the second tone as the accent at reduced
  opacity. Attribution (name, link, license, a note that it was modified) goes in an About/Credits page
  and `/usr/share/licenses/`. **The Solar GitHub repository has no LICENSE file.** Before packaging,
  confirm the CC BY 4.0 grant from the authors' Figma page or Iconify's metadata, and record the source.
- Within any row of controls: one family, one size, one fill state. Filled means *active or selected*;
  outline means *idle*. Monochrome (`currentColor`) everywhere except Solar duotone illustrations.
  Icon-only buttons always carry an accessible name and a tooltip.
- A small Torch set (checkpoint, rollback, ledger, diagnose, known-good, agent) is drawn on Solar's grid
  so it sits beside Solar at the same sizes. No original app icons.

**Accessibility is part of the acceptance criteria**, not a later pass: keyboard reachability of every
Torch app action, 4.5:1 text contrast, scaling at 1×–2×, reduced motion, and screen-reader names on GTK4
widgets. Wayland shell accessibility (Waybar, Quickshell) is weak across the ecosystem; state that and
keep every shell function also reachable from a Torch app.

### 4.7 Local intelligence: the protocol comes first

**Scope.** The agent is optional, off by default, and installed as its own package. Nothing in Layers I
and II may depend on it. It does three things: explains, diagnoses what deterministic checks can't
classify, and proposes typed operations. It never executes.

**Runtime.** llama.cpp (`llama-server`, MIT). It supports grammar- and JSON-Schema-constrained decoding,
which turns "the model must output valid JSON" from a hope into a property of decoding. It runs as a
user-level systemd unit with `MemoryMax`, `CPUQuota` and unload-on-idle, listening on a Unix socket or
loopback only. Models are the **Qwen3.5 small dense series (0.8B / 2B / 4B, Apache-2.0, March 2026)**,
4-bit quantized (secondary sources put the 0.8B and 2B under 2 GB), with 4B as the reference. Weights are
downloaded only by an explicit user action, with a checksum, and never in the ISO. No second runtime or
provider unless a measured gap justifies it.

**When the model is invoked.** Most events need no model:

- Deterministic first. A *known-failure catalog* (shipped data: pattern → explanation → suggested op) runs
  in `torch doctor` and covers common cases: failed unit with a known cause, full disk, pacman lock,
  missing keyring, booted snapshot, stale mirrors. It's useful without any model, so it belongs to Layer
  I/II.
- The model is invoked only when the user asks a free-form question, or explicitly asks it to analyze
  something the catalog didn't classify. It's never triggered automatically on boot or on every failure.

**Messages** (versioned, JSON Schema, in `torch/schemas/`):

- `torch.observation/1`, built by deterministic collectors, never by the model: `request_id`,
  `state_revision` (§4.2), `collected_at`, typed `facts` from `torch diagnose`, and `evidence[]`. Each
  evidence item has an id, a `source` (journal unit, file path, command), a `trust` value (`system` for
  values Torch computed, `untrusted` for anything containing external text: log lines, package
  descriptions, filenames, SSIDs, PKGBUILDs), and a `truncated` flag. Collectors come from a fixed list,
  each with a size cap and redaction for known secret shapes.
- `torch.proposal/1`, the model's only output, constrained at decoding time. Exactly one of:
  - `answer` — explanation text plus the evidence ids it relies on;
  - `propose` — `op` and `args` from the published op catalogue, a rationale, evidence ids, and the
    expected effect;
  - `need_more` — collector ids from the fixed list, never free-form commands;
  - `abstain` — a reason.

**Validation, independent of the model.** It runs in `torch-agent` for good error messages and *again*
in `torchd`, the endpoint. Checks: schema; op exists and is enabled for proposals; args pass the same
validators `torchd` uses; `state_revision` matches the current one (if not, the proposal is stale: discard
it and re-observe once); evidence ids exist; deadline not passed. Late, malformed or stale output becomes
`abstain`, shown as "couldn't produce a reliable answer", and never a partial action.

**Execution.** A valid `propose` is rendered as an ordinary Torch plan in the same UI a human uses. If the
user chooses to apply it, `torchd` regenerates the plan itself (it never executes the agent's text). The
request then goes through §4.2's contract under the *user's* identity, with interactive authentication
bound to that plan's digest. The agent runs as its own user (not a member of the socket group), can call
only read-only collectors, and never receives an auto-approving tier. So **no proposal can execute
without a person authenticating the daemon-generated plan for it**, and that holds by construction,
independent of model quality. As §4.2 says, authentication isn't proof the person read the plan; the UI
must not pretend otherwise. CaMeL's rule applies: untrusted evidence can
only *fill* typed arguments that `torchd` re-validates. It can never choose to bypass the plan.

**Records and retention.** Observations and proposals stay under the user's
`~/.local/state/torch/agent/` (readable only by that user, size-capped, deletable from Settings). The
`torchd` journal records only that an applied request originated from proposal `<id>`. Nothing is sent
off the machine. Telemetry, if ever added, is opt-in and separate.

**Order of work.** Schemas and validator first. Then a **mock agent** returning fixtures, including
adversarial ones: unknown op, injected argument, stale revision, injection text inside evidence, oversized
output, a `need_more` loop. Then real inference. Fine-tuning comes last and only if evaluation shows a
gap. The best training data source is probably Torch's own fault-injection harness, which produces
(observation, correct operation, verified outcome) triples. Existing datasets (Loghub, NL2Bash) are for
probing, not the main course.

---

## 5. Decision record

### 5.1 Keep

| Decision | Why it stands |
|---|---|
| Arch repos + signed `[torchos]`; CachyOS kernel opt-in (`0001`) | Built, verified, honest lineage |
| GRUB + grub-btrfs (`bootloader.md`) | Snapshot boot needs no working userspace; verified |
| Btrfs layout with separate `@snapshots`, `/boot` in `@` (`btrfs-layout.md`) | Rollback keeps kernels and modules consistent and never loses snapshots |
| `torchd`: narrow typed ops, shell-outs, root-only, SO_PEERCRED, no raw shell | Small, auditable, matches privilege-separation practice |
| Calamares, configuration only | Works; no evidence a replacement pays for itself |
| `torch install` ladder (repo → Flathub → gated AUR → Distrobox → files) | Implemented, mostly verified; gated AUR is the right default |
| Hyprland | Working; the shell *around* it is the open question |
| "GUI renders CLI output; no second management path" | v1's best idea; `torch-welcome` proves it for `torch diagnose`. The general structured interface is a proposal (§4.1) |
| Snapshots ≠ backups, said plainly | Already in docs; extend into the UI |

### 5.2 Change (with the evidence)

| Change | Evidence |
|---|---|
| Hide untested installer options (LUKS, manual, ext4/xfs, BIOS) | Gap 1: code shows LUKS can't boot as configured |
| Privileged execution contract (§4.2): daemon plans, preconditions, plan-bound authorization (polkit for interactive authentication), intent record, verification, outcome | Gap 2; privilege-separation literature; polkit is already installed but proves less than "approved this plan" |
| Caller-derived tiers: agent and other non-interactive callers never get today's auto-approval of `package.install`/`system.upgrade`/`snapshot.create` | Gap 2 (fixed `Auto` tier in `torchd/src/main.rs`) |
| Autostart a polkit agent in the session | Gap 11 |
| Rename the `torch-agent` group (e.g. `torch-admin`), keeping the old name as an alias for one release | Every human user is in a group named for an agent that doesn't exist; Layer III needs the name to mean the opposite |
| Socket read timeout | Gap 3 |
| Journal with intent/outcome, `torchd`-generated ids, state revisions | Gap 9; ARIES/end-to-end |
| Plan step for every mutating op | Product thesis; Libertix's plan-before-mutation |
| Retention fixes, pre-rollback visibility, delete/discard ops, known-good tagging | Gaps 4, 5 |
| Booted-snapshot rollback fix; atomic or barriered swap | Gaps 6, 7; Pillai et al. |
| Guarded GRUB regeneration | Gap 8; Libertix |
| Required install steps fail the install; first-boot evidence | Gap 10; end-to-end |
| Layered configuration replaces `/etc/skel` copy as the update mechanism | Gap 12 |
| AI: Claude Agent SDK → optional local agent (llama.cpp + Qwen3.5), proposal-only | Owner direction; local, optional, no account |
| Priority order: security and owner control become constraints | §2 |
| Withdraw `cachyos-settings` adoption | Unmeasured; never implemented |

### 5.3 Open (needs an experiment)

| # | Question | Alternatives | Leaning |
|---|---|---|---|
| O1 | Desktop shell | Restyled Waybar/Wofi/Mako · Quickshell · fuzzel-style lighter launcher | Prototype, decide on measured criteria (§4.6) |
| O2 | Korean pairing | Pretendard · Noto Sans/Serif KR · MaruBuri · Hahmlet · sans-only Korean heads | Pretendard + test serif candidates on a fixture page |
| O3 | Default package set | Current full set · lean default + bundles | Lean + bundles; measure ISO size and first-update size first |
| O4 | Swap atomicity | `RENAME_EXCHANGE` · two renames + sync + documented recovery | Exchange, if a VM test on the shipped kernel passes |
| O5 | Backup recommendation | Pika Backup (borg, Flathub) · Déjà Dup · restic + timer | Recommend Pika Backup in the GUI, restic in docs; doctor warns when none is configured |
| O6 | Encryption design | `/boot` in encrypted `@` (GRUB unlock; Argon2 since GRUB 2.14, verify shipped version; keyfile or double prompt) · separate unencrypted `/boot` | Keep `/boot` in `@`; verify GRUB version/build, measure unlock time on real hardware, VM test, security review |
| O7 | Secure Boot | sbctl with own keys (+ Microsoft keys for option ROMs) · shim-signed + MOK | After hardware; sbctl is simpler for a mutable system, but test firmware variety |
| O8 | Home snapshots | None (today) · opt-in snapper `home` config with a timeline | Opt-in only, clearly labeled "not a backup" |
| O9 | Agent model size | 0.8B · 2B · 4B (Q4) | 4B reference; choose by §7 measurements per task class |
| O10 | Firewall | none · `ufw` default-deny-incoming · nftables via `firewalld` | Small; `ufw` with a Settings toggle is the cheapest honest option |
| O11 | Transactional updates | Current mutable + snapshots · update-into-snapshot | Postpone; revisit with replay data |

---

## 6. The three layers

Each layer has a goal, slices small enough to finish and demonstrate on their own, and acceptance
criteria that are observations, not exit codes. QA and docs live inside each slice: a slice isn't done
until `docs/known-issues.md` and the relevant guide say what it verified.

### Layer I — The System

*Goal: Torch runs as a normal personal desktop on real Intel and AMD hardware, installs honestly, updates
predictably and recovers verifiably, with no model anywhere.*

| Slice | Acceptance |
|---|---|
| I-1 Honest installer: hide untested options, preflight + pre-partition revalidation, required/optional steps, install journal, first-boot evidence | VM: blank-disk install passes; a forced failure in a required step shows a failed install; a BIOS VM is refused before Calamares; the evidence file matches the journal |
| I-2 `torchd` journal: intent/steps/outcome, daemon ids, state revision, socket timeout, interrupted-op report | VM: `kill -9 torchd` and a QEMU `system_reset` mid-upgrade each produce a doctor line naming the op and the pre-snapshot; an idle connection no longer blocks other clients |
| I-3 Plan-bound authorization (polkit for interactive authentication); polkit agent autostart; group rename; caller-derived tiers | A script replaying `torchd`'s own token can't run a rollback; an authorization for plan A can't execute plan B; a non-interactive caller never auto-approves a mutating op; the polkit dialog appears in Hyprland; `pkttyagent` works on a TTY; the journal records the auth result and plan digest |
| I-4 Daemon-generated plans for upgrade, remove, rollback, kernel add, install-file, plus the proposed structured CLI output for them | Plan output validates against its schema; after apply, the observed package set equals the plan's prediction |
| I-5 Recovery hardening: booted-snapshot rollback, atomic or barriered swap, retention, pre-rollback listing and discard, known-good tags, guarded GRUB | VM: rollback from a booted snapshot persists across reboot; 50 resets at random points during rollback never leave a system that won't boot to the menu; 30-day replay keeps snapshot count within limits |
| I-6 Update pre/postflight: space, power, lock, keyring-first, Arch news gate, `.pacnew`, reboot-needed | Each injected condition (disk nearly full, synthetic news item, network down) is refused *before* any snapshot or pacman step |
| I-7 Real hardware: one Intel laptop, one AMD machine, then NVIDIA | §7.2 checklist passes and is recorded in `docs/hardware/`; failures become known issues, not silent omissions |
| I-8 Release engineering: release ISO from the final tree, signed checksums, CI for `cargo test` + manifests + shellcheck, release builds pinned to an Arch Linux Archive date | CI green on every push; two release builds a day apart produce the same package list |

Dependencies: I-2 comes before I-3, I-4 and I-5, since they write to the journal. I-1, I-6 and I-8 are
independent of the rest. I-7 runs whenever hardware is available, and its findings feed back. **Exit:**
the owner uses Torch on a real machine for two weeks, with at least one update, one rollback and one
snapshot boot, and every incident is explained by the journal.

### Layer II — The Experience

*Goal: a non-developer can install an app, change how the desktop looks, take and undo a checkpoint, and
understand what happened, without a terminal and without a separate management path.*

| Slice | Acceptance |
|---|---|
| II-1 Design tokens → generated configs; WCAG check in `verify_palette.py` | Build fails on a <4.5:1 text pair; one token change shows up in the bar, the apps and Calamares |
| II-2 Layered configuration + migration + `torch config diff/reset` | A `torch-config` update changes an existing user's bar; their override survives; migration is journaled and reversible |
| II-3 Shell prototype (O1) | Written comparison on the §4.6 criteria; decision recorded in `docs/decisions/` |
| II-4 Fonts and icons packaged with licenses and credits; Korean fixture page (O2) | Screenshots at 1×/1.5×/2× reviewed; credits page lists Solar/MingCute/Colloid/Geist correctly |
| II-5 Torch Recovery app: the ledger, plan view before rollback, known-good marks | Every GUI action shows its CLI equivalent; the GUI rollback path passes the same VM test as the CLI's |
| II-6 Torch Software (over `torch install --plan`) and bundles (O3) | Installing a browser from the GUI produces the same journal entries as the CLI |
| II-7 Settings: appearance, power profiles (ppd), hardware page, backup status (O5), firewall toggle (O10) | Keyboard-only walkthrough passes; reduced motion honored |
| II-8 Installer, greeter and GRUB theming in the new language | Install walkthrough by someone who didn't build it |

Dependencies: II-5 and II-6 need I-4 (plans). II-1 comes before every visual slice. II-3 can run any time.
**Exit:** a usability session with one or two people who didn't write Torch: install a browser, switch to
a dark theme, checkpoint, break something, roll back. Their stumbles are recorded and fixed.

### Layer III — Local Intelligence

*Goal: an optional assistant that measurably improves diagnosis and explanation, never executes, and can't
harm the system even when wrong or manipulated.*

| Slice | Acceptance |
|---|---|
| III-1 Schemas, validator (agent side and `torchd` side), mock agent, adversarial fixtures | Every fixture class is rejected or abstains; there's no code path from proposal to execution without a `torchd`-generated plan and plan-bound authorization |
| III-2 Known-failure catalog in `doctor` (ships even without the agent) | Fault-injection cases diagnosed deterministically, with explanations reviewed by a human |
| III-3 llama.cpp packaging, explicit model download, resource limits | Peak RSS, time-to-first-token and tokens/s for 0.8B/2B/4B Q4 measured on the Layer I machines |
| III-4 Evaluation harness (OSWorld-style execution checks; AgentDojo-style injections into logs, filenames and package metadata) | Report: accuracy versus catalog-only baseline, injection success rate (target: zero proposals that change op choice from injected text), abstention rate |
| III-5 Fine-tuning, only if III-4 shows a gap | Measured improvement on held-out harness cases, not on the training distribution |

Dependencies: III-1 needs I-2 (state revision) and I-3 (polkit). III-3 and III-4 need III-1. **Exit:** the
owner keeps the agent enabled because it's useful. If III-4 shows the catalog alone does as well, the
right outcome is to ship the catalog and not the model.

---

## 7. Verification

The principle: the check that something worked is independent of the thing that did it, and it observes
an outcome. Code doesn't certify its own success, and neither does an agent, a script's exit code or a
model.

### 7.1 In QEMU (automatable with `image/scripts/dev/`)

| Scenario | How it's produced | Pass means |
|---|---|---|
| Normal install, boot, update, rollback | Existing journey (`handoff.md` §1) | Current criteria, plus the first-boot evidence matching the install journal |
| Interrupted installation | QEMU `quit` during `unpackfs`, and again during `torch-target-setup` | Next boot doesn't present a half-system as installed; rerunning the installer succeeds; nothing reported success |
| Failed update | Network cut mid-download; a corrupted package in a local test repo; `fallocate` the disk to near-full | Refused or failed *visibly*; system boots; pre-snapshot exists; the journal names the op |
| Power loss mid-update | `system_reset` during `pacman` | Next boot (or a snapshot boot) works; doctor reports the interrupted op |
| Power loss mid-rollback | `system_reset` at each step (a test-only pause between steps, compiled behind a cargo feature that packaged builds never enable) | GRUB menu always reachable; exactly one `@` |
| Failed boot | Remove the default kernel's initramfs; break `fstab` | LTS entry or snapshot boot works; doctor explains in the booted state |
| Disk exhaustion | Fill `/` and `/home` separately | Updates refused before acting; doctor names snapshot space as the reclaimable part |
| Snapshot growth | **Replay 30 days of real Arch updates** by stepping the mirror through Arch Linux Archive dates | Snapshot count and exclusive space stay within the configured bounds |
| Missing hardware support | VM with no GPU acceleration | Doctor explains the degraded state instead of failing silently |
| Invalid agent requests | Mock-agent fixtures (III-1) | No execution; correct abstain or reject reason |

### 7.2 Only on real hardware

Suspend/resume ×20 (lid and idle), external displays and hotplug, Wi-Fi/Bluetooth/audio/brightness,
battery drain at idle (W, via `upower`) and under video playback, hardware video decode (`vainfo` plus a
real player), thermals under sustained load, firmware/Secure Boot behavior, NVIDIA. Measurements for any
performance claim: `systemd-analyze` and time from greeter to a usable desktop, idle RSS and wakeups
after five minutes, update duration including snapshots, and model RSS/latency for Layer III. Each run is
recorded in `docs/hardware/<machine>.md` with date, kernel, Mesa and firmware versions.

### 7.3 How failures get reproduced

Every bug report that touches Layers I–III should come with `torch diagnose` (JSON), the relevant journal
lines, and `torch snapshot list`. Every fixed system-level bug gets a harness scenario, or a unit test if
it's pure logic, so it can't come back quietly.

---

## 8. What to do first

These six tasks are small, change existing files, and remove the risks that matter most. They come
*before* real hardware, because they make what hardware testing finds trustworthy. The redesign and the
agent wait.

1. *(Implemented 2026-11-02 on `feat/torchos-install-correctness`, NOT READY: static, unit and container tests
   pass; package build succeeded; the ISO build stopped when the host disk filled. VM verification is
   outstanding, see `image/tests/vm/README.md`.)*
   **Make the installer honest** (`image/calamares/etc/calamares/modules/partition.conf`,
   `torch-target-setup`). Disable LUKS, manual partitioning and ext4/xfs; refuse BIOS and any non-erase
   choice in a job that runs before `partition`; make required step failures fail the install. *Why first:* it's the only known path to an
   unbootable system, and it's a config change. *Done when:* VM tests from I-1 for these items pass.
2. **Fix rollback from a booted snapshot** (`torchd/src/ops/snapshot.rs`). *Why:* doctor tells users to
   do something that likely fails, at the moment they're already in trouble. *Done when:* booted snapshot
   → `torch snapshot rollback N` → reboot → state persists, in the VM.
3. **Bound snapshot growth** (`ops/snapshot.rs`, `ops/kernel.rs`, `doctor.rs`). Add
   `--cleanup-algorithm number`, list pre-rollback roots, and have doctor report count and space. *Done
   when:* a VM with many checkpoints is pruned by `snapper-cleanup` and doctor shows the numbers.
4. **Start the `torchd` journal** (`torchd/src/main.rs`, `audit.rs`). Intent before, outcome after,
   fsync, daemon-generated ids, a read timeout on the socket, and an interrupted-op report. *Done when:*
   the I-2 kill/reset tests pass.
5. **Plan-bound authorization** (`torchd`, a new `org.torchos.policy` actions file, `hyprland.conf` for
   the agent autostart). *Why before the agent and before the GUI:* both depend on authorization meaning
   "a person authenticated for this exact daemon-generated plan", with no caller inheriting today's
   auto-approval. *Done when:* the I-3 tests pass and `systemd-analyze security` has been re-scored.
6. **Build the release ISO from the result** (already open in `handoff.md` §5), then take it to the first
   real machine.

After that comes the rest of Layer I in the order of §6. Layer II starts with tokens and layered config,
because they unblock every visual decision without committing to one.

---

## Sources

Repository (the source of truth for current state): `README.md`, `CLAUDE.md`, `docs/handoff.md`,
`docs/known-issues.md`, `docs/build.md`, `docs/recovery.md`, `docs/decisions/*`,
`docs/superpowers/specs/*`, `docs/superpowers/plans/2026-09-10-torchd-phase2.md` (STATUS block),
`torch/torchd/src/**`, `torch/src/**`, `image/calamares/**`, `image/archiso/profiledef.sh`,
`pkg/torchos/PKGBUILD`, `packages/*.txt`, `dotfiles/dot_config/**`.

External, checked this session:
- Libertix: [README](https://github.com/ekimiateam/libertix) and [docs/ARCHITECTURE.md](https://github.com/ekimiateam/libertix/blob/main/docs/ARCHITECTURE.md);
  `Installation/InstallationStateMachine.cs`, `assets/live/libertix-first-boot-verify.py` (GPL-3.0)
- Snapper: [snapper(8)](https://github.com/openSUSE/snapper/blob/master/doc/snapper.xml.in) (cleanup only counts snapshots with an algorithm; `SPACE_LIMIT` needs quota; `rollback` sets the default subvolume) and [snapper-configs(5)](https://github.com/openSUSE/snapper/blob/master/doc/snapper-configs.xml.in)
- Btrfs `RENAME_EXCHANGE`: [original patch](https://patchwork.kernel.org/patch/8152711/), [subvolume exchange fix](https://android-kvm.googlesource.com/linux/+/3f79f6f6247c83f448c8026c3ee16d4636ef8d4f), [Proxmox discussion](https://lore.proxmox.com/pve-devel/1623328337.kyeh01gy04.astroid@nora.none/T/)
- Geist: [vercel/geist-font](https://github.com/vercel/geist-font) (OFL-1.1; Geist Serif in v1.9.0, 2026-10-30)
- Qwen3.5 small models: [Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models), [Gigazine](https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small) (0.8B/2B/4B/9B, Apache-2.0; secondary sources, so confirm on the model cards before packaging)
- [QwenPU](https://github.com/divagr18/QwenPU), [Scarlet](https://github.com/petitstrawberry/Scarlet), [Wasabi](https://github.com/hikalium/wasabi), [Omarchy](https://github.com/omacom/omarchy) (`install/omarchy-base.packages`), [ANOLISA](https://github.com/agentic-os-org/ANOLISA), [llama.cpp](https://github.com/ggml-org/llama.cpp)
- Icons: [MingCute](https://github.com/mingcute-design/mingcute-icons) (Apache-2.0), [Colloid](https://github.com/vinceliuice/Colloid-icon-theme) (GPL-3.0), [Solar](https://github.com/480-Design/Solar-Icon-Set) (no LICENSE file in the repo; CC BY 4.0 grant to be confirmed)

Papers: Saltzer, Reed & Clark, *End-to-End Arguments in System Design*, ACM TOCS 1984. Mohan et al.,
*ARIES*, ACM TODS 1992. Pillai et al., *All File Systems Are Not Created Equal*, OSDI 2014. Provos,
Friedl & Honeyman, *Preventing Privilege Escalation*, USENIX Security 2003. Xie et al., *OSWorld*,
NeurIPS 2024. Debenedetti et al., *AgentDojo*, NeurIPS 2024 Datasets & Benchmarks. Debenedetti et al.,
*Defeating Prompt Injections by Design (CaMeL)*, 2025. Patil et al., *Berkeley Function Calling
Leaderboard*, 2024–25. He et al., *Loghub*. Lin et al., *NL2Bash*, LREC 2018.

Not verified, and flagged where used: the GRUB version and Argon2 support inside an actual Torch install
(Arch `core` lists `grub 2:2.16-1`), whether GitHub-hosted runners expose `/dev/kvm`, and Solar's
license source.

Corrected 2026-11-02 after owner review: authorization semantics (§4.2), the fixed `Auto` tier (gap 2),
the structured CLI interface marked as a proposal, GRUB Argon2 support, the rollback swap described as two
non-atomic renames with unhandled crash states, and required-versus-optional install failures.
