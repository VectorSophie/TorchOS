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
