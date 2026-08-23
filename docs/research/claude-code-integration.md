# TorchOS v2 Research: Claude Code / Claude Agent SDK Integration Shape

Researched 2026-08-23 and 2026-08-24 (follow-up) via the `claude-code-guide` agent, with one claim independently verified by direct primary-source fetch.

---

## Round 1 — integration architecture options

Three options were compared for embedding Claude as TorchOS's always-available system-mechanic assistant:

| Option | Verdict |
|---|---|
| **(a) Shell out to the Claude Code CLI per invocation** | Rejected as the primary path. Each `SUPER+SPACE` invocation cold-starts a session — latency and lost context on every call are unacceptable for an assistant invoked repeatedly through the day. |
| **(b) Claude Agent SDK, long-running daemon** | **Recommended.** Persistent process, low per-invocation latency, full harness (tool loop, session state, hooks, native MCP loading). |
| **(c) Raw Messages API + hand-rolled loop** | Rejected — rebuilds what the Agent SDK already provides (context management, hooks, subagent delegation, streaming). Last resort only. |

**Recommended shape**: Agent SDK daemon (long-running) + a custom MCP server exposing `torchd`'s privileged operations (`snapshot.rollback`, `service.restart`, `package.install`, etc.) as named, typed tools — no shell access, no arbitrary command strings reaching the model. HUD talks to the daemon over a local IPC (Unix socket/HTTP); deterministic requests (open Firefox) never reach the model. Model-selection routing (cheap/fast model as default, escalate for complex/risky repairs) was suggested for cost control, with prompt caching for stable diagnostic schemas.

```
HUD / Hyprland Command Palette (SUPER+SPACE)
        │ IPC (Unix socket / HTTP)
Long-running Assistant Loop (Claude Agent SDK)
        │
   MCP Server (system operations: snapshot.rollback, service.restart, ...)
        │
   torchd privilege broker (validates, then escalates safely)
```

**Caveat raised in Round 1** (which triggered the Round 2 follow-up): the SDK was assumed to require a console.anthropic.com API key (metered pay-as-you-go billing), separate from a Claude.ai Pro/Max/Team subscription. The user explicitly wants to use their existing Claude Code subscription as the actual auth/billing mechanism, not stand up separately-billed API usage — this needed direct verification rather than assumption.

---

## Round 2 — subscription auth, verified

The initial follow-up answer (via the same research agent) claimed Agent SDK usage under a subscription-linked API key draws from "the same pool" as normal interactive Claude Code usage. **This was checked directly against the primary source** (`support.claude.com`, "Use the Claude Agent SDK with your Claude plan") rather than taken at face value, because it's a narrow, financially consequential claim that didn't match prior understanding of how Console (API) and Claude.ai (subscription) billing have historically been separated.

**What the primary source actually says, verified 2026-08-24:**

1. **Authentication mechanism**: not detailed in this particular article — the article only confirms that "third-party apps [can] authenticate with your Claude subscription through the Agent SDK" without documenting the exact OAuth/token flow or CLI commands. **Needs a direct doc-check at Phase 3 implementation time**, not assumed now.
2. **Billing**: Agent SDK and `claude -p` (headless mode) usage draws from a **separate monthly credit specific to that channel** — explicitly **not** the same pool as interactive terminal/IDE usage ("Claude Agent SDK and `claude -p` usage no longer counts toward your Claude plan's usage limits"). The credit "drains first"; once exhausted, requests either fall back to metered API rates (if pay-as-you-go credits are enabled) or stop until the monthly refresh — the article doesn't state which is the default behavior.
3. **Limitations**: credits are per-user, non-poolable on Team/Enterprise plans. The credit covers Agent SDK and `claude -p` but *excludes* interactive Claude Code in terminals/IDEs (i.e., it's additive, not a reallocation of the normal coding budget). API-key-only users get no monthly credit at all — they're pay-as-you-go from the start, confirming Agent-SDK-via-subscription and Agent-SDK-via-API-key are two genuinely distinct billing paths.
4. **Unattended/background use**: no mention anywhere in the article of rate limits or restrictions specific to running this unattended/programmatically vs. a human typing `claude -p` by hand. **Genuinely unverified** — worth testing empirically once Phase 3 is actually built, not assumed safe or assumed restricted.

### Practical implication for TorchOS
This is good news for the ambient-assistant use case: it draws from a dedicated credit pool that won't compete with normal coding-session usage. It is *not* unlimited, though — it's a capped monthly allotment specific to this channel. The design should degrade gracefully if that credit runs dry mid-month: tell the user plainly ("assistant credit exhausted, resets on `<date>`") rather than silently falling back to metered billing or failing opaquely.

### Sources
- https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan (fetched directly, primary source, 2026-08-24)
- https://code.claude.com/docs/en/headless.md (Round 1)
- https://platform.claude.com/docs/en/managed-agents/overview (Round 1)
- https://platform.claude.com/docs/en/managed-agents/session-operations (Round 1)
- Round 1's secondhand claims about a "June 15, 2026 billing change" being paused, exact Pro/Max weekly "Sonnet hour" quotas, and a "console API key linked to your subscription" mechanism were **not** independently corroborated in Round 2 and should be treated as unverified color, not fact — the verified finding above (separate monthly credit, drains first, no stated unattended-use policy) supersedes them.

---

## Cross-cutting takeaway for TorchOS

**§8 (AI/Claude boundary) recommendation stands**: Claude Agent SDK + a custom MCP server wrapping `torchd`'s operations, long-running local daemon for low `SUPER+SPACE` latency, deterministic requests routed away from the model entirely, builder/reviewer/adversarial-auditor verification discipline (see `fableos-antigravity.md`), structurally separate action log. **Auth path: the Agent SDK's Claude-plan credit, not a console API key** — exact setup mechanics and unattended-use behavior are open items to confirm against current docs when Phase 3 is actually built, with graceful degrade-on-credit-exhaustion designed in from the start rather than retrofitted.
