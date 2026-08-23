use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct LabMetadata {
    pub name: String,
    pub created: DateTime<Utc>,
    pub base: String,
}

impl LabMetadata {
    pub fn new(name: String, base: String) -> Self {
        Self {
            name,
            created: Utc::now(),
            base,
        }
    }
}
