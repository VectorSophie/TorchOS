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
