# Prior Art Research: SimpleOS and VibeOS
Researched 2026-08-23 for TorchOS v2 planning.

---

## SimpleOS (zacharyr0th/simple-os → zacharyr0th/SimpleOS)

**Availability caveat (read first):** As of 2026-08-23 this repository returns a genuine 404 from both the GitHub web UI and the GitHub REST API (`api.github.com/repos/zacharyr0th/SimpleOS` → 404; user's public repo list of 12 repos does not include it). GitHub's own code/repo search index also returns zero hits. It appears to have been deleted, transferred, or made private sometime after mid-2025. No fork or mirror preserving the code was found. The description below is reconstructed from two secondary sources and should be treated as **stale / partially unverifiable**:
1. A Wayback Machine snapshot from 2025-08-05 of `github.com/zacharyr0th/simple-os` (only snapshot that exists; earlier name, **x86-64**, no v86 demo mentioned).
2. Google/Bing search-engine cache snippets (via WebSearch) describing a later state of the repo renamed to `SimpleOS`, **x86-32** architecture, with virtual terminals and job control — presumably closer to what the task description (processes, virtual memory, syscalls, pipes, signals, ramfs, shell, ELF userspace, v86 browser demo) refers to, but the v86 demo, ramfs naming, and final directory layout could not be independently confirmed from a primary source.

Treat every specific claim in this section as "as of an unknown mid-2025 snapshot, possibly superseded" rather than current fact.

- **Purpose**: A personal/educational, from-scratch Unix-like OS kernel written in C and x86 assembly. Explicitly framed as "perfect for learning OS development or as a foundation for building custom operating systems" — a teaching/portfolio project, not a daily-driver.
- **Base / architecture**: x86 (64-bit long mode in the archived Aug-2025 snapshot; later search snippets describe it as x86-32 — the architecture target apparently changed between versions). Boots via GRUB (multiboot), 4-level paging (PML4/PDPT/PD/PT) in the x86-64 version. Ring 0/3 privilege separation with a TSS. Monolithic kernel with a VFS layer, a RAM-backed filesystem (block size 512B, inode-based), pipes (circular buffers), POSIX-style signals (SIGINT/SIGKILL/SIGTERM), a Linux-style `int 0x80` syscall interface (~18 syscalls: fork/exec/exit/wait/getpid/ps, read/write/open/close/pipe/dup2, stat/mkdir/readdir, sbrk, sleep/kill), an ELF loader for userspace binaries, a round-robin/priority scheduler, and a two-shell setup (`shell` and an enhanced `shell_v2` with pipes, I/O redirection, history, tab completion, background jobs, 4 virtual terminals via Alt+F1-4).
- **Agent model**: No evidence of AI-assisted development in the archived README or repo metadata — a conventional solo hobbyist OS project (unlike VibeOS). The task prompt's framing of it as having a "v86 browser demo" suggests a later addition not documented in the source retrievable here.
- **Privilege model**: Classic ring 0/ring 3 hardware privilege separation via the CPU's own protection rings + TSS-based mode switching. No broker/mediation layer — a kernel enforcing privilege at the ISA level, not analogous to TorchOS's userspace privileged-broker model.
- **Recovery model**: None documented. No snapshotting, no rollback, no A/B boot. A kernel panic handler (`panic.c`) exists but recovery is "reboot and try again."
- **Compatibility strategy**: None — targets QEMU emulation (`qemu-system-x86_64`) and a specific cross-compiler toolchain (`x86_64-elf-gcc`). No real-hardware driver breadth.
- **UI model**: Text-mode VGA terminal with 4 virtual terminals, no GUI. Shell-first.
- **What works well**: pipes/command chaining, signals, job control, tab completion, command history — a surprisingly complete *shell UX* layered over a minimal kernel. Documents a `make test`/GDB remote-debug workflow (`qemu-system-x86_64 -s -S`, `gdb target remote localhost:1234`).
- **What breaks / limits / fails to generalize**: From-scratch kernel exercise — no MMU-backed memory protection guarantees beyond basic paging ("copy-on-write planned for future," never confirmed done), no networking, no persistent storage beyond a RAM filesystem, no package manager, no real driver ecosystem, single point of failure (any kernel bug = total halt, no fallback). Architecturally the *opposite* of what TorchOS needs.
- **What TorchOS should reuse conceptually**: Very little architecturally, since TorchOS sits entirely in userspace/systemd-land on top of a real Linux kernel. The one transferable idea is the shell-UX completeness bar (pipes, redirection, job control, tab-complete, history) — "feels like a real Unix shell" is a low bar users expect even from toy kernels.
- **What TorchOS must explicitly avoid**: Treating ring/hardware privilege separation as sufficient "security" (TorchOS needs a policy-level broker, since it's mediating an AI agent's actions, not just untrusted userspace code). Also avoid the "no recovery model" pattern — TorchOS's Recoverability priority is the opposite of "reboot and hope."
- **Sources**:
  - https://github.com/zacharyr0th/SimpleOS (live check, 404)
  - https://github.com/zacharyr0th/simple-os (live check, 404)
  - https://api.github.com/repos/zacharyr0th/SimpleOS (404)
  - https://api.github.com/users/zacharyr0th/repos (200 — confirms repo absent from current public repo list of 12)
  - http://web.archive.org/web/20250805161750/https://github.com/zacharyr0th/simple-os (200, only available snapshot)
  - WebSearch queries for `zacharyr0th SimpleOS` / `simple-os x86 v86 ramfs` (search-engine cache snippets only)
  - https://github.com/MatthiasKroll/simple-os — investigated as a possible match, confirmed **unrelated** (0-star project created 2025-09-08), ruled out.

---

## VibeOS (kaansenol5/VibeOS)

- **Purpose**: A hobby OS "vibecoded" (their term) entirely from scratch for ARM64/aarch64, built as a documented experiment in "what can an LLM build" — collaboratively developed with Claude Code over 64 numbered sessions across ~1.5 months (repo created 2025-12-10, last push 2026-01-27). Explicitly not aiming to be Linux, production-ready, or modern — "Win3.1-style" nostalgia project. Confirmed live: 1,522 stars, 115 forks, MIT license (DOOM port GPL-2.0), 15 open issues, not archived.
- **Base / architecture**: Custom kernel for QEMU's `virt` machine (Cortex-A72) and real Raspberry Pi Zero 2W hardware. Flat address space, **no MMU/no memory protection** — all programs run in kernel space, calling a kernel API (`kapi`) directly rather than through syscalls. Cooperative multitasking (`yield()` + round-robin scheduler) with a later preemptive-multitasking backup added. FAT32 on virtio-blk (QEMU) / SD-EMMC (Pi) as the persistent, host-mountable filesystem. GIC-400 (QEMU) / BCM2835/2836 (Pi) interrupt controllers. Full custom TCP/IP stack (Ethernet/ARP/IP/ICMP/UDP/TCP), DNS, HTTP, hand-rolled TLS 1.2 (TLSe) for HTTPS. GUI desktop (draggable windows, dock, menu bar), 60+ bundled programs, an on-device C compiler (TCC), MicroPython interpreter, and a DOOM port.
- **Agent model**: The central point of interest. Built by a human (kaansenol5) directing Claude Code across 64 discrete, numbered sessions, each producing a persisted log entry. The repo's root `CLAUDE.md` is the persistent context file reloaded every session; `README.md`/`PROGRAMMING.md`/`USAGE.md` round out a documentation hierarchy for overview/app-developers/end-users respectively. No multi-agent orchestration — single-agent, single-human, session-by-session, human as final arbiter.
- **Privilege model**: Not applicable in the security sense (flat, unprotected address space by design). Not a useful reference for TorchOS's broker model directly, but its *documentation* privilege model (what Claude is/isn't allowed to do in the repo) is directly relevant.
- **Recovery model**: None at the OS level. At the *development-process* level, an implicit recovery mechanism exists: the CLAUDE.md's locked-in "Architecture Decisions" table and accumulated "Gotchas" list prevent Claude from re-attempting previously-abandoned approaches (e.g. real syscalls via SVC, external ELF binaries beyond a 5-binary linker limit).
- **Compatibility strategy**: Narrow and deliberate — one emulated target (QEMU virt/Cortex-A72) plus one real board (Pi Zero 2W), small hardware-abstraction differences noted in CLAUDE.md's memory map tables. README is candid that Pi hardware support is partial (no WiFi/Ethernet/audio driver on Pi despite both working under QEMU).
- **UI model**: Full custom GUI (retro Mac/System-7-ish desktop) on a raw framebuffer, no compositor/toolkit — bespoke widget code from scratch. Not applicable to TorchOS (Hyprland/Wayland already solves this).
- **What works well**:
  - A single, disciplined `CLAUDE.md` (~260 lines across 64 sessions), reloaded every session, opening with hard behavioral rules ("Never look at the disk," "`make run` is the only way to compile and run the code," "Trust `make run`") — trust-boundary and tool-usage constraints stated before any technical content.
  - A living checklist ("Current State (Last Updated: Session 40)") — cheap, greppable proof of what's actually done vs. aspirational.
  - A "locked-in" architecture-decisions table (Kernel: Monolithic, Multitasking: Cooperative, Filesystem: FAT32 on virtio-blk) so the agent doesn't re-litigate settled calls each session.
  - A flat, append-only "Gotchas / Lessons Learned" list (~40 entries): exact memory addresses, compiler flags, register/field-level hardware quirks.
  - Per-session logs split into 6 files by ~10-session chunks, each a short bullet list (attempted / broke / abandoned-why / shipped), candid about dead ends (including consulting a different model for a second opinion).
  - Three-tier doc split by audience: CLAUDE.md (agent/technical), PROGRAMMING.md (human dev), USAGE.md (human end-user), README.md (overview + links).
  - Honest, low-ceremony disclaimers next to the features they qualify ("What's Missing on Pi" right under "What Works on Pi").
- **What breaks / limits / fails to generalize**:
  - The **session-log index file has already rotted**: `SESSION_LOG.md` stops at "Session Log 5," missing Session Log 6, even though `SESSION_LOG_6.md` exists and the main README correctly lists all six — a secondary summary doc drifting out of sync with the per-session source of truth.
  - The Gotchas list is unstructured and growing without pruning — already borderline unwieldy at OS-kernel scope.
  - No automated testing/CI — verification is `make run` + human eyeballing, explicit and mandatory per CLAUDE.md's own rules ("never inspect disk state directly, never second-guess the build"). Defensible for a single-human hobby project, not replicable for TorchOS.
  - Some tolerated technical debt visible in the gotchas ("`-O0` everywhere to avoid subtle optimizer bugs," "root cause unknown").
- **What TorchOS should reuse conceptually** (the main point of researching VibeOS — not its kernel):
  1. A single root **CLAUDE.md**, short, opening with hard behavioral/trust-boundary imperatives before any technical content.
  2. A **living, checkbox-style capability/status list**.
  3. A **"locked" architecture-decisions table**, separate from exploratory decision history.
  4. A **flat, append-only gotchas list** for hard-won, non-obvious facts.
  5. **Session logs as the actual decision record** (goal → tried → broke → resolution/pivot), split by chunk with an index that must be regenerated/checked, not hand-maintained forever.
  6. **Audience-segmented docs** instead of one giant file.
  7. Documenting **abandoned approaches and why**.
- **What TorchOS must explicitly avoid**:
  - "Trust the human's eyeball test as the only verification loop" — TorchOS's assistant needs real automated pre/post-checks (snapshot diff, service health, boot success), since it runs "always available," not during a supervised coding session.
  - Tolerating unresolved bugs on anything touching the privileged broker, filesystem mutations, or rollback path.
  - Letting secondary/index documentation silently rot.
  - Letting the gotchas file grow unbounded and unstructured — worth light categorization from the start (by subsystem) given TorchOS's broader surface area than a single kernel.
- **Sources**:
  - https://github.com/kaansenol5/VibeOS
  - https://api.github.com/repos/kaansenol5/VibeOS
  - https://raw.githubusercontent.com/kaansenol5/VibeOS/main/CLAUDE.md (read in full, 260 lines)
  - https://raw.githubusercontent.com/kaansenol5/VibeOS/main/README.md (read in full, 206 lines)
  - https://raw.githubusercontent.com/kaansenol5/VibeOS/main/SESSION_LOG.md (index file — noted as stale)
  - https://raw.githubusercontent.com/kaansenol5/VibeOS/main/SESSION_LOG_1.md
  - https://raw.githubusercontent.com/kaansenol5/VibeOS/main/SESSION_LOG_6.md
  - https://raw.githubusercontent.com/kaansenol5/VibeOS/main/PROGRAMMING.md
  - https://api.github.com/repos/kaansenol5/VibeOS/contents/

---

## Cross-cutting takeaways for TorchOS

1. Keep one short root `CLAUDE.md` opening with hard, imperative trust-boundary rules the agent must never violate: never bypass the privileged broker, always snapshot before a mutating action, never treat a "looks safe" repair as pre-approved, the broker's allowlist is the only privilege path.
2. Separate "locked" decisions from exploratory decision history.
3. Maintain a living, checkbox capability/status section.
4. Maintain a flat, append-only "gotchas" list, lightly categorized by subsystem from the start (systemd / Wayland / PipeWire / Btrfs / broker / AI agent).
5. Log sessions as terse bullet decision records, not prose narratives — record abandoned approaches and why.
6. Split session logs by chunk once long, but don't hand-maintain a separate index without a check.
7. Segment documentation by audience.
8. Disclose limitations honestly and locally, next to the feature they qualify.
9. Don't import "trust the manual smoke test" as the verification model — TorchOS's mechanic needs actual automated pre/post-action checks.
10. Treat documentation staleness as a real failure mode to design against, not just an ideal.
