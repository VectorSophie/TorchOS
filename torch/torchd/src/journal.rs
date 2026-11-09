//! Operation journal (docs/decisions/0003-recovery-integrity.md §4): one JSON object per line, each made durable
//! (fdatasync) before `append` returns. Lives on @log, so it survives a rollback of @.
//!
//! Damage handling. A crash or a short write (ENOSPC on the shared filesystem) can leave an unterminated last
//! line. That record was never confirmed to its writer, so nothing relied on it; the reader skips it, and the next
//! `append` terminates it and writes a `repair` record right after it, naming the torn line's length, so it stays
//! recognisable as that repaired torn tail and nothing else. Any other unparseable line is reported in `Journal::corrupt`: callers fail closed on it instead of
//! carrying on as if the record never existed. A journal that cannot be read is an error, never an empty list.
use anyhow::{Context, Result};
use std::fs::OpenOptions;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::FileExt;

pub const PATH: &str = "/var/log/torchd/journal.jsonl";

#[derive(Debug, Default)]
pub struct Journal {
    /// Every readable record, in order.
    pub records: Vec<serde_json::Value>,
    /// 1-based numbers of unreadable lines that are not a torn tail (current, or repaired: followed by a repair
    /// record whose `torn_bytes` equals the line's length).
    pub corrupt: Vec<usize>,
}

/// Append one record and fdatasync it. An error means the record may not be on disk: callers treat that as
/// "this step must not be claimed". A torn last line is terminated and marked first, in the same write.
pub fn append(path: &str, record: &serde_json::Value) -> Result<()> {
    #[cfg(feature = "fault-injection")]
    if crate::ops::snapshot::journal_fault(record) {
        anyhow::bail!("injected journal write failure");
    }
    let f = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening journal {path}"))?;
    let len = f.metadata().context("journal metadata")?.len();
    let mut buf = Vec::new();
    if len > 0 {
        let mut last = [0u8];
        f.read_exact_at(&mut last, len - 1).context("reading the journal's last byte")?;
        if last[0] != b'\n' {
            // torn_bytes ties the marker to the exact line it terminates (the reader checks the length)
            let tail = torn_len(&f, len).context("reading the journal's torn tail")?;
            buf.extend(format!("\n{}\n", serde_json::json!({"kind": "repair", "repair": "torn-tail", "torn_bytes": tail})).into_bytes());
        }
    }
    buf.extend(record.to_string().into_bytes());
    buf.push(b'\n');
    (&f).write_all(&buf).context("writing journal record")?;
    f.sync_data().context("fdatasync journal")?;
    Ok(())
}

/// Length of the unterminated last line of a `len`-byte journal (rare path: reads the whole file).
fn torn_len(f: &std::fs::File, len: u64) -> Result<u64> {
    let mut b = vec![0u8; len as usize];
    f.read_exact_at(&mut b, 0)?;
    Ok(b.iter().rposition(|c| *c == b'\n').map_or(len, |i| len - i as u64 - 1))
}

/// Read the journal. A missing file is an empty journal; any other read failure is an error.
pub fn read(path: &str) -> Result<Journal> {
    match std::fs::read(path) {
        Ok(b) => Ok(parse(&b)),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(Journal::default()),
        Err(e) => Err(e).with_context(|| format!("reading journal {path}")),
    }
}

fn parse(bytes: &[u8]) -> Journal {
    let obj = |l: &[u8]| serde_json::from_slice::<serde_json::Value>(l).ok().filter(|v| v.is_object());
    let mut lines: Vec<&[u8]> = bytes.split(|b| *b == b'\n').collect();
    // split leaves "" after a final newline; otherwise the last element is an unterminated (torn) tail
    let tail = lines.pop().filter(|t| !t.is_empty());
    let parsed: Vec<_> = lines.iter().map(|l| obj(l)).collect();
    let mut j = Journal::default();
    for (i, (line, rec)) in lines.iter().zip(&parsed).enumerate() {
        match rec {
            Some(v) => j.records.push(v.clone()),
            None if line.iter().all(u8::is_ascii_whitespace) => {}
            None if parsed.get(i + 1).and_then(Option::as_ref).is_some_and(|n| {
                n["kind"] == "repair" && n["torn_bytes"].as_u64() == Some(line.len() as u64)
            }) => {}
            None => j.corrupt.push(i + 1),
        }
    }
    // A complete record whose newline was lost is still a record; a partial one is the skipped torn tail.
    j.records.extend(tail.and_then(obj));
    j
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tmp() -> String {
        let dir = std::env::temp_dir().join(format!("torchd-journal-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("j.jsonl").to_str().unwrap().to_string()
    }
    fn raw(p: &str, b: &[u8]) {
        OpenOptions::new().create(true).append(true).open(p).unwrap().write_all(b).unwrap();
    }

    #[test]
    fn appends_and_skips_a_torn_tail() {
        let p = tmp();
        append(&p, &json!({"op_id": "a", "seq": 1})).unwrap();
        append(&p, &json!({"op_id": "a", "seq": 2})).unwrap();
        raw(&p, b"{\"op_id\":\"a\",\"se"); // crash in the middle of a write
        let j = read(&p).unwrap();
        assert_eq!(j.records.len(), 2);
        assert_eq!(j.records[1]["seq"], 2);
        assert!(j.corrupt.is_empty(), "a torn tail is not corruption");
        assert!(read("/nonexistent/torchd-journal").unwrap().records.is_empty(), "missing = empty");
    }

    #[test]
    fn a_record_appended_after_a_torn_tail_is_not_lost() {
        // Regression: the new intent was glued onto the torn line and silently dropped with it.
        let p = tmp();
        append(&p, &json!({"op_id": "a", "kind": "outcome", "result": "prepared"})).unwrap();
        raw(&p, b"{\"op_id\":\"b\",\"kind\":\"inte");
        append(&p, &json!({"op_id": "c", "kind": "intent"})).unwrap();
        append(&p, &json!({"op_id": "c", "kind": "step"})).unwrap();
        let j = read(&p).unwrap();
        let ids: Vec<_> = j.records.iter().map(|r| r["op_id"].as_str().unwrap_or("-").to_string()).collect();
        assert_eq!(ids, ["a", "-", "c", "c"], "the repair record, then the new intent intact");
        assert_eq!(j.records[1]["kind"], "repair");
        assert!(j.corrupt.is_empty(), "a repaired torn tail is not corruption");
        // restart after the interrupted write: reading again gives the same answer
        assert_eq!(read(&p).unwrap().records, j.records);
    }

    #[test]
    fn a_corrupt_middle_line_is_reported_not_dropped() {
        let p = tmp();
        raw(&p, b"{\"op_id\":\"a\",\"kind\":\"intent\"}\n{garbage\n{\"op_id\":\"a\",\"kind\":\"step\"}\n");
        let j = read(&p).unwrap();
        assert_eq!(j.records.len(), 2);
        assert_eq!(j.corrupt, vec![2]);
    }

    #[test]
    fn a_repair_excuses_only_the_torn_line_it_terminated() {
        // A corrupt confirmed record elsewhere stays corrupt even when a torn tail is repaired later.
        let p = tmp();
        raw(&p, b"{\"op_id\":\"a\",\"kind\":\"intent\"}\n{garb\n{\"op_id\":\"a\",\"kind\":\"step\"}\n{\"op_id\":\"b\",\"ki");
        append(&p, &json!({"op_id": "c", "kind": "intent"})).unwrap();
        assert_eq!(read(&p).unwrap().corrupt, vec![2]);
        // Damage that merges a confirmed record into the torn line (its newline lost) is not "the torn line":
        // the repair names how many bytes it terminated, so the merged line does not match.
        let p = tmp();
        append(&p, &json!({"op_id": "a", "kind": "intent"})).unwrap();
        append(&p, &json!({"op_id": "a", "kind": "step", "step": "created"})).unwrap();
        raw(&p, b"{\"op_id\":\"b\",\"ki");
        append(&p, &json!({"op_id": "c", "kind": "intent"})).unwrap();
        let mut b = std::fs::read(&p).unwrap();
        let first_nl = b.iter().position(|c| *c == b'\n').unwrap();
        let second_nl = first_nl + 1 + b[first_nl + 1..].iter().position(|c| *c == b'\n').unwrap();
        b[second_nl] = b'#'; // the `created` record's newline is damaged
        std::fs::write(&p, &b).unwrap();
        let j = read(&p).unwrap();
        assert_eq!(j.corrupt, vec![2], "the lost `created` record must be reported, not excused by the repair");
    }

    #[test]
    fn a_repair_write_torn_after_its_newline_fails_closed() {
        // Two short writes in a row (ENOSPC): the first leaves a torn line, the second gets only its leading "\n"
        // out. Nothing marks the line as torn any more, so it is reported (operator review), never dropped silently.
        let p = tmp();
        append(&p, &json!({"op_id": "a", "kind": "intent"})).unwrap();
        raw(&p, b"{\"op_id\":\"b\",\"ki\n");
        append(&p, &json!({"op_id": "c", "kind": "intent"})).unwrap();
        let j = read(&p).unwrap();
        assert_eq!(j.corrupt, vec![2]);
        assert_eq!(j.records.len(), 2);
    }

    #[test]
    fn invalid_utf8_does_not_empty_the_journal() {
        // Regression: read_to_string failed on one bad byte and the whole journal read as empty.
        let p = tmp();
        raw(&p, b"{\"op_id\":\"a\",\"kind\":\"intent\"}\n{\"detail\":\"\xc3\n{\"op_id\":\"a\",\"kind\":\"step\"}\n");
        let j = read(&p).unwrap();
        assert_eq!(j.records.len(), 2);
        assert_eq!(j.corrupt, vec![2]);
    }

    #[test]
    fn unreadable_journal_is_an_error_not_empty() {
        let p = tmp();
        std::fs::create_dir(&p).unwrap(); // EISDIR stands in for EIO / EACCES
        assert!(read(&p).is_err());
        assert!(append(&p, &json!({})).is_err());
    }

    #[test]
    fn a_complete_record_missing_its_newline_is_kept() {
        let p = tmp();
        raw(&p, b"{\"op_id\":\"a\",\"kind\":\"intent\"}");
        assert_eq!(read(&p).unwrap().records.len(), 1);
        append(&p, &json!({"op_id": "a", "kind": "step"})).unwrap();
        let j = read(&p).unwrap();
        assert_eq!(j.records.len(), 3, "intent, repair, step");
        assert!(j.corrupt.is_empty());
    }
}
