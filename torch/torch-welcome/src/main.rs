use gtk4::gdk::Display;
use gtk4::glib::Propagation;
use gtk4::prelude::*;
use gtk4::{Align, Application, ApplicationWindow, Box as GtkBox, CheckButton, CssProvider, Label, Orientation};

const APP_ID: &str = "org.torchos.Welcome";
const DISMISS_FLAG_REL: &str = ".config/torch/welcome-dismissed";
const STYLE: &str = include_str!("style.css");

// Mirrors `torch diagnose` (schema 1). Every field is optional/defaulted so a newer
// or partial document still renders instead of collapsing to "unknown".
#[derive(serde::Deserialize, Debug, PartialEq, Default)]
struct Gpu {
    #[serde(default)]
    vendor: String,
    #[serde(default)]
    device: String,
}

#[derive(serde::Deserialize, Debug, PartialEq, Default)]
struct Diagnose {
    #[serde(default)]
    kernel: Option<String>,
    #[serde(default)]
    hostname: Option<String>,
    #[serde(default)]
    root_fstype: Option<String>,
    #[serde(default)]
    gpus: Vec<Gpu>,
    #[serde(default)]
    failed_units: Vec<String>,
    #[serde(default)]
    mem_available_kb: Option<u64>,
}

impl Diagnose {
    fn rows(&self) -> Vec<(&'static str, String)> {
        let or_unknown = |o: &Option<String>| o.clone().unwrap_or_else(|| "unknown".into());
        let gpu = if self.gpus.is_empty() {
            "none detected".to_string()
        } else {
            self.gpus.iter().map(|g| format!("{} {}", g.vendor, g.device)).collect::<Vec<_>>().join(", ")
        };
        vec![
            ("Kernel", or_unknown(&self.kernel)),
            ("Hostname", or_unknown(&self.hostname)),
            ("Root filesystem", or_unknown(&self.root_fstype)),
            ("GPU", gpu),
            (
                "Available memory",
                self.mem_available_kb.map_or("unknown".into(), |kb| format!("{} MiB", kb / 1024)),
            ),
            (
                "Failed services",
                if self.failed_units.is_empty() { "none".into() } else { self.failed_units.join(", ") },
            ),
        ]
    }
}

fn dismiss_flag_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join(DISMISS_FLAG_REL)
}

fn run_diagnose() -> anyhow::Result<Diagnose> {
    // `torch diagnose` exits 1 when any check is degraded; the JSON on stdout is still valid.
    let out = std::process::Command::new("torch").arg("diagnose").output()?;
    Ok(serde_json::from_slice(&out.stdout)?)
}

fn load_css() {
    let provider = CssProvider::new();
    provider.load_from_data(STYLE);
    gtk4::style_context_add_provider_for_display(
        &Display::default().expect("no display connection"),
        &provider,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

fn build_ui(app: &Application) {
    let diag = run_diagnose().unwrap_or_default();

    let container = GtkBox::new(Orientation::Vertical, 12);
    container.set_margin_top(24);
    container.set_margin_bottom(24);
    container.set_margin_start(24);
    container.set_margin_end(24);
    container.add_css_class("welcome-root");

    let title = Label::new(Some("Welcome to TorchOS"));
    title.add_css_class("welcome-title");
    container.append(&title);

    let rows = diag.rows();
    for (label, value) in rows {
        let row = Label::new(Some(&format!("{label}: {value}")));
        row.set_halign(Align::Start);
        row.set_xalign(0.0);
        row.set_wrap(true); // long failed-unit lists used to run off the window
        row.set_max_width_chars(60);
        row.add_css_class("welcome-row");
        container.append(&row);
    }

    let dismiss = CheckButton::with_label("Don't show this again");
    container.append(&dismiss);

    let window = ApplicationWindow::builder()
        .application(app)
        .title("TorchOS Welcome")
        .default_width(480)
        .default_height(360)
        .child(&container)
        .build();

    window.connect_close_request(move |_| {
        if dismiss.is_active() {
            let path = dismiss_flag_path();
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(path, "");
        }
        Propagation::Proceed
    });

    window.present();
}

fn main() -> anyhow::Result<()> {
    if dismiss_flag_path().exists() {
        return Ok(());
    }

    let app = Application::builder().application_id(APP_ID).build();
    app.connect_startup(|_| load_css());
    app.connect_activate(build_ui);
    app.run();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_schema_1_and_renders_rows() {
        let sample = r#"{"schema":1,"kernel":"7.2.6-arch2-1","hostname":"torchos-test","root_fstype":"btrfs",
            "gpus":[{"slot":"00:02.0","class":"VGA compatible controller","vendor":"Red Hat, Inc.","device":"Virtio 1.0 GPU"}],
            "failed_units":["a.service","b.mount"],"mem_available_kb":2097152,"checks":[]}"#;
        let d: Diagnose = serde_json::from_str(sample).unwrap();
        let rows = d.rows();
        assert_eq!(rows[0], ("Kernel", "7.2.6-arch2-1".to_string()));
        assert_eq!(rows[3].1, "Red Hat, Inc. Virtio 1.0 GPU");
        assert_eq!(rows[4].1, "2048 MiB");
        assert_eq!(rows[5].1, "a.service, b.mount");
    }

    #[test]
    fn empty_document_still_renders() {
        let d: Diagnose = serde_json::from_str("{}").unwrap();
        assert_eq!(d.rows()[0].1, "unknown");
        assert_eq!(d.rows()[5].1, "none");
    }
}
