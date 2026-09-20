use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

const SOCKET_PATH: &str = "/run/torchd/torchd.sock";

/// Send one op to torchd, prompting for confirmation if it asks. Returns the
/// daemon's human-readable message on success.
pub fn call(op: &str, args: serde_json::Value) -> Result<String> {
    let request_id = uuid::Uuid::new_v4().to_string();
    let mut resp = send(&request_id, op, &args, None)?;

    if resp["status"] == "needs_confirmation" {
        println!("{}", resp["message"].as_str().unwrap_or("this action needs confirmation"));
        print!("Proceed? [y/N] ");
        std::io::stdout().flush().ok();
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !answer.trim().eq_ignore_ascii_case("y") {
            bail!("cancelled");
        }
        let token = resp["confirm_token"].as_str().unwrap_or("yes").to_string();
        resp = send(&request_id, op, &args, Some(&token))?;
    }

    let msg = resp["message"].as_str().unwrap_or("").to_string();
    match resp["status"].as_str() {
        Some("ok") => Ok(msg),
        Some("denied") => bail!("denied: {msg}"),
        Some("error") => bail!("torchd error: {msg}"),
        other => bail!("unexpected torchd status {other:?}: {msg}"),
    }
}

fn send(request_id: &str, op: &str, args: &serde_json::Value, token: Option<&str>) -> Result<serde_json::Value> {
    let mut req = serde_json::json!({"request_id": request_id, "op": op, "args": args});
    if let Some(t) = token {
        req["confirm_token"] = t.into();
    }
    let mut stream = UnixStream::connect(SOCKET_PATH)
        .with_context(|| format!("connecting to {SOCKET_PATH} — is torchd running, and are you in the torch-agent group?"))?;
    writeln!(stream, "{req}")?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    serde_json::from_str(&line).context("parsing torchd response")
}
