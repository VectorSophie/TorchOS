use anyhow::{Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};

mod protocol;
mod policy;

use protocol::{Request, Response};

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
