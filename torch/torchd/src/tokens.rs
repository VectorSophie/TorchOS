use std::collections::HashMap;
use std::time::{Duration, Instant};

const TTL: Duration = Duration::from_secs(300);

/// Confirmation tokens torchd has issued. A token is valid once, for the same op, args and
/// peer uid it was issued for, within TTL. This is what stops a client from confirming an
/// action it was never shown (or confirming a different one with a stale token).
#[derive(Default)]
pub struct Tokens {
    issued: HashMap<String, (String, serde_json::Value, u32, Instant)>,
}

impl Tokens {
    pub fn issue(&mut self, op: &str, args: &serde_json::Value, uid: u32) -> String {
        self.issued.retain(|_, (.., t)| t.elapsed() < TTL);
        let token = uuid::Uuid::new_v4().to_string();
        self.issued.insert(token.clone(), (op.to_string(), args.clone(), uid, Instant::now()));
        token
    }

    /// Consumes the token: a second use of the same token is always rejected.
    pub fn redeem(&mut self, token: &str, op: &str, args: &serde_json::Value, uid: u32) -> bool {
        match self.issued.remove(token) {
            Some((o, a, u, t)) => o == op && &a == args && u == uid && t.elapsed() < TTL,
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn token_is_single_use_and_bound_to_op_args_uid() {
        let mut t = Tokens::default();
        let a = json!({"name": "sshd"});
        let tok = t.issue("service.restart", &a, 1000);
        assert!(!t.redeem("made-up", "service.restart", &a, 1000));
        assert!(t.redeem(&tok, "service.restart", &a, 1000));
        assert!(!t.redeem(&tok, "service.restart", &a, 1000), "reused");

        for (op, args, uid) in [
            ("package.remove", a.clone(), 1000),
            ("service.restart", json!({"name": "torchd"}), 1000),
            ("service.restart", a.clone(), 1001),
        ] {
            let tok = t.issue("service.restart", &a, 1000);
            assert!(!t.redeem(&tok, op, &args, uid), "{op} {args} {uid}");
        }
    }
}
