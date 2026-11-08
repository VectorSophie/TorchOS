//! Operation journal (docs/decisions/0003-recovery-integrity.md §4): one JSON object per line, each made durable
//! (fdatasync) before `append` returns. Lives on @log, so it survives a rollback of @.
use anyhow::{Context, Result};
use std::fs::OpenOptions;
use std::io::Write;

pub const PATH: &str = "/var/log/torchd/journal.jsonl";

/// Append one record and fdatasync it. An error means the record may not be on disk: callers treat that as
/// "this step must not be claimed".
pub fn append(path: &str, record: &serde_json::Value) -> Result<()> {
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening journal {path}"))?;
    writeln!(f, "{record}").context("writing journal record")?;
    f.sync_data().context("fdatasync journal")?;
    Ok(())
}

/// Every parseable record, in order. A torn last line (crash mid-write) or any other junk line is skipped.
pub fn read(path: &str) -> Vec<serde_json::Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(|v| v.is_object())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn appends_and_skips_torn_lines() {
        let dir = std::env::temp_dir().join(format!("torchd-journal-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("j.jsonl");
        let p = p.to_str().unwrap();
        append(p, &json!({"op_id": "a", "seq": 1})).unwrap();
        append(p, &json!({"op_id": "a", "seq": 2})).unwrap();
        // A crash in the middle of a write leaves a partial line.
        std::fs::OpenOptions::new().append(true).open(p).unwrap().write_all(b"{\"op_id\":\"a\",\"se").unwrap();
        let r = read(p);
        assert_eq!(r.len(), 2);
        assert_eq!(r[1]["seq"], 2);
        assert!(read("/nonexistent/torchd-journal").is_empty());
    }
}
