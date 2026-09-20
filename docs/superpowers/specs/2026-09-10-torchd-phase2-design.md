# TorchOS v2 — Phase 2: `torchd` — Design

Status: **approved by user 2026-09-10**, pending written self-review below.
Author: Claude (Sonnet 5), in conversation with the project owner.
Parent docs: `docs/superpowers/specs/2026-08-24-torchos-v2-architecture-design.md` (locked spec, §7
privilege boundary and §8 AI boundary — not re-litigated here) and
`docs/superpowers/specs/2026-08-26-os-essentials-security-design.md` (§7 `torchd` refinement — the
autonomy-tier/danger-ladder/audit-log policy model this spec makes concrete and implementation-ready).

## 1. Scope

Phase 2 = `torchd` itself (the privilege-broker daemon) plus the `torch` CLI-side commands that
actually exercise it. Explicitly **not** in scope: the AI assistant / Agent SDK / MCP layer (Phase 3
— `torchd` is built so Phase 3's daemon is "just another client," but that client doesn't get built
here), and migrating `scripts/install-apps.sh` to route through `torchd` (a separate follow-up, see
§7 Risks).

**Operation-class scope for v1** (the "medium" option from three considered — narrower would leave
`torch update`/`torch service restart` with nothing to route through; wider would build
`network.dns.set`-class operations with no near-term consumer):
- `snapshot.create`, `snapshot.rollback` — hand-built, no existing D-Bus API covers Btrfs snapshot
  rollback (confirmed in the locked spec's own research).
- `package.install`, `package.remove` — wraps PackageKit's D-Bus API (see §7 Risks — availability on
  CachyOS unverified).
- `service.restart` — wraps `org.freedesktop.systemd1`.

`torch status`/`doctor`/`gpu`/`diagnose`/`snapshot list` are unaffected — they're already
unprivileged reads and stay direct shell-outs. Routing them through `torchd` would add latency for no
security benefit.

## 2. Wire protocol & socket

**Socket**: `/run/torchd/torchd.sock`, owned `root:torch-agent` (a new system group this phase
creates; the `torch` user is added to it), mode `0660`. `torchd` additionally verifies `SO_PEERCRED`
on every connection — not just for the file-permission layer, but to positively identify which user
connected (for the audit log) and to confirm it isn't `root` itself reaching the socket through the
normal-user path.

**Protocol**: newline-delimited JSON, one object per line each direction. `serde`/`serde_json`
(already a project dependency via `torch-welcome`) are the right tool here — unlike
`torch/src/commands/diagnose.rs`'s deliberately flat, hand-rolled JSON (a simple string-keyed map with
no nesting), `torchd` requests/responses have real structure (typed args per operation, confirmation
tokens, audit metadata) that genuinely warrants real (de)serialization rather than hand-rolling.

Request:
```json
{"request_id": "<uuid-v4>", "op": "snapshot.rollback", "args": {"snapshot_id": "42"}}
```
Response:
```json
{"request_id": "<uuid-v4>", "status": "ok|denied|error|needs_confirmation", "result": {}, "message": "human-readable"}
```

**Confirmation flow**: `torchd` is stateless per-request — it does not track "awaiting confirmation"
sessions across the socket. A risky operation gets back `needs_confirmation` with a `confirm_token`;
the CLI (never the daemon) prints the y/n prompt, and on yes, re-sends the identical request with
`{"confirm_token": "..."}` attached. This keeps the daemon simple and matches the "CLI/GUI renders,
the broker decides" split already established for `torch-welcome` (§3 of the Group A design spec).

## 3. Operation classes & danger-tier mapping

Using the A3V danger ladder's *spirit* (additive/read-like actions are low risk, destructive/
consequential ones are high), not a literal 1:1 mapping — `torchd`'s typed operation classes don't
correspond directly to memory/file/shell actions the way A3V's own ladder does for AI-agent tool
calls:

| Operation | Danger tier | Auto-tier behavior | Denylist? |
|---|---|---|---|
| `snapshot.create` | Low | Runs immediately | No |
| `package.install` | Low-medium | Runs immediately | No |
| `service.restart` | Medium | Confirms once | No |
| `package.remove` | Medium-high | Confirms once | No |
| `snapshot.rollback` | High | Confirms once, always — even Trust tier asks | No (rollback is the point of having snapshots; hard-denying it would defeat the feature) |

**Hard denylist** (from the locked spec §7, unchanged, always wins regardless of tier): bootloader/
partition changes, deleting the last-known-good snapshot, disabling `torchd` itself. None of Phase
2's 5 operation classes touch these directly, but the denylist check runs on every request
regardless — no operation class is exempt from being checked against it.

**Autonomy tiers** (from ANOLISA, per the os-essentials spec §7) apply on top of this table:
**Recommend** never auto-runs anything (explain-only); **Auto** (torch CLI's default in Phase 2 —
see §4) follows the table above; **Trust** auto-runs everything except the hard denylist and
`snapshot.rollback`, which always confirms regardless of tier.

## 4. Policy engine: built now, canary values deferred

**Built in Phase 2**: the full tier/denylist/danger-tier dispatch logic described in §3, even though
Phase 2's only client (`torch` CLI, human-typed) has no real use for tier *selection* yet — it always
runs as **Auto**. This is deliberate: building the policy engine as tier-agnostic now means Phase 3's
AI daemon is later just another client requesting a tier, with no need to re-touch `torchd`'s
already-hardened, already-reviewed dispatch core.

**Deferred to Phase 3**: canary-value scanning (synthetic values that should never legitimately
appear in a request, signaling a compromised/injected AI session, per the os-essentials spec §7).
This concept only has a threat model once there's an AI agent in the loop to be injected *into* —
Phase 2's only client is a human typing commands at a terminal, with no injection vector for canary
values to protect against. Building it now would be dead code with nothing exercising it; explicitly
scoped out rather than silently dropped.

**Audit log** (general accountability, independent of the AI-agent threat model above — stays in
Phase 2): `/var/log/torchd/audit.jsonl`, append-only, `root:torch-agent` readable (not root-only —
this is a personal machine; you should be able to review your own action history without `sudo`).
One JSON object per line:
```json
{"timestamp": "2026-09-10T14:32:01Z", "request_id": "<uuid>", "peer_uid": 1000, "peer_user": "torch", "op": "snapshot.rollback", "args": {"snapshot_id": "42"}, "tier": "auto", "decision": "confirmed", "result": "ok", "message": "rolled back to snapshot 42"}
```

## 5. `torch` CLI transition

New `torch/src/torchd_client.rs` module (socket connect/send/receive, and the confirm-prompt loop
from §2), reused by four commands:
- `torch snapshot create` — existing command, becomes a `torchd` client (was a direct `snapper`
  shell-out; Phase 1's own note in `torch/src/main.rs` already flagged this exact transition as the
  target).
- `torch snapshot rollback <id>` — new.
- `torch update` — new; the os-essentials spec's §3 design (a thin wrapper over `pacman` using
  `IgnorePkg`/`IgnoreGroup`) made real, routed through `package.install`/`package.remove`.
- `torch service restart <name>` — new.

`status`/`doctor`/`gpu`/`diagnose`/`snapshot list` are unchanged. `serde`/`serde_json` get added to
`torch/Cargo.toml` (the root package — currently only `clap`/`anyhow`) for the request/response
schema.

## 6. Verification plan

Real checks per operation, not "exit code 0" — per CLAUDE.md's trust-boundary rule that the agent
making a change is never the sole judge it worked, and matching Group A's own verification
discipline:
- `snapshot.create`/`rollback` — a genuine round-trip (create a test file, snapshot, modify the file,
  roll back, confirm the file actually reverted) — not just command success.
- `package.install`/`remove` — `pacman -Q <pkg>` before/after.
- `service.restart` — `systemctl show <svc> -p ActiveEnterTimestamp` actually changes (proves a real
  restart happened, not a no-op that still exits 0).
- Socket security — confirm a user outside `torch-agent` genuinely cannot connect; confirm the
  SO_PEERCRED-identified UID lands correctly in the audit log.
- Denylist — confirm it blocks a denylisted-shaped request even under Trust tier.
- `systemd-analyze security torchd.service` scored for real, not assumed from the hardening
  directives alone.
- Audit log — a sequence of real operations produces correctly-shaped, line-parseable JSONL.

## 7. Risks / open items

- **`scripts/install-apps.sh` still bypasses `torchd`** (direct `sudo pacman`/AUR calls) — it
  predates `torchd` and is not migrated as part of this plan. CLAUDE.md's trust-boundary rule ("never
  bypass `torchd` once it exists") needs a companion note that `install-apps.sh` is a Phase 1/Group A
  bootstrap tool explicitly exempted, not an oversight — otherwise the rule and the shipped script
  visibly contradict each other the moment `torchd` exists.
- **PackageKit's availability on CachyOS is unverified.** Arch-family systems don't universally ship
  it (it's more of a cross-distro/GNOME-Software abstraction layer than a base-system component). If
  missing or unreliable, `package.install`/`package.remove` may need to hand-build against `pacman`
  directly instead — the same pattern already used for the snapshot operations. Worth checking early
  in implementation, not assumed to just work.
- Testing a privileged daemon during development needs either running the VM as the actual target (it
  already is, per the locked "never touch the host OS" rule) or careful systemd-unit iteration —
  an implementation-plan-level detail, not a design gap.

## Self-review (brainstorming skill checklist)

- **Placeholder scan**: no TBD/TODO markers. The two Risks items (PackageKit availability,
  `install-apps.sh` exemption) are genuine open questions to resolve during implementation, not
  unresolved design decisions — the design's own shape (wrap D-Bus, fall back to hand-building per
  operation class if needed) already accommodates either outcome.
- **Internal consistency**: §1's operation-class scope, §3's danger-tier table, and §5's CLI commands
  all name the same five operations consistently. §4's "Auto tier by default" matches §3's Auto-tier
  behavior column. §2's stateless-confirmation design and §5's `torchd_client.rs` module agree on
  where the confirm-prompt UI lives (client, not daemon).
- **Scope check**: Phase 3 (AI/MCP layer) and the `install-apps.sh` migration are both explicitly
  out, matching the owner's own sequencing (Phase 2 chosen over Group B this session, with Phase 3
  named as a separate future phase in the locked spec's own roadmap).
- **Ambiguity check**: exact socket path, group name, audit log path/permissions, and wire-format
  schema are all stated as literal values, not left as "some format" for the implementation plan to
  invent.

## Next steps

1. Owner reviews this file.
2. Invoke `writing-plans` for a Phase 2 implementation plan.
3. Execute it (with the verification discipline above enforced, not just stated).
