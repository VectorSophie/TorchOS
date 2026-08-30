use gtk4::gdk::Display;
use gtk4::glib::Propagation;
use gtk4::prelude::*;
use gtk4::{Align, Application, ApplicationWindow, Box as GtkBox, CheckButton, CssProvider, Label, Orientation};

const APP_ID: &str = "org.torchos.Welcome";
const DISMISS_FLAG_REL: &str = ".config/torch/welcome-dismissed";
const STYLE: &str = include_str!("style.css");

#[derive(serde::Deserialize, Debug, PartialEq)]
struct Diagnose {
    kernel: String,
    hostname: String,
    root_fstype: String,
    gpu: String,
    failed_units: String,
    mem_available_kb: String,
}

fn dismiss_flag_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join(DISMISS_FLAG_REL)
}

fn run_diagnose() -> anyhow::Result<Diagnose> {
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
    let diag = run_diagnose().unwrap_or(Diagnose {
        kernel: "unknown".into(),
        hostname: "unknown".into(),
        root_fstype: "unknown".into(),
        gpu: "unknown".into(),
        failed_units: String::new(),
        mem_available_kb: "0".into(),
    });

    let container = GtkBox::new(Orientation::Vertical, 12);
    container.set_margin_top(24);
    container.set_margin_bottom(24);
    container.set_margin_start(24);
    container.set_margin_end(24);
    container.add_css_class("welcome-root");

    let title = Label::new(Some("Welcome to TorchOS"));
    title.add_css_class("welcome-title");
    container.append(&title);

    let rows = [
        ("Kernel", diag.kernel.as_str()),
        ("Hostname", diag.hostname.as_str()),
        ("Root filesystem", diag.root_fstype.as_str()),
        ("GPU", diag.gpu.as_str()),
        ("Available memory (kB)", diag.mem_available_kb.as_str()),
        (
            "Failed services",
            if diag.failed_units.is_empty() { "none" } else { diag.failed_units.as_str() },
        ),
    ];
    for (label, value) in rows {
        let row = Label::new(Some(&format!("{label}: {value}")));
        row.set_halign(Align::Start);
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
    fn parses_real_diagnose_json_shape() {
        // Exact shape torch/src/commands/diagnose.rs emits — a flat
        // string-keyed object, all values strings (even the numeric one).
        let sample = r#"{"kernel":"6.10.1-1-cachyos","hostname":"torchos-vm","root_fstype":"btrfs","gpu":"00:02.0 VGA compatible controller: Red Hat, Inc. Virtio GPU","failed_units":"","mem_available_kb":"1048576"}"#;
        let diag: Diagnose = serde_json::from_str(sample).unwrap();
        assert_eq!(diag.kernel, "6.10.1-1-cachyos");
        assert_eq!(diag.root_fstype, "btrfs");
        assert_eq!(diag.mem_available_kb, "1048576");
        assert_eq!(diag.failed_units, "");
    }
}
