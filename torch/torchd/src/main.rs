use anyhow::{Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};

mod audit;
mod ops;
mod policy;
mod protocol;

use audit::AuditEvent;
use policy::{decide, Decision, Tier};
use protocol::{Request, Response, Status};

const SOCKET_DIR: &str = "/run/torchd";
const SOCKET_PATH: &str = "/run/torchd/torchd.sock";
const AUDIT_PATH: &str = "/var/log/torchd/audit.jsonl";

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

// std's `UnixStream::peer_cred()` is gated behind the unstable
// `peer_credentials_unix_socket` feature on this toolchain (rustc 1.98.0
// stable) — not usable without nightly. SO_PEERCRED is read directly via
// getsockopt(2) instead, avoiding a new crate dependency for one syscall.
#[repr(C)]
struct RawUCred {
    pid: i32,
    uid: u32,
    gid: u32,
}

extern "C" {
    fn getsockopt(
        sockfd: i32,
        level: i32,
        optname: i32,
        optval: *mut std::ffi::c_void,
        optlen: *mut u32,
    ) -> i32;
}

const SOL_SOCKET: i32 = 1;
const SO_PEERCRED: i32 = 17;

fn peer_identity(stream: &UnixStream) -> Result<(u32, u32)> {
    use std::os::unix::io::AsRawFd;
    let mut cred = RawUCred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<RawUCred>() as u32;
    let ret = unsafe {
        getsockopt(
            stream.as_raw_fd(),
            SOL_SOCKET,
            SO_PEERCRED,
            &mut cred as *mut RawUCred as *mut std::ffi::c_void,
            &mut len,
        )
    };
    if ret != 0 {
        return Err(std::io::Error::last_os_error()).context("reading SO_PEERCRED");
    }
    if cred.uid == 0 {
        anyhow::bail!("connections from uid 0 (root) are rejected — connect as the torch user instead");
    }
    Ok((cred.uid, cred.gid))
}

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

    // torch CLI is the only Phase 2 client and always runs as Auto.
    let tier = Tier::Auto;
    // ponytail: any non-empty confirm_token counts as confirmation; the issued
    // token is not tracked. Fine while the only client is the local CLI prompting
    // a human; validate issued tokens before any non-interactive client exists.
    let has_confirmation = req.confirm_token.as_deref().is_some_and(|t| !t.is_empty());
    let decision = decide(&req.op, tier, has_confirmation);

    let response = match &decision {
        Decision::Denied(reason) => Response::denied(&req.request_id, reason.clone()),
        Decision::NeedsConfirmation => Response::needs_confirmation(
            &req.request_id,
            format!("{} requires confirmation — resend with confirm_token set", req.op),
            uuid::Uuid::new_v4().to_string(),
        ),
        Decision::AutoApprove => match run_op(&req.op, &req.args) {
            Ok(msg) => Response::ok(&req.request_id, msg, None),
            Err(e) => Response::error(&req.request_id, format!("{e:#}")),
        },
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
        timestamp: now_utc(),
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
    if let Err(e) = audit::append(AUDIT_PATH, &event) {
        eprintln!("audit log write failed: {e:#}");
    }

    writeln!(writer, "{}", serde_json::to_string(&response)?)?;
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

// ponytail: shells out to `date` once per request; swap for a time crate if
// request volume ever matters.
fn now_utc() -> String {
    std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}
