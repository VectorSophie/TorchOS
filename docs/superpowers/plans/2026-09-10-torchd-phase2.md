# Phase 2: torchd Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `torchd`, a privileged broker daemon exposing 5 typed operation classes (snapshot
create/rollback, package install/remove, service restart) over a Unix socket, with a policy engine
(autonomy tiers, hard denylist, danger-tier confirmation) and an append-only audit log — then make
`torch` CLI a real client of it.

**Architecture:** `torchd` is a new Rust binary crate (`torch/torchd/`) in the existing Cargo
workspace, running as its own systemd service. It listens on `/run/torchd/torchd.sock`
(`root:torch-agent`, mode `0660`), speaks newline-delimited JSON, verifies the connecting peer via
`SO_PEERCRED`, runs every request through a policy engine before dispatch, executes operations by
shelling out to `snapper`/`pacman`/`systemctl` (not a D-Bus client library — see Global Constraints),
and logs every decision to a JSONL audit file. `torch` CLI gains a `torchd_client` module and four
commands that use it.

**Tech Stack:** Rust (matching the existing `torch`/`torch-welcome` crates), `serde`/`serde_json`
(already a workspace dependency via `torch-welcome`), `uuid` (new — request IDs), std library only
otherwise (`std::os::unix::net::UnixListener`/`UnixStream::peer_cred()`, both stable, no `libc` crate
needed).

## Global Constraints

- Socket: `/run/torchd/torchd.sock`, owned `root:torch-agent`, mode `0660`.
- Wire protocol: newline-delimited JSON, one object per line each direction. Exact request shape:
  `{"request_id": "<uuid-v4>", "op": "<op-name>", "args": {...}, "confirm_token": "<optional>"}`.
  Exact response shape: `{"request_id": "...", "status": "ok|denied|error|needs_confirmation", "result": {...}|null, "message": "...", "confirm_token": "<optional, only on needs_confirmation>"}`.
- 5 operation classes only, exact names: `snapshot.create`, `snapshot.rollback`, `package.install`,
  `package.remove`, `service.restart`.
- Danger-tier table (exact, from the spec — Auto-tier behavior column matters most since `torch` CLI
  always runs as Auto in Phase 2):

  | Operation | Auto-tier behavior |
  |---|---|
  | `snapshot.create` | runs immediately |
  | `package.install` | runs immediately |
  | `service.restart` | confirms once |
  | `package.remove` | confirms once |
  | `snapshot.rollback` | confirms once, always — even Trust tier asks |

- Hard denylist (bootloader/partition changes, deleting the last-known-good snapshot, disabling
  `torchd` itself) always wins regardless of tier — checked on every request, though none of the 5
  operation classes touch these directly in Phase 2 (the check exists for future operation classes
  too).
- Audit log: `/var/log/torchd/audit.jsonl`, append-only, `root:torch-agent` readable, one JSON object
  per line.
- **No D-Bus client library** (`zbus` or similar) — the design spec's own Risk #2 flags PackageKit's
  availability on CachyOS as unverified, so this plan shells out to `pacman`/`systemctl`/`snapper`
  directly instead, isolated in `torchd/src/ops/*.rs` so swapping to real D-Bus wrapping later (if
  PackageKit turns out reliable) is a contained change to those 3 files, not a rewrite. This matches
  the existing codebase's own established pattern (`torch/src/commands/*.rs` all shell out directly
  already).
- Canary-value scanning is explicitly **out of scope** for this plan (deferred to Phase 3 — no AI
  client exists yet to have an injection threat model).
- VM-only, per CLAUDE.md's trust-boundary rules — never touch the dev host. Snapshot before any
  mutating privileged action while testing (`snapper create -d "<what>" -u important=yes`).

---

## File Structure

```
torch/Cargo.toml                        # modified — adds "torchd" workspace member
torch/torchd/Cargo.toml                 # new
torch/torchd/src/main.rs                # new — socket listener, connection loop, request dispatch
torch/torchd/src/protocol.rs            # new — Request/Response/Status types
torch/torchd/src/policy.rs              # new — tier/denylist/danger-tier decision logic
torch/torchd/src/audit.rs               # new — JSONL audit log writer
torch/torchd/src/ops/mod.rs             # new — Op enum + dispatch trait
torch/torchd/src/ops/snapshot.rs        # new — snapshot.create / snapshot.rollback
torch/torchd/src/ops/package.rs         # new — package.install / package.remove
torch/torchd/src/ops/service.rs         # new — service.restart
torch/torchd.service                    # new — systemd unit (lives at repo root's deployable-units
                                         #   location; not under torch/ since it's not Rust source)
torch/Cargo.toml                        # torch (root) gains serde/serde_json/uuid deps
torch/src/torchd_client.rs              # new — socket client + confirm-prompt loop
torch/src/main.rs                       # modified — new subcommands
torch/src/commands/snapshot.rs          # modified — create() becomes a torchd client; +rollback()
torch/src/commands/update.rs            # new
torch/src/commands/service.rs           # new
```

---

### Task 1: `torchd` crate scaffold — protocol types + echo server

**Files:**
- Modify: `torch/Cargo.toml`
- Create: `torch/torchd/Cargo.toml`
- Create: `torch/torchd/src/protocol.rs`
- Create: `torch/torchd/src/main.rs`

**Interfaces:**
- Produces: `protocol::Request { request_id: String, op: String, args: serde_json::Value,
  confirm_token: Option<String> }`, `protocol::Response { request_id: String, status: Status,
  result: Option<serde_json::Value>, message: String, confirm_token: Option<String> }`, `enum Status {
  Ok, Denied, Error, NeedsConfirmation }` (serializes lowercase via `#[serde(rename_all =
  "snake_case")]`), `Response::error(request_id: &str, message: impl Into<String>) -> Response`. Later
  tasks build on these exact names/fields.

- [ ] **Step 1: Add the workspace member**

`torch/Cargo.toml` — add `"torchd"` to the members list:
```toml
[workspace]
members = [".", "torch-welcome", "torchd"]

[package]
name = "torch"
version = "0.1.0"
edition = "2021"

[dependencies]
clap = { version = "4", features = ["derive"] }
anyhow = "1"
```

- [ ] **Step 2: Create the torchd crate manifest**

`torch/torchd/Cargo.toml`:
```toml
[package]
name = "torchd"
version = "0.1.0"
edition = "2021"

[dependencies]
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
uuid = { version = "1", features = ["v4"] }
```

- [ ] **Step 3: Write the protocol types**

`torch/torchd/src/protocol.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    pub request_id: String,
    pub op: String,
    #[serde(default = "default_args")]
    pub args: serde_json::Value,
    #[serde(default)]
    pub confirm_token: Option<String>,
}

fn default_args() -> serde_json::Value {
    serde_json::Value::Null
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Ok,
    Denied,
    Error,
    NeedsConfirmation,
}

#[derive(Debug, Clone, Serialize)]
pub struct Response {
    pub request_id: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confirm_token: Option<String>,
}

impl Response {
    pub fn error(request_id: &str, message: impl Into<String>) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::Error,
            result: None,
            message: message.into(),
            confirm_token: None,
        }
    }

    pub fn ok(request_id: &str, message: impl Into<String>, result: Option<serde_json::Value>) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::Ok,
            result,
            message: message.into(),
            confirm_token: None,
        }
    }

    pub fn denied(request_id: &str, message: impl Into<String>) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::Denied,
            result: None,
            message: message.into(),
            confirm_token: None,
        }
    }

    pub fn needs_confirmation(request_id: &str, message: impl Into<String>, confirm_token: String) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::NeedsConfirmation,
            result: None,
            message: message.into(),
            confirm_token: Some(confirm_token),
        }
    }
}
```

- [ ] **Step 4: Write the echo-server main.rs** (stub dispatch — Task 7 replaces the stub with the
  real policy/audit/ops-wired handler; this task's only job is proving the socket+protocol works)

`torch/torchd/src/main.rs`:
```rust
use anyhow::{Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};

mod protocol;

use protocol::{Request, Response};

// Task 2 moves this to /run/torchd/torchd.sock with real ownership/permissions.
// Kept as a plain /tmp path here so this task's echo-server can be tested without
// root or systemd involved at all.
const SOCKET_PATH: &str = "/tmp/torchd-dev.sock";

fn main() -> Result<()> {
    let _ = std::fs::remove_file(SOCKET_PATH);
    let listener =
        UnixListener::bind(SOCKET_PATH).with_context(|| format!("failed to bind {SOCKET_PATH}"))?;
    println!("torchd listening on {SOCKET_PATH}");

    for stream in listener.incoming() {
        let stream = stream.context("accept failed")?;
        if let Err(e) = handle_client(stream) {
            eprintln!("client error: {e:#}");
        }
    }
    Ok(())
}

fn handle_client(stream: UnixStream) -> Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.trim().is_empty() {
        return Ok(());
    }

    let response = match serde_json::from_str::<Request>(&line) {
        Ok(req) => Response::error(&req.request_id, "not implemented yet"),
        Err(e) => Response::error("unknown", format!("bad request: {e}")),
    };

    let out = serde_json::to_string(&response)?;
    writeln!(writer, "{out}")?;
    Ok(())
}
```

- [ ] **Step 5: Build and manually verify on the VM**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 -p torchd'
```
Expected: builds clean for both `torch` and `torchd` (the workspace still builds `torch` unaffected —
confirm with `cargo build -j 1 -p torch` too).

```bash
ssh -p 2222 torch@localhost 'cd ~/torch && ./target/debug/torchd &'
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"1\",\"op\":\"snapshot.create\",\"args\":{}}" | socat - UNIX-CONNECT:/tmp/torchd-dev.sock'
```
Expected: `{"request_id":"1","status":"error","message":"not implemented yet"}` — a well-formed
response, proving the socket/protocol round-trip works end to end.

- [ ] **Step 6: Commit**

```bash
git add torch/Cargo.toml torch/torchd/Cargo.toml torch/torchd/src
git commit -m "feat: torchd crate scaffold with protocol types and echo server"
```

---

### Task 2: Real socket path, permissions, and SO_PEERCRED identity

**Files:**
- Modify: `torch/torchd/src/main.rs`

**Interfaces:**
- Consumes: `protocol::{Request, Response}` from Task 1.
- Produces: `fn peer_identity(stream: &UnixStream) -> Result<(u32, u32)>` (returns `(uid, gid)`,
  errors if the connecting peer is uid 0 / root). Task 7's real dispatch handler uses this to reject
  root connections and to populate the audit log's `peer_uid` field.

- [ ] **Step 1: Create the `torch-agent` group on the VM** (one-time machine setup, not code — this
  socket's ownership depends on the group existing)

```bash
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k groupadd -r torch-agent'
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k usermod -aG torch-agent torch'
```
Verify: `ssh -p 2222 torch@localhost 'getent group torch-agent'` shows the group with `torch` as a
member (a fresh login may be needed for the group membership to apply to a *new* SSH session — the
existing Gotcha about group grants not applying retroactively applies here too).

- [ ] **Step 2: Move the socket to its real path with real ownership**

`torch/torchd/src/main.rs` — replace the `SOCKET_PATH` constant and `main()`'s bind logic:
```rust
use std::os::unix::fs::PermissionsExt;

const SOCKET_DIR: &str = "/run/torchd";
const SOCKET_PATH: &str = "/run/torchd/torchd.sock";

fn main() -> Result<()> {
    std::fs::create_dir_all(SOCKET_DIR).with_context(|| format!("creating {SOCKET_DIR}"))?;
    let _ = std::fs::remove_file(SOCKET_PATH);
    let listener =
        UnixListener::bind(SOCKET_PATH).with_context(|| format!("failed to bind {SOCKET_PATH}"))?;

    // 0660 root:torch-agent — the file-permission layer is the primary access
    // control; SO_PEERCRED (below) is defense-in-depth identifying *who*
    // connected, not the thing that decides *whether* they're allowed to.
    std::fs::set_permissions(SOCKET_PATH, std::fs::Permissions::from_mode(0o660))
        .context("setting socket permissions")?;
    let status = std::process::Command::new("chown")
        .arg("root:torch-agent")
        .arg(SOCKET_PATH)
        .status()
        .context("running chown")?;
    if !status.success() {
        anyhow::bail!("chown root:torch-agent {SOCKET_PATH} failed");
    }

    println!("torchd listening on {SOCKET_PATH}");
    for stream in listener.incoming() {
        let stream = stream.context("accept failed")?;
        if let Err(e) = handle_client(stream) {
            eprintln!("client error: {e:#}");
        }
    }
    Ok(())
}
```

- [ ] **Step 2: Add peer-identity extraction**

`torch/torchd/src/main.rs` — add this function and use it at the top of `handle_client`:
```rust
fn peer_identity(stream: &UnixStream) -> Result<(u32, u32)> {
    let cred = stream.peer_cred().context("reading SO_PEERCRED")?;
    let uid = cred.uid();
    let gid = cred.gid();
    if uid == 0 {
        anyhow::bail!("connections from uid 0 (root) are rejected — connect as the torch user instead");
    }
    Ok((uid, gid))
}
```

Update `handle_client` to call it first and short-circuit on failure:
```rust
fn handle_client(stream: UnixStream) -> Result<()> {
    let (peer_uid, _peer_gid) = match peer_identity(&stream) {
        Ok(id) => id,
        Err(e) => {
            let mut writer = stream;
            let resp = Response::error("unknown", format!("rejected: {e}"));
            writeln!(writer, "{}", serde_json::to_string(&resp)?)?;
            return Ok(());
        }
    };
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.trim().is_empty() {
        return Ok(());
    }

    let response = match serde_json::from_str::<Request>(&line) {
        Ok(req) => Response::error(&req.request_id, format!("not implemented yet (peer_uid={peer_uid})")),
        Err(e) => Response::error("unknown", format!("bad request: {e}")),
    };

    let out = serde_json::to_string(&response)?;
    writeln!(writer, "{out}")?;
    Ok(())
}
```

- [ ] **Step 3: Verify on the VM — authorized connection works, unauthorized is rejected at the OS
  level**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 -p torchd'
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k bash -c "setsid nohup ~/torch/target/debug/torchd > /tmp/torchd.log 2>&1 < /dev/null &"'
ssh -p 2222 torch@localhost 'ls -la /run/torchd/torchd.sock'
```
Expected: socket exists, `-rw-rw---- 1 root torch-agent`.

```bash
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"1\",\"op\":\"x\",\"args\":{}}" | socat - UNIX-CONNECT:/run/torchd/torchd.sock'
```
Expected (as `torch`, a `torch-agent` member): a response containing `peer_uid=1000` (torch's real
uid), proving SO_PEERCRED correctly identified the caller.

```bash
ssh -p 2222 torch@localhost 'sudo -u nobody socat - UNIX-CONNECT:/run/torchd/torchd.sock <<< "test"'
```
Expected: `Permission denied` from `socat` itself — `nobody` isn't in `torch-agent`, so the 0660 file
permission blocks the connection before torchd's own code even runs. (If `nobody` has no valid shell/
can't be `sudo -u`'d directly, use any other real non-`torch-agent` user instead — the point is
confirming the OS-level file-permission layer, not this specific test user.)

- [ ] **Step 4: Commit**

```bash
git add torch/torchd/src/main.rs
git commit -m "feat: torchd real socket path, permissions, and SO_PEERCRED identity"
```

---

### Task 3: Policy engine — denylist, autonomy tiers, danger-tier table

**Files:**
- Create: `torch/torchd/src/policy.rs`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure logic module).
- Produces: `enum Tier { Recommend, Auto, Trust }`, `enum Decision { AutoApprove, NeedsConfirmation,
  Denied(String) }`, `fn decide(op: &str, tier: Tier, has_confirmation: bool) -> Decision`. Task 7's
  real dispatch handler calls `decide()` for every request before running an operation.

- [ ] **Step 1: Write the failing tests** (table-driven, covering every row of the Global Constraints
  danger-tier table plus the denylist)

`torch/torchd/src/policy.rs`:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Recommend,
    Auto,
    Trust,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    AutoApprove,
    NeedsConfirmation,
    Denied(String),
}

// Bootloader/partition changes and disabling torchd itself have no operation
// class yet in Phase 2 (see the plan's Global Constraints) — this list exists
// so future operation classes are denylist-checked from day one, not added
// later as an afterthought.
const HARD_DENYLIST: &[&str] = &["bootloader.modify", "partition.modify", "torchd.disable"];

pub fn decide(op: &str, tier: Tier, has_confirmation: bool) -> Decision {
    if HARD_DENYLIST.contains(&op) {
        return Decision::Denied(format!("{op} is on the hard denylist — no tier can bypass it"));
    }

    if tier == Tier::Recommend {
        return Decision::NeedsConfirmation;
    }

    // snapshot.rollback always confirms, even in Trust — per the design spec's
    // §3, rollback is high-danger enough that no autonomy tier auto-runs it.
    if op == "snapshot.rollback" {
        return if has_confirmation {
            Decision::AutoApprove
        } else {
            Decision::NeedsConfirmation
        };
    }

    let auto_runs_immediately = matches!(op, "snapshot.create" | "package.install");
    if tier == Tier::Trust || auto_runs_immediately {
        return Decision::AutoApprove;
    }

    // tier == Auto, and op is one of the "confirms once" ops (service.restart,
    // package.remove) per the danger-tier table.
    if has_confirmation {
        Decision::AutoApprove
    } else {
        Decision::NeedsConfirmation
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn denylist_always_wins_regardless_of_tier() {
        for tier in [Tier::Recommend, Tier::Auto, Tier::Trust] {
            assert!(matches!(decide("bootloader.modify", tier, true), Decision::Denied(_)));
        }
    }

    #[test]
    fn recommend_tier_never_auto_approves() {
        for op in ["snapshot.create", "package.install", "service.restart", "package.remove", "snapshot.rollback"] {
            assert_eq!(decide(op, Tier::Recommend, false), Decision::NeedsConfirmation);
        }
    }

    #[test]
    fn auto_tier_matches_danger_table() {
        assert_eq!(decide("snapshot.create", Tier::Auto, false), Decision::AutoApprove);
        assert_eq!(decide("package.install", Tier::Auto, false), Decision::AutoApprove);
        assert_eq!(decide("service.restart", Tier::Auto, false), Decision::NeedsConfirmation);
        assert_eq!(decide("service.restart", Tier::Auto, true), Decision::AutoApprove);
        assert_eq!(decide("package.remove", Tier::Auto, false), Decision::NeedsConfirmation);
        assert_eq!(decide("package.remove", Tier::Auto, true), Decision::AutoApprove);
    }

    #[test]
    fn rollback_always_confirms_even_in_trust() {
        assert_eq!(decide("snapshot.rollback", Tier::Trust, false), Decision::NeedsConfirmation);
        assert_eq!(decide("snapshot.rollback", Tier::Trust, true), Decision::AutoApprove);
        assert_eq!(decide("snapshot.rollback", Tier::Auto, false), Decision::NeedsConfirmation);
    }

    #[test]
    fn trust_tier_auto_approves_everything_except_rollback_and_denylist() {
        for op in ["snapshot.create", "package.install", "service.restart", "package.remove"] {
            assert_eq!(decide(op, Tier::Trust, false), Decision::AutoApprove);
        }
    }
}
```

- [ ] **Step 2: Wire the module into main.rs**

`torch/torchd/src/main.rs` — add near the top:
```rust
mod policy;
```

- [ ] **Step 3: Run the tests on the VM**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo test -j 1 -p torchd'
```
Expected: all 5 tests pass (`denylist_always_wins_regardless_of_tier`,
`recommend_tier_never_auto_approves`, `auto_tier_matches_danger_table`,
`rollback_always_confirms_even_in_trust`, `trust_tier_auto_approves_everything_except_rollback_and_denylist`).

- [ ] **Step 4: Commit**

```bash
git add torch/torchd/src/main.rs torch/torchd/src/policy.rs
git commit -m "feat: torchd policy engine (tiers, denylist, danger-tier table)"
```

---

### Task 4: Audit log writer

**Files:**
- Create: `torch/torchd/src/audit.rs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct AuditEvent { timestamp: String, request_id: String, peer_uid: u32, peer_user:
  String, op: String, args: serde_json::Value, tier: String, decision: String, result: String,
  message: String }` (all fields `pub`, `Serialize`), `fn append(path: &str, event: &AuditEvent) ->
  Result<()>`. Task 7's real dispatch handler constructs an `AuditEvent` per request and calls
  `append()`.

- [ ] **Step 1: Write the failing test**

`torch/torchd/src/audit.rs`:
```rust
use anyhow::{Context, Result};
use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;

#[derive(Debug, Clone, Serialize)]
pub struct AuditEvent {
    pub timestamp: String,
    pub request_id: String,
    pub peer_uid: u32,
    pub peer_user: String,
    pub op: String,
    pub args: serde_json::Value,
    pub tier: String,
    pub decision: String,
    pub result: String,
    pub message: String,
}

pub fn append(path: &str, event: &AuditEvent) -> Result<()> {
    let line = serde_json::to_string(event).context("serializing audit event")?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening audit log {path}"))?;
    writeln!(file, "{line}").context("writing audit line")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;

    #[test]
    fn appends_valid_parseable_jsonl() {
        let dir = std::env::temp_dir().join(format!("torchd-audit-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("audit.jsonl");
        let path_str = path.to_str().unwrap();

        for i in 0..3 {
            let event = AuditEvent {
                timestamp: "2026-09-10T00:00:00Z".to_string(),
                request_id: format!("req-{i}"),
                peer_uid: 1000,
                peer_user: "torch".to_string(),
                op: "snapshot.create".to_string(),
                args: serde_json::json!({"description": "test"}),
                tier: "auto".to_string(),
                decision: "auto_approved".to_string(),
                result: "ok".to_string(),
                message: "created".to_string(),
            };
            append(path_str, &event).unwrap();
        }

        let file = std::fs::File::open(&path).unwrap();
        let lines: Vec<String> = std::io::BufReader::new(file)
            .lines()
            .collect::<std::io::Result<_>>()
            .unwrap();
        assert_eq!(lines.len(), 3, "expected 3 appended lines");
        for (i, line) in lines.iter().enumerate() {
            let parsed: serde_json::Value = serde_json::from_str(line).expect("each line must be valid JSON");
            assert_eq!(parsed["request_id"], format!("req-{i}"));
            assert_eq!(parsed["peer_user"], "torch");
        }

        std::fs::remove_dir_all(&dir).ok();
    }
}
```

- [ ] **Step 2: Add `uuid` as a dev-dependency for the test, and wire the module**

`torch/torchd/Cargo.toml` — add a `[dev-dependencies]` section (uuid is already a normal dependency
from Task 1, so this step just confirms it's usable in tests, which it already is since normal deps
are available to `#[cfg(test)]` code too — no Cargo.toml change actually needed here; skip if `cargo
test` already passes without one).

`torch/torchd/src/main.rs` — add:
```rust
mod audit;
```

- [ ] **Step 3: Run the test on the VM**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo test -j 1 -p torchd appends_valid_parseable_jsonl -- --nocapture'
```
Expected: `test audit::tests::appends_valid_parseable_jsonl ... ok`.

- [ ] **Step 4: Commit**

```bash
git add torch/torchd/src/main.rs torch/torchd/src/audit.rs torch/torchd/Cargo.toml
git commit -m "feat: torchd JSONL audit log writer"
```

---

### Task 5: `snapshot.create` and `snapshot.rollback` operations

**Files:**
- Create: `torch/torchd/src/ops/mod.rs`
- Create: `torch/torchd/src/ops/snapshot.rs`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (pure operation-execution module; Task 7 wires it to
  policy/audit).
- Produces: `ops::snapshot::create(args: &serde_json::Value) -> Result<String>` (returns a
  human-readable success message), `ops::snapshot::rollback(args: &serde_json::Value) ->
  Result<String>`. Task 7 calls these by matching on `Request.op`.

- [ ] **Step 1: Create the ops module root**

`torch/torchd/src/ops/mod.rs`:
```rust
pub mod package;
pub mod service;
pub mod snapshot;
```

- [ ] **Step 2: Write snapshot ops**

`torch/torchd/src/ops/snapshot.rs`:
```rust
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct CreateArgs {
    description: String,
}

#[derive(Deserialize)]
struct RollbackArgs {
    snapshot_id: String,
}

pub fn create(args: &serde_json::Value) -> Result<String> {
    let args: CreateArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.create")?;
    let status = Command::new("snapper")
        .args(["-c", "root", "create", "-d", &args.description, "-u", "important=yes"])
        .status()
        .context("running snapper create")?;
    if !status.success() {
        bail!("snapper create failed");
    }
    Ok(format!("snapshot created: {}", args.description))
}

// snapper rollback is NOT instant — it creates a new snapshot pair and sets
// the target as the default subvolume for the *next boot*. Message the
// caller honestly rather than implying this takes effect immediately.
pub fn rollback(args: &serde_json::Value) -> Result<String> {
    let args: RollbackArgs = serde_json::from_value(args.clone()).context("bad args for snapshot.rollback")?;
    let status = Command::new("snapper")
        .args(["-c", "root", "rollback", &args.snapshot_id])
        .status()
        .context("running snapper rollback")?;
    if !status.success() {
        bail!("snapper rollback failed");
    }
    Ok(format!(
        "rollback to snapshot {} prepared — reboot to complete it",
        args.snapshot_id
    ))
}
```

- [ ] **Step 3: Wire the module into main.rs**

`torch/torchd/src/main.rs` — add:
```rust
mod ops;
```

- [ ] **Step 4: Build on the VM (no dispatch wiring yet — that's Task 7 — this just confirms the
  module compiles)**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 -p torchd'
```
Expected: builds clean. `package.rs`/`service.rs` don't exist yet, so `mod package;`/`mod service;`
in `ops/mod.rs` will fail to compile until Task 6/7 create them — **for this task only**, comment out
those two lines in `ops/mod.rs`, leaving just `pub mod snapshot;`, and Task 6 uncomments `pub mod
package;` when it adds that file.

`torch/torchd/src/ops/mod.rs` (this task's actual version):
```rust
pub mod snapshot;
```
(Task 6 changes this to add `pub mod package;`, Task 7 adds `pub mod service;`.)

- [ ] **Step 5: Real verification — call `create` directly via a tiny test binary is unnecessary;
  verify by exercising it through Task 1's existing echo path won't work yet either (dispatch isn't
  wired). Instead, verify the underlying command is correct by running it directly on the VM once,
  matching exactly what the Rust code invokes:**

```bash
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k snapper -c root create -d "torchd Task 5 verification" -u important=yes'
ssh -p 2222 torch@localhost 'snapper -c root list | tail -3'
```
Expected: a new snapshot appears in the list with the matching description — confirms the exact
command `create()` runs is correct real snapper syntax. (Full end-to-end verification through
`torchd` itself happens in Task 7, once dispatch is wired.)

- [ ] **Step 6: Commit**

```bash
git add torch/torchd/src/main.rs torch/torchd/src/ops
git commit -m "feat: torchd snapshot.create and snapshot.rollback operations"
```

---

### Task 6: `package.install` and `package.remove` operations

**Files:**
- Create: `torch/torchd/src/ops/package.rs`
- Modify: `torch/torchd/src/ops/mod.rs`

**Interfaces:**
- Consumes: nothing from earlier tasks directly.
- Produces: `ops::package::install(args: &serde_json::Value) -> Result<String>`,
  `ops::package::remove(args: &serde_json::Value) -> Result<String>`. Task 7 calls these.

- [ ] **Step 1: Write package ops**

`torch/torchd/src/ops/package.rs`:
```rust
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct PackageArgs {
    names: Vec<String>,
}

pub fn install(args: &serde_json::Value) -> Result<String> {
    let args: PackageArgs = serde_json::from_value(args.clone()).context("bad args for package.install")?;
    if args.names.is_empty() {
        bail!("package.install requires at least one package name");
    }
    let status = Command::new("pacman")
        .arg("-S")
        .arg("--needed")
        .arg("--noconfirm")
        .args(&args.names)
        .status()
        .context("running pacman -S")?;
    if !status.success() {
        bail!("pacman -S failed for: {}", args.names.join(", "));
    }
    Ok(format!("installed: {}", args.names.join(", ")))
}

pub fn remove(args: &serde_json::Value) -> Result<String> {
    let args: PackageArgs = serde_json::from_value(args.clone()).context("bad args for package.remove")?;
    if args.names.is_empty() {
        bail!("package.remove requires at least one package name");
    }
    let status = Command::new("pacman")
        .arg("-R")
        .arg("--noconfirm")
        .args(&args.names)
        .status()
        .context("running pacman -R")?;
    if !status.success() {
        bail!("pacman -R failed for: {}", args.names.join(", "));
    }
    Ok(format!("removed: {}", args.names.join(", ")))
}
```

- [ ] **Step 2: Wire the module in**

`torch/torchd/src/ops/mod.rs`:
```rust
pub mod package;
pub mod snapshot;
```

- [ ] **Step 3: Build on the VM**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 -p torchd'
```
Expected: builds clean (comment out `pub mod service;` reference — it doesn't exist until Task 7 —
this file already omits it above, matching Task 5's note).

- [ ] **Step 4: Real verification — confirm the exact commands work as invoked**

```bash
ssh -p 2222 torch@localhost 'pacman -Q tldr 2>&1 || echo "not installed"'
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k pacman -S --needed --noconfirm tree'
ssh -p 2222 torch@localhost 'pacman -Q tree'
```
Expected: `tree` (a small, harmless package unlikely to already be installed, chosen specifically so
this is a real, verifiable state change rather than a no-op) installs successfully and `pacman -Q
tree` confirms it. Clean up if desired: `sudo pacman -R --noconfirm tree` (optional — leaving it
installed is harmless).

- [ ] **Step 5: Commit**

```bash
git add torch/torchd/src/ops/mod.rs torch/torchd/src/ops/package.rs
git commit -m "feat: torchd package.install and package.remove operations"
```

---

### Task 7: `service.restart` operation + real request dispatch (ties everything together)

**Files:**
- Create: `torch/torchd/src/ops/service.rs`
- Modify: `torch/torchd/src/ops/mod.rs`
- Modify: `torch/torchd/src/main.rs`

**Interfaces:**
- Consumes: `protocol::{Request, Response, Status}` (Task 1), `policy::{Tier, Decision, decide}`
  (Task 3), `audit::{AuditEvent, append}` (Task 4), `ops::snapshot::{create, rollback}` (Task 5),
  `ops::package::{install, remove}` (Task 6).
- Produces: the real `handle_client` — this is the last task that touches `main.rs`'s dispatch logic;
  Task 8 (systemd) and Task 9 (CLI client) treat this as the finished daemon behavior.

- [ ] **Step 1: Write the service op**

`torch/torchd/src/ops/service.rs`:
```rust
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct ServiceArgs {
    name: String,
}

pub fn restart(args: &serde_json::Value) -> Result<String> {
    let args: ServiceArgs = serde_json::from_value(args.clone()).context("bad args for service.restart")?;
    let status = Command::new("systemctl")
        .args(["restart", &args.name])
        .status()
        .context("running systemctl restart")?;
    if !status.success() {
        bail!("systemctl restart {} failed", args.name);
    }
    Ok(format!("restarted: {}", args.name))
}
```

`torch/torchd/src/ops/mod.rs` (final version):
```rust
pub mod package;
pub mod service;
pub mod snapshot;
```

- [ ] **Step 2: Replace `main.rs`'s stub dispatch with the real handler**

`torch/torchd/src/main.rs` — replace `handle_client` entirely (keep everything above it from Task 2 —
`SOCKET_DIR`, `SOCKET_PATH`, `main()`, `peer_identity()` — unchanged):

```rust
mod audit;
mod ops;
mod policy;
mod protocol;

use audit::AuditEvent;
use policy::{decide, Decision, Tier};
use protocol::{Request, Response, Status};

fn handle_client(stream: UnixStream) -> Result<()> {
    let (peer_uid, _peer_gid) = match peer_identity(&stream) {
        Ok(id) => id,
        Err(e) => {
            let mut writer = stream;
            let resp = Response::error("unknown", format!("rejected: {e}"));
            writeln!(writer, "{}", serde_json::to_string(&resp)?)?;
            return Ok(());
        }
    };
    let peer_user = std::process::Command::new("id")
        .args(["-nu", &peer_uid.to_string()])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| peer_uid.to_string());

    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.trim().is_empty() {
        return Ok(());
    }

    let req: Request = match serde_json::from_str(&line) {
        Ok(r) => r,
        Err(e) => {
            let resp = Response::error("unknown", format!("bad request: {e}"));
            writeln!(writer, "{}", serde_json::to_string(&resp)?)?;
            return Ok(());
        }
    };

    // torch CLI is the only Phase 2 client and always runs as Auto (per the
    // design spec §4 — Phase 3's AI daemon is what eventually requests a
    // different tier; no client can do that yet).
    let tier = Tier::Auto;
    let has_confirmation = req.confirm_token.as_deref().is_some_and(|t| !t.is_empty());

    let decision = decide(&req.op, tier, has_confirmation);

    let response = match &decision {
        Decision::Denied(reason) => Response::denied(&req.request_id, reason.clone()),
        Decision::NeedsConfirmation => Response::needs_confirmation(
            &req.request_id,
            format!("{} requires confirmation — resend with confirm_token set", req.op),
            uuid::Uuid::new_v4().to_string(),
        ),
        Decision::AutoApprove => {
            let outcome = run_op(&req.op, &req.args);
            match outcome {
                Ok(msg) => Response::ok(&req.request_id, msg, None),
                Err(e) => Response::error(&req.request_id, format!("{e:#}")),
            }
        }
    };

    let decision_label = match &decision {
        Decision::Denied(_) => "denied",
        Decision::NeedsConfirmation => "needs_confirmation",
        Decision::AutoApprove => "auto_approved",
    };
    let result_label = match response.status {
        Status::Ok => "ok",
        Status::Denied => "denied",
        Status::Error => "error",
        Status::NeedsConfirmation => "needs_confirmation",
    };
    let event = AuditEvent {
        timestamp: chrono_now(),
        request_id: req.request_id.clone(),
        peer_uid,
        peer_user,
        op: req.op.clone(),
        args: req.args.clone(),
        tier: format!("{tier:?}").to_lowercase(),
        decision: decision_label.to_string(),
        result: result_label.to_string(),
        message: response.message.clone(),
    };
    if let Err(e) = audit::append("/var/log/torchd/audit.jsonl", &event) {
        eprintln!("audit log write failed: {e:#}");
    }

    let out = serde_json::to_string(&response)?;
    writeln!(writer, "{out}")?;
    Ok(())
}

fn run_op(op: &str, args: &serde_json::Value) -> Result<String> {
    match op {
        "snapshot.create" => ops::snapshot::create(args),
        "snapshot.rollback" => ops::snapshot::rollback(args),
        "package.install" => ops::package::install(args),
        "package.remove" => ops::package::remove(args),
        "service.restart" => ops::service::restart(args),
        other => anyhow::bail!("unknown operation: {other}"),
    }
}

// No chrono dependency for one timestamp — std::time + a hand-rolled RFC3339
// formatter would be more code than just shelling out `date`, and this isn't
// a hot path (once per request, a broker for a single-user personal
// machine). ponytail: shells out per event; switch to a real time crate if
// this ever needs to handle serious request volume.
fn chrono_now() -> String {
    std::process::Command::new("date")
        .arg("-u")
        .arg("+%Y-%m-%dT%H:%M:%SZ")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}
```

(The `mod audit; mod ops; mod policy; mod protocol;` lines replace the separate `mod` statements
added incrementally in Tasks 2-6 — consolidate them at the top of `main.rs` as shown; remove any
duplicate `mod` lines left over from earlier tasks.)

- [ ] **Step 3: Build and run the full end-to-end flow on the VM**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 -p torchd'
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k pkill -x torchd; sleep 1; echo torchos2026 | sudo -S -k bash -c "setsid nohup ~/torch/target/debug/torchd > /tmp/torchd.log 2>&1 < /dev/null &"'
```

**Low-risk op, auto-approves immediately:**
```bash
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"t1\",\"op\":\"snapshot.create\",\"args\":{\"description\":\"torchd Task 7 e2e\"}}" | socat - UNIX-CONNECT:/run/torchd/torchd.sock'
ssh -p 2222 torch@localhost 'snapper -c root list | tail -3'
```
Expected: `{"request_id":"t1","status":"ok","message":"snapshot created: torchd Task 7 e2e"}` and a
real matching entry in `snapper list`.

**Medium-risk op, needs confirmation then succeeds on resend:**
```bash
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"t2\",\"op\":\"service.restart\",\"args\":{\"name\":\"sshd\"}}" | socat - UNIX-CONNECT:/run/torchd/torchd.sock'
```
Expected: `{"request_id":"t2","status":"needs_confirmation","message":"service.restart requires confirmation...","confirm_token":"<uuid>"}`
```bash
ssh -p 2222 torch@localhost 'systemctl show sshd -p ActiveEnterTimestamp'
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"t2\",\"op\":\"service.restart\",\"args\":{\"name\":\"sshd\"},\"confirm_token\":\"yes\"}" | socat - UNIX-CONNECT:/run/torchd/torchd.sock'
ssh -p 2222 torch@localhost 'systemctl show sshd -p ActiveEnterTimestamp'
```
Expected: second confirm attempt returns `{"status":"ok",...}`, and `ActiveEnterTimestamp` genuinely
changes between the two `systemctl show` calls — proves a real restart happened, not a no-op.

**Denylist:**
```bash
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"t3\",\"op\":\"bootloader.modify\",\"args\":{}}" | socat - UNIX-CONNECT:/run/torchd/torchd.sock'
```
Expected: `{"request_id":"t3","status":"denied","message":"bootloader.modify is on the hard denylist — no tier can bypass it"}`.

**Audit log:**
```bash
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k tail -5 /var/log/torchd/audit.jsonl'
```
Expected: 3 well-formed JSONL lines (one per request above), each parseable, with `peer_uid` = 1000
and `peer_user` = `torch`.

- [ ] **Step 4: Commit**

```bash
git add torch/torchd/src/main.rs torch/torchd/src/ops
git commit -m "feat: torchd service.restart and real request dispatch"
```

---

### Task 8: systemd unit + hardening + security score

**Files:**
- Create: `torch/torchd.service`

**Interfaces:**
- Consumes: the finished `torchd` binary from Task 7.
- Produces: a deployable systemd unit. Task 9 doesn't depend on this file directly (the CLI just
  connects to the socket, however it got started), but this task's real verification requires the
  daemon to actually be running under systemd, not the manual `setsid nohup` pattern used in earlier
  tasks' testing.

- [ ] **Step 1: Write the unit file**

`torch/torchd.service`:
```ini
[Unit]
Description=TorchOS privileged operation broker
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/torchd
Restart=on-failure
RestartSec=2

RuntimeDirectory=torchd
RuntimeDirectoryMode=0750

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
ReadWritePaths=/var/log/torchd /run/torchd
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

Note: `CapabilityBoundingSet=` (empty) means torchd runs with zero Linux capabilities — it must run
as root (for `pacman`/`systemctl`/`snapper` to work) but this strips every *extra* capability beyond
plain root, which `ProtectSystem=strict` and the other directives further constrain. `ReadWritePaths`
explicitly allows only the two paths torchd actually needs to write (`/run/torchd` for the socket,
`/var/log/torchd` for the audit log) despite `ProtectSystem=strict` making everything else read-only.

- [ ] **Step 2: Deploy and verify on the VM**

```bash
scp -P 2222 torch/torchd.service torch@localhost:~/torchd.service
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 --release -p torchd'
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k bash -c "
  pkill -x torchd 2>/dev/null
  mkdir -p /var/log/torchd
  chown root:torch-agent /var/log/torchd
  cp ~/torch/target/release/torchd /usr/local/bin/torchd
  cp ~/torchd.service /etc/systemd/system/torchd.service
  systemctl daemon-reload
  systemctl enable --now torchd.service
"'
```
(Release build needs `CARGO_PROFILE_RELEASE_OPT_LEVEL=1` per CLAUDE.md's "rust builds in the VM"
Gotcha if the plain `cargo build --release` OOMs — use
`CARGO_PROFILE_RELEASE_OPT_LEVEL=1 cargo build -j 1 --release -p torchd` if the first attempt fails.)

```bash
ssh -p 2222 torch@localhost 'systemctl status torchd.service --no-pager'
ssh -p 2222 torch@localhost 'ls -la /run/torchd/torchd.sock'
```
Expected: `active (running)`, socket present with correct ownership (now created via
`RuntimeDirectory=torchd` rather than the manual `mkdir`/`chown` in Task 2's code — both paths lead to
the same result, systemd's mechanism is just the more idiomatic one for a real deployed service).

```bash
ssh -p 2222 torch@localhost 'echo "{\"request_id\":\"s1\",\"op\":\"snapshot.create\",\"args\":{\"description\":\"systemd smoke test\"}}" | socat - UNIX-CONNECT:/run/torchd/torchd.sock'
```
Expected: `{"status":"ok",...}` — confirms the systemd-managed daemon works identically to the
manually-launched one from Task 7.

```bash
ssh -p 2222 torch@localhost 'echo torchos2026 | sudo -S -k systemd-analyze security torchd.service'
```
Expected: a real score printed (not erroring), with most individual checks showing ✓ given the
hardening directives above — read the actual output rather than assuming a specific number, since the
exact score depends on the installed systemd version.

- [ ] **Step 3: Commit**

```bash
git add torch/torchd.service
git commit -m "feat: torchd systemd unit with hardening"
```

---

### Task 9: `torch` CLI client — 4 commands

**Files:**
- Modify: `torch/Cargo.toml`
- Create: `torch/src/torchd_client.rs`
- Modify: `torch/src/main.rs`
- Modify: `torch/src/commands/snapshot.rs`
- Create: `torch/src/commands/update.rs`
- Create: `torch/src/commands/service.rs`

**Interfaces:**
- Consumes: the wire protocol from Task 1/7 (matching JSON shapes exactly — this crate has no
  compile-time dependency on the `torchd` crate, they only share the protocol *shape*, matching how a
  real socket client/server pair works).
- Produces: `torchd_client::call(op: &str, args: serde_json::Value) -> Result<serde_json::Value>`
  (handles the full request/confirm-prompt/resend loop internally, returns the final `result` on
  success, errors on `denied`/`error`). Nothing later consumes this — it's the plan's last task.

- [ ] **Step 1: Add dependencies to the root crate**

`torch/Cargo.toml`:
```toml
[workspace]
members = [".", "torch-welcome", "torchd"]

[package]
name = "torch"
version = "0.1.0"
edition = "2021"

[dependencies]
clap = { version = "4", features = ["derive"] }
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
uuid = { version = "1", features = ["v4"] }
```

- [ ] **Step 2: Write the torchd client module**

`torch/src/torchd_client.rs`:
```rust
use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

const SOCKET_PATH: &str = "/run/torchd/torchd.sock";

pub fn call(op: &str, args: serde_json::Value) -> Result<serde_json::Value> {
    let request_id = uuid::Uuid::new_v4().to_string();
    let response = send(&request_id, op, &args, None)?;

    match response["status"].as_str() {
        Some("ok") => Ok(response["result"].clone()),
        Some("denied") => bail!("denied: {}", response["message"].as_str().unwrap_or("no reason given")),
        Some("error") => bail!("torchd error: {}", response["message"].as_str().unwrap_or("unknown error")),
        Some("needs_confirmation") => {
            println!(
                "{}",
                response["message"].as_str().unwrap_or("this action needs confirmation")
            );
            print!("Proceed? [y/N] ");
            std::io::stdout().flush().ok();
            let mut answer = String::new();
            std::io::stdin().read_line(&mut answer)?;
            if !answer.trim().eq_ignore_ascii_case("y") {
                bail!("cancelled");
            }
            let confirmed = send(&request_id, op, &args, Some("yes"))?;
            match confirmed["status"].as_str() {
                Some("ok") => Ok(confirmed["result"].clone()),
                _ => bail!("torchd error after confirmation: {}", confirmed["message"].as_str().unwrap_or("unknown error")),
            }
        }
        other => bail!("unexpected torchd status: {other:?}"),
    }
}

fn send(
    request_id: &str,
    op: &str,
    args: &serde_json::Value,
    confirm_token: Option<&str>,
) -> Result<serde_json::Value> {
    let mut req = serde_json::json!({
        "request_id": request_id,
        "op": op,
        "args": args,
    });
    if let Some(token) = confirm_token {
        req["confirm_token"] = serde_json::Value::String(token.to_string());
    }

    let mut stream = UnixStream::connect(SOCKET_PATH)
        .with_context(|| format!("connecting to torchd at {SOCKET_PATH} — is it running? (systemctl status torchd)"))?;
    writeln!(stream, "{}", serde_json::to_string(&req)?)?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    serde_json::from_str(&line).context("parsing torchd response")
}

// Convenience wrapper — most commands print the response's own `message`
// field on success rather than needing the raw `result` value.
pub fn call_and_print(op: &str, args: serde_json::Value) -> Result<()> {
    call(op, args)?;
    Ok(())
}
```

Wait — `call()` returns `Ok(response["result"].clone())` but doesn't surface `message` to the caller.
Fix `call_and_print` to actually print something useful by having callers print their own success
message (simplest — each command already knows what it just did), so `call_and_print` isn't needed as
a separate function. Remove it; each command below calls `torchd_client::call(...)` directly and
prints its own message.

- [ ] **Step 3: Wire the module into main.rs and add new subcommands**

`torch/src/main.rs` — add the module declaration and new subcommands:
```rust
use anyhow::Result;
use clap::{Parser, Subcommand};

mod commands {
    pub mod diagnose;
    pub mod doctor;
    pub mod gpu;
    pub mod service;
    pub mod snapshot;
    pub mod status;
    pub mod update;
}
mod torchd_client;

// PHASE 1 NOTE: every command here shells out directly to snapper/systemctl/etc.
// That's a deliberate stopgap, not the target architecture — per the locked design
// (see ../CLAUDE.md), Phase 2 introduces `torchd`, a privileged broker with a typed
// operation surface, and these commands should become thin clients that talk to it
// over its Unix socket instead of invoking system tools directly. Keeping the direct
// shell-outs isolated to commands/*.rs (not scattered through main.rs) is what makes
// that swap a contained change later rather than a rewrite.
//
// PHASE 2 UPDATE: snapshot create/rollback, update, and service restart are now
// torchd clients (see torchd_client.rs). status/doctor/gpu/diagnose/snapshot list
// remain direct — they're unprivileged reads with nothing to broker.

#[derive(Parser)]
#[command(name = "torch")]
#[command(version = "0.1.0")]
#[command(about = "TorchOS CLI — the single human-facing interface to the system", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Show basic host status (uptime, disk, memory)
    Status,
    /// Run basic health checks
    Doctor,
    /// GPU detection
    Gpu,
    /// Structured (JSON) system diagnostics — for scripts and the future AI assistant
    Diagnose,
    /// Btrfs/Snapper snapshot management
    Snapshot {
        #[command(subcommand)]
        action: SnapshotAction,
    },
    /// Install/upgrade packages via torchd
    Update {
        /// Package names to install (omit to just run a full system upgrade)
        packages: Vec<String>,
    },
    /// Restart a systemd service via torchd
    Service {
        #[command(subcommand)]
        action: ServiceAction,
    },
}

#[derive(Subcommand)]
enum SnapshotAction {
    /// List snapshots
    List,
    /// Create a labeled checkpoint snapshot
    Create {
        /// What this snapshot is for, e.g. "before enabling nvidia-open driver"
        description: String,
    },
    /// Roll back to a prior snapshot (takes effect on next reboot)
    Rollback {
        /// Snapshot number, from `torch snapshot list`
        snapshot_id: String,
    },
}

#[derive(Subcommand)]
enum ServiceAction {
    /// Restart a systemd service
    Restart {
        /// Service name, e.g. "NetworkManager"
        name: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Status => commands::status::run()?,
        Commands::Doctor => commands::doctor::run()?,
        Commands::Gpu => commands::gpu::run()?,
        Commands::Diagnose => commands::diagnose::run()?,
        Commands::Snapshot { action } => match action {
            SnapshotAction::List => commands::snapshot::list()?,
            SnapshotAction::Create { description } => commands::snapshot::create(&description)?,
            SnapshotAction::Rollback { snapshot_id } => commands::snapshot::rollback(&snapshot_id)?,
        },
        Commands::Update { packages } => commands::update::run(&packages)?,
        Commands::Service { action } => match action {
            ServiceAction::Restart { name } => commands::service::restart(&name)?,
        },
    }

    Ok(())
}
```

- [ ] **Step 4: Update `snapshot.rs`'s `create()` to use torchd, add `rollback()`**

`torch/src/commands/snapshot.rs` (`list()` stays exactly as-is — it's unprivileged and doesn't touch
torchd; replace `run_snapper`/`create` and add `rollback`):
```rust
use anyhow::{bail, Context, Result};
use std::process::Command;

use crate::torchd_client;

fn run_snapper(args: &[&str]) -> Result<std::process::ExitStatus> {
    Command::new("snapper")
        .args(args)
        .status()
        .context("couldn't run snapper — is it installed? (`torch doctor` checks this)")
}

pub fn list() -> Result<()> {
    let status = run_snapper(&["-c", "root", "list"])?;
    if !status.success() {
        bail!("snapper list failed — is snapper configured for 'root'? (torch doctor checks this)");
    }
    Ok(())
}

pub fn create(description: &str) -> Result<()> {
    println!("Creating checkpoint: {description}");
    torchd_client::call(
        "snapshot.create",
        serde_json::json!({"description": description}),
    )?;
    println!("Checkpoint created. Run `torch snapshot list` to see it.");
    Ok(())
}

pub fn rollback(snapshot_id: &str) -> Result<()> {
    let result = torchd_client::call(
        "snapshot.rollback",
        serde_json::json!({"snapshot_id": snapshot_id}),
    )?;
    println!("{}", result.as_str().unwrap_or("rollback prepared — reboot to complete it"));
    Ok(())
}
```

- [ ] **Step 5: Write `torch update`**

`torch/src/commands/update.rs`:
```rust
use anyhow::Result;

use crate::torchd_client;

pub fn run(packages: &[String]) -> Result<()> {
    if packages.is_empty() {
        println!("No packages given — `torch update <pkg>...` installs/upgrades specific packages.");
        println!("(A full-system `pacman -Syu` wrapper is a possible future addition, not built here.)");
        return Ok(());
    }
    println!("Installing: {}", packages.join(", "));
    torchd_client::call(
        "package.install",
        serde_json::json!({"names": packages}),
    )?;
    println!("Done.");
    Ok(())
}
```

- [ ] **Step 6: Write `torch service restart`**

`torch/src/commands/service.rs`:
```rust
use anyhow::Result;

use crate::torchd_client;

pub fn restart(name: &str) -> Result<()> {
    println!("Restarting: {name}");
    torchd_client::call("service.restart", serde_json::json!({"name": name}))?;
    println!("Done.");
    Ok(())
}
```

- [ ] **Step 7: Fix the `torchd_client.rs` `call_and_print` issue found while writing this task**
  (per the note in Step 2 — remove the unused function)

`torch/src/torchd_client.rs` — delete the `call_and_print` function entirely; it's unused since every
command above calls `torchd_client::call(...)` directly and prints its own success message.

- [ ] **Step 8: Build on the VM and run the full end-to-end CLI flow**

```bash
scp -r torch torch@localhost:~/torch -P 2222
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build -j 1 -p torch'
```
Expected: builds clean.

```bash
ssh -p 2222 torch@localhost '~/torch/target/debug/torch snapshot create "torch CLI Task 9 e2e"'
ssh -p 2222 torch@localhost 'snapper -c root list | tail -3'
```
Expected: real success message, real new snapshot entry.

```bash
ssh -p 2222 torch@localhost '~/torch/target/debug/torch update tree 2>&1'
```
Expected: since `tree` is likely already installed from Task 6's verification, this either
no-ops cleanly via `pacman -S --needed` or confirms/installs — either way, no crash, real
`pacman -Q tree` still shows it installed afterward.

```bash
ssh -p 2222 torch@localhost 'echo "n" | ~/torch/target/debug/torch service restart sshd'
```
Expected: prints the confirmation message, reads `n`, prints `cancelled` (via the `Err` from
`torchd_client::call`, surfaced by `anyhow` — confirm the exact CLI output, adjust
`commands/service.rs` to print a clean message on this error case if `anyhow`'s default `Error: cancelled`
output looks too raw for a CLI tool, though this is a minor polish call left to the implementer's
judgment, not a hard requirement).

- [ ] **Step 9: Commit**

```bash
git add torch/Cargo.toml torch/src/torchd_client.rs torch/src/main.rs torch/src/commands/snapshot.rs torch/src/commands/update.rs torch/src/commands/service.rs
git commit -m "feat: torch CLI becomes a torchd client (snapshot rollback, update, service restart)"
```

---

## Self-Review

**1. Spec coverage**: §1 scope (5 operation classes, CLI-side consumers) → Tasks 5,6,7,9. §2 wire
protocol/socket → Tasks 1,2. §3 danger-tier table → Task 3 (exact table encoded in tests). §4 policy
engine built now / canary deferred / audit log → Tasks 3,4 (canary explicitly NOT built, matching the
spec's own deferral). §5 CLI transition → Task 9. §6 verification plan → real checks embedded in
every task's own verification steps (round-trip snapshot test in Task 7, `pacman -Q` in Task 6,
`ActiveEnterTimestamp` diff in Task 7, socket permission test in Task 2, denylist test in Task 3/7,
`systemd-analyze security` in Task 8, audit log parseability in Task 4/7). §7 risks: PackageKit
avoidance is the Global Constraints' explicit design choice (shell out instead); `install-apps.sh`
bypass is noted as out of scope for this plan, not silently ignored — matches the spec's own framing
that it's a separate follow-up.

**2. Placeholder scan**: no TBD/TODO. Every step has complete, real code or a real command with a
stated expected result. The one deliberate simplification (`chrono_now()` shelling out to `date`
instead of a proper time crate) is marked with a `ponytail:` comment naming the ceiling, per the
project's own convention for such calls.

**3. Type consistency**: `Response`/`Request`/`Status` field names and the `Decision`/`Tier` enum
values are used identically across Tasks 1, 3, and 7 (checked against each task's own code as
written). `ops::snapshot::create`/`rollback`, `ops::package::install`/`remove`,
`ops::service::restart` signatures (`fn(&serde_json::Value) -> Result<String>`) match exactly between
their definition (Tasks 5/6/7) and their call sites in Task 7's `run_op()`. `torchd_client::call`'s
signature is used identically across all of Task 9's command modules.

## Next steps

Plan complete and saved to `docs/superpowers/plans/2026-09-10-torchd-phase2.md`. Two execution
options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — batch execution in this session with checkpoints

Which approach?
