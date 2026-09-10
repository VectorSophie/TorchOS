use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    pub request_id: String,
    pub op: String,
    #[serde(default = "default_args")]
    pub args: serde_json::Value,
    #[serde(default)]
    pub confirm_token: Option<String>,
}

fn default_args() -> serde_json::Value {
    serde_json::Value::Null
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Ok,
    Denied,
    Error,
    NeedsConfirmation,
}

#[derive(Debug, Clone, Serialize)]
pub struct Response {
    pub request_id: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confirm_token: Option<String>,
}

impl Response {
    pub fn error(request_id: &str, message: impl Into<String>) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::Error,
            result: None,
            message: message.into(),
            confirm_token: None,
        }
    }

    pub fn ok(request_id: &str, message: impl Into<String>, result: Option<serde_json::Value>) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::Ok,
            result,
            message: message.into(),
            confirm_token: None,
        }
    }

    pub fn denied(request_id: &str, message: impl Into<String>) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::Denied,
            result: None,
            message: message.into(),
            confirm_token: None,
        }
    }

    pub fn needs_confirmation(request_id: &str, message: impl Into<String>, confirm_token: String) -> Self {
        Response {
            request_id: request_id.to_string(),
            status: Status::NeedsConfirmation,
            result: None,
            message: message.into(),
            confirm_token: Some(confirm_token),
        }
    }
}
