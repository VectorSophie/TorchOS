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
        for op in ["bootloader.modify", "partition.modify", "torchd.disable"] {
            for tier in [Tier::Recommend, Tier::Auto, Tier::Trust] {
                assert!(matches!(decide(op, tier, true), Decision::Denied(_)));
            }
        }
    }

    #[test]
    fn recommend_tier_never_auto_approves() {
        for op in ["snapshot.create", "package.install", "service.restart", "package.remove", "snapshot.rollback"] {
            for has_confirmation in [false, true] {
                assert_eq!(decide(op, Tier::Recommend, has_confirmation), Decision::NeedsConfirmation);
            }
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
