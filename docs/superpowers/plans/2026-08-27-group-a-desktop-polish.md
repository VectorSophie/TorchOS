# Group A: Desktop Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the Phase 1 Hyprland baseline to a themed, app-complete desktop: install the Group A app
bundle, ship a real `torch-welcome` status app, wire up chezmoi-managed dotfiles (Hyprland config,
keybinds, palette-themed waybar/wofi/wlogout), and verify all of it with real checks (package queries,
`grim` screenshots, pixel sampling, QEMU-monitor key exercise) — not just "it built."

**Architecture:** A one-shot idempotent `scripts/install-apps.sh` installs everything via pacman/yay. A
new `torch-welcome` crate joins `torch/` as a Cargo workspace member — a read-only GTK4 renderer over
`torch diagnose`'s existing JSON output, no independent diagnostic logic. A new `dotfiles/` directory
becomes chezmoi's source dir, holding every per-user config file (Hyprland core config + keybinds,
hypridle, waybar, wofi, wlogout) themed with the locked palette. Everything lands and gets verified on
the Phase 1 QEMU VM — never the dev host.

**Tech Stack:** Bash (install script), Rust + `gtk4-rs` 0.9 (torch-welcome), chezmoi (dotfiles), Hyprland
config DSL, GTK CSS, Python + Pillow (palette pixel-sampling check, matching the existing
`scripts/branding/generate_wallpaper.py` pattern).

## Global Constraints

- **Never touch the host OS.** All work happens on the Phase 1 QEMU VM (`ssh -p 2222 torch@localhost`,
  password `torchos2026` — throwaway, VM-only, fine to use non-interactively). This dev host is
  off-limits for anything beyond editing files in this repo.
- **Snapshot before any mutating privileged action** (`CLAUDE.md` trust-boundary rule): every task that
  installs packages or changes system-level config on the VM snapshots first via
  `snapper create -d "<what and why>" -u important=yes`.
- **`torchd` doesn't exist yet** (Phase 2) — nothing in this plan routes through it; direct
  pacman/systemctl/chezmoi calls are correct for Phase 1/Group A, matching how `torch/` itself already
  works (see the PHASE 1 NOTE at the top of `torch/src/main.rs`).
- **Locked palette, exact hexes, do not substitute**: `#ff4500` (primary accent), `#ff6a00` (secondary
  accent), `#2b0a00` (dark/text), light backgrounds (`#ffffff`). Every themed surface in this plan uses
  these values verbatim.
- **`chezmoi diff` before every `chezmoi apply`, no exceptions** (locked architecture spec §5) — every
  dotfiles task's verification includes capturing and reading the diff before applying.
- **A "looks safe" change is not pre-approved** — verification in each task below means running the real
  command and reading real output, not declaring success because a step didn't error.
- Package names throughout are the verified real Arch/AUR names from `docs/superpowers/specs/2026-08-26-desktop-polish-design.md` §2, plus two gaps this plan closes that the design's package table
  didn't cover: `wlogout` (needed by §6's power-menu keybind, absent from the table) and `chezmoi` itself
  (needed by §5, also absent from the table).

---

## File Structure

```
scripts/install-apps.sh                     # new — Group A app bundle installer
scripts/verify_palette.py                   # new — pixel-sampling palette check
torch/Cargo.toml                             # modified — becomes a workspace root
torch/torch-welcome/Cargo.toml               # new
torch/torch-welcome/src/main.rs              # new
torch/torch-welcome/src/style.css            # new — embedded via include_str!
dotfiles/dot_config/hypr/hyprland.conf       # new — chezmoi-managed
dotfiles/dot_config/hypr/hypridle.conf       # new — chezmoi-managed
dotfiles/dot_config/hypr/bindings.conf       # new — chezmoi-managed
dotfiles/dot_config/autostart/torch-welcome.desktop  # new — chezmoi-managed (XDG-compliance copy; see Task 4 note)
dotfiles/dot_config/waybar/config            # new — chezmoi-managed
dotfiles/dot_config/waybar/style.css         # new — chezmoi-managed
dotfiles/dot_config/wofi/config              # new — chezmoi-managed
dotfiles/dot_config/wofi/style.css           # new — chezmoi-managed
dotfiles/dot_config/wlogout/layout           # new — chezmoi-managed
dotfiles/dot_config/wlogout/style.css        # new — chezmoi-managed
```

Each `dotfiles/dot_config/...` path is chezmoi source-dir naming: the `dot_` prefix maps to a literal
leading dot on the deployed path (`dot_config` → `.config`). No chezmoi templating (`.tmpl`) is used
anywhere in Group A — one target machine, hardcoded palette, no per-host variation to template around
(YAGNI; add `.tmpl` later only if a second target machine actually needs different values).

---

### Task 1: `install-apps.sh` — app bundle installer

**Files:**
- Create: `scripts/install-apps.sh`

**Interfaces:**
- Produces: every package in the combined candidate list below, installed and queryable via
  `pacman -Q <pkg>` on the VM. Later tasks (3, 4, 6) depend on `gtk4`, `pkgconf`, `chezmoi`, `wlogout`,
  `mako`, `swayosd`, `cliphist` being present.

- [ ] **Step 1: Write `scripts/install-apps.sh`**

```bash
#!/usr/bin/env bash
# TorchOS Group A app bundle installer.
#
# Idempotent: safe to re-run (pacman -S --needed / yay -S --needed are no-ops
# for already-installed packages). Self-classifies each candidate as
# official-repo vs. AUR by querying pacman directly instead of a
# hand-maintained split — repos change over time and this stays correct
# without editing this script.
#
# Usage: sudo ./install-apps.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo ./install-apps.sh" >&2
  exit 1
fi

# Trust-boundary rule (CLAUDE.md): snapshot before any mutating privileged action.
snapper create -d "before Group A app bundle install" -u important=yes

# Refresh package databases so pacman -Si below reflects reality.
pacman -Sy

PACMAN_CANDIDATES=(
  # Shell/CLI quality-of-life
  bash-completion bat btop dust eza fastfetch fd fzf jq less man-db plocate
  ripgrep starship tldr tmux tree-sitter-cli usage zoxide gum expac inxi
  # Notifications / OSD / input
  mako swayosd fcitx5 fcitx5-gtk fcitx5-qt brightnessctl playerctl pamixer wiremix
  # Screenshot / capture / clipboard
  grim slurp satty hyprpicker wl-clipboard cliphist imv ffmpegthumbnailer
  # File management
  nautilus nautilus-python sushi gnome-disk-utility gvfs-mtp gvfs-nfs gvfs-smb
  dosfstools exfatprogs
  # Terminal apps
  lazydocker lazygit neovim mise
  # Productivity / office
  libreoffice-fresh libqalculate gnome-calculator obsidian evince
  # Creative / media
  imagemagick pinta mpv obs-studio gpu-screen-recorder
  # Printing
  cups cups-browsed cups-filters cups-pdf system-config-printer
  # Fonts / theming
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
  woff2-font-awesome gnome-themes-extra yaru-icon-theme kvantum-qt5 qt5-wayland
  # System / power (wlogout added here — §6 keybind needs it, missing from
  # the design doc's own package table)
  power-profiles-daemon zram-generator avahi nss-mdns bluetui bolt iwd
  wireless-regdb plymouth wlogout
  # Dev tooling
  github-cli rust docker docker-compose docker-buildx
  # Windows compatibility
  bottles
  # Dotfiles tooling (chezmoi itself — needed by Task 4, also missing from
  # the design doc's package table)
  chezmoi
  # torch-welcome build dependency (Task 3 — gtk4-rs needs the gtk4
  # pkg-config file; base-devel/git are for the yay bootstrap below)
  gtk4 pkgconf base-devel git
)

OFFICIAL=()
AUR=()
for pkg in "${PACMAN_CANDIDATES[@]}"; do
  if pacman -Si "$pkg" &>/dev/null; then
    OFFICIAL+=("$pkg")
  else
    AUR+=("$pkg")
  fi
done

echo "installing ${#OFFICIAL[@]} official-repo packages..."
pacman -S --needed --noconfirm "${OFFICIAL[@]}"

BUILD_USER="${SUDO_USER:-torch}"

# yay bootstrap: yay isn't in the official repos, and makepkg refuses to run
# as root, so this always runs as the invoking (non-root) user.
if ! command -v yay &>/dev/null; then
  echo "bootstrapping yay..."
  runuser -u "$BUILD_USER" -- bash -c '
    set -euo pipefail
    tmp=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
    cd "$tmp/yay-bin"
    makepkg -si --noconfirm
    rm -rf "$tmp"
  '
fi

if [[ ${#AUR[@]} -gt 0 ]]; then
  echo "installing ${#AUR[@]} AUR packages: ${AUR[*]}"
  runuser -u "$BUILD_USER" -- yay -S --needed --noconfirm "${AUR[@]}"
fi

echo "done."
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/install-apps.sh
```

- [ ] **Step 3: Copy to the VM and run it**

```bash
scp -P 2222 scripts/install-apps.sh torch@localhost:~/install-apps.sh
ssh -p 2222 torch@localhost 'sudo bash ~/install-apps.sh'
```
Expected: script runs to completion printing `done.`, no `error: target not found` lines (that would
mean the pacman/AUR self-classification put a package in the wrong bucket — fix by moving that name to
its correct list, or check for a typo).

- [ ] **Step 4: Spot-check at least one package per group actually installed**

```bash
ssh -p 2222 torch@localhost 'pacman -Q mako swayosd cliphist wlogout chezmoi gtk4 bottles neovim obsidian docker'
```
Expected: every name prints a version, no "was not found" errors.

- [ ] **Step 5: Confirm idempotency — run it again**

```bash
ssh -p 2222 torch@localhost 'sudo bash ~/install-apps.sh'
```
Expected: completes cleanly, pacman/yay report nothing new to install, no errors.

- [ ] **Step 6: Reboot the VM and confirm the desktop still renders**

```bash
ssh -p 2222 torch@localhost 'sudo reboot'
# wait ~20s for boot, then from a Hyprland session on the VM:
ssh -p 2222 torch@localhost 'export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1; grim /tmp/after-install.png'
scp -P 2222 torch@localhost:/tmp/after-install.png /tmp/torchos-after-install.png
```
Expected: `grim` exits 0 and produces a real PNG — read it with the Read tool to confirm the desktop
rendered (wallpaper + waybar visible), not a black screen.

- [ ] **Step 7: Commit**

```bash
git add scripts/install-apps.sh
git commit -m "feat: Group A app bundle installer"
```

---

### Task 2: Cargo workspace scaffold for `torch-welcome`

**Files:**
- Modify: `torch/Cargo.toml`
- Create: `torch/torch-welcome/Cargo.toml`
- Create: `torch/torch-welcome/src/main.rs` (stub — real app is Task 3)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a `torch-welcome` binary target inside the `torch/` workspace. Task 3 replaces the stub
  `main()` body; the crate name and binary name (`torch-welcome`) stay fixed for Task 4's `exec-once`
  line to reference.

- [ ] **Step 1: Turn `torch/Cargo.toml` into a workspace root**

The existing package manifest becomes the workspace root package *and* declares a second member — no
files move, `torch`'s existing source tree and behavior are untouched.

```toml
[workspace]
members = [".", "torch-welcome"]

[package]
name = "torch"
version = "0.1.0"
edition = "2021"

[dependencies]
clap = { version = "4", features = ["derive"] }
anyhow = "1"
```

- [ ] **Step 2: Create the `torch-welcome` crate manifest**

`torch/torch-welcome/Cargo.toml`:
```toml
[package]
name = "torch-welcome"
version = "0.1.0"
edition = "2021"

[dependencies]
gtk4 = "0.9"
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

- [ ] **Step 3: Create a stub binary**

`torch/torch-welcome/src/main.rs`:
```rust
fn main() {
    println!("torch-welcome stub — real UI lands in Task 3");
}
```

- [ ] **Step 4: Build the whole workspace on the VM** (gtk4-rs needs the `gtk4`/`pkgconf` packages
  Task 1 installed — this won't build on the dev host, which has no GTK4 dev files)

```bash
scp -P 2222 -r torch torch@localhost:~/torch
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build'
```
Expected: both `torch` and `torch-welcome` build successfully; `target/debug/torch` and
`target/debug/torch-welcome` both exist.

- [ ] **Step 5: Confirm the existing `torch` CLI still behaves identically**

```bash
ssh -p 2222 torch@localhost 'cd ~/torch && ./target/debug/torch diagnose'
```
Expected: same JSON shape as before this change (kernel/hostname/root_fstype/gpu/failed_units/
mem_available_kb) — the workspace conversion must not touch `torch`'s own behavior.

- [ ] **Step 6: Commit**

```bash
git add torch/Cargo.toml torch/torch-welcome
git commit -m "feat: scaffold torch-welcome as a workspace member"
```

---

### Task 3: `torch-welcome` — real GTK4 status app

**Files:**
- Modify: `torch/torch-welcome/src/main.rs`
- Create: `torch/torch-welcome/src/style.css`

**Interfaces:**
- Consumes: `torch diagnose`'s JSON output — exact keys `kernel`, `hostname`, `root_fstype`, `gpu`,
  `failed_units`, `mem_available_kb`, all strings (per `torch/src/commands/diagnose.rs`).
- Produces: a `torch-welcome` binary that (a) exits immediately with no window if
  `~/.config/torch/welcome-dismissed` exists, (b) otherwise renders a GTK4 window with those six fields
  plus a "Don't show this again" checkbox that writes that file on close if checked. Task 4's
  `exec-once = torch-welcome` line depends on this binary being on `$PATH`.

- [ ] **Step 1: Write the embedded stylesheet**

`torch/torch-welcome/src/style.css`:
```css
window.welcome-root {
    background-color: #ffffff;
}

.welcome-title {
    font-size: 20px;
    font-weight: bold;
    color: #ff4500;
}

.welcome-row {
    color: #2b0a00;
}

check {
    color: #ff6a00;
}
```

- [ ] **Step 2: Write the real app**

`torch/torch-welcome/src/main.rs`:
```rust
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
```

Note: if the resolved `gtk4` crate version's `connect_close_request` expects a different return type
than `gtk4::glib::Propagation` (API surface has shifted across gtk4-rs releases before), fix the return
type to match — `cargo build`'s compiler error will name the expected type directly.

- [ ] **Step 3: Run the unit test on the VM**

```bash
scp -P 2222 -r torch/torch-welcome torch@localhost:~/torch/torch-welcome
ssh -p 2222 torch@localhost 'cd ~/torch && cargo test -p torch-welcome'
```
Expected: `parses_real_diagnose_json_shape` passes.

- [ ] **Step 4: Build release and put it on `$PATH`**

```bash
ssh -p 2222 torch@localhost 'cd ~/torch && cargo build --release -p torch-welcome && sudo ln -sf ~/torch/target/release/torch-welcome /usr/local/bin/torch-welcome'
```
Expected: `torch-welcome` binary exists at `/usr/local/bin/torch-welcome`.

- [ ] **Step 5: Run it standalone and cross-check against a live `torch diagnose`**

```bash
ssh -p 2222 torch@localhost '
  export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1
  hyprctl dispatch exec torch-welcome
  sleep 1
  grim /tmp/torch-welcome.png
  ~/torch/target/debug/torch diagnose > /tmp/diagnose-at-same-moment.json
'
scp -P 2222 torch@localhost:/tmp/torch-welcome.png /tmp/torch-welcome.png
scp -P 2222 torch@localhost:/tmp/diagnose-at-same-moment.json /tmp/diagnose-at-same-moment.json
```
Expected: read `/tmp/torch-welcome.png` with the Read tool — a window titled "TorchOS Welcome" showing
six fields — and compare each displayed value against `/tmp/diagnose-at-same-moment.json`'s actual
content (catches stale/mocked data, not just "a window appeared").

- [ ] **Step 6: Verify the dismiss flag actually suppresses the window**

```bash
ssh -p 2222 torch@localhost 'touch ~/.config/torch/welcome-dismissed && hyprctl dispatch exec torch-welcome'
ssh -p 2222 torch@localhost 'pgrep -f torch-welcome'
```
Expected: `pgrep` finds no running process shortly after launch (it exited immediately per the
dismiss-flag check). Then:
```bash
ssh -p 2222 torch@localhost 'rm ~/.config/torch/welcome-dismissed'
```
to reset for later tasks.

- [ ] **Step 7: Commit**

```bash
git add torch/torch-welcome/src
git commit -m "feat: torch-welcome status dashboard"
```

---

### Task 4: chezmoi dotfiles scaffold — Hyprland core config

**Files:**
- Create: `dotfiles/dot_config/hypr/hyprland.conf`
- Create: `dotfiles/dot_config/hypr/hypridle.conf`
- Create: `dotfiles/dot_config/autostart/torch-welcome.desktop`

**Interfaces:**
- Consumes: the `torch-welcome` binary on `$PATH` (Task 3, Step 4).
- Produces: `~/.config/hypr/hyprland.conf` sourcing `~/.config/hypr/bindings.conf` (created in Task 5 —
  the `source` line is written now, the file itself doesn't need to exist yet for `chezmoi apply` to
  succeed, only for a later `hyprctl reload`).

**Note on the `.desktop` autostart file**: Hyprland does not itself process `~/.config/autostart/*.desktop`
files the way a full desktop environment (GNOME/KDE) does — there's no session manager scanning that
directory. The design doc's "launches via a plain `.desktop` autostart entry" language matches
cachyos-hello's actual target environment, but on bare Hyprland the file alone would silently never run.
This plan ships the `.desktop` file anyway (XDG-standard compliance, useful if TorchOS ever runs under a
session manager that does honor it) but wires the *real* launch through an `exec-once` line in
`hyprland.conf` below, which is how Hyprland configs actually autostart programs.

- [ ] **Step 1: Create the chezmoi source directory and Hyprland core config**

`dotfiles/dot_config/hypr/hyprland.conf`:
```
monitor = , preferred, auto, 1

env = XCURSOR_SIZE,24

input {
    kb_layout = us
    follow_mouse = 1
    touchpad {
        natural_scroll = false
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
    col.active_border = rgb(ff4500)
    col.inactive_border = rgb(2b0a00)
    layout = dwindle
}

decoration {
    rounding = 6
}

animations {
    enabled = true
}

dwindle {
    pseudotile = true
    preserve_split = true
}

$mainMod = SUPER

bind = $mainMod, Q, exec, kitty
bind = $mainMod, C, killactive
bind = $mainMod, M, exit
bind = $mainMod, E, exec, nautilus
bind = $mainMod, F, togglefloating
bind = $mainMod, D, exec, wofi --show drun

bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9

bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9

source = ~/.config/hypr/bindings.conf

exec-once = mkdir -p ~/Pictures/Screenshots
exec-once = hyprpaper
exec-once = waybar
exec-once = hypridle
exec-once = mako
exec-once = swayosd-server
exec-once = torch-welcome
```

- [ ] **Step 2: Create the hypridle config**

`dotfiles/dot_config/hypr/hypridle.conf`:
```
general {
    lock_cmd = hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 300
    on-timeout = hyprlock
}

listener {
    timeout = 600
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
```

- [ ] **Step 3: Create the XDG autostart file (documentation/compliance copy, see note above)**

`dotfiles/dot_config/autostart/torch-welcome.desktop`:
```
[Desktop Entry]
Type=Application
Name=TorchOS Welcome
Exec=torch-welcome
X-GNOME-Autostart-enabled=true
NoDisplay=false
```

- [ ] **Step 4: Deploy the dotfiles source dir to the VM and preview with `chezmoi diff`**

```bash
scp -P 2222 -r dotfiles torch@localhost:~/torchos-dotfiles
ssh -p 2222 torch@localhost 'chezmoi init --source ~/torchos-dotfiles && chezmoi diff'
```
Expected: diff output shows the new files being created (`hyprland.conf`, `hypridle.conf`,
`torch-welcome.desktop`) — read it before proceeding, per the mandatory-preview constraint.

- [ ] **Step 5: Apply**

```bash
ssh -p 2222 torch@localhost 'chezmoi apply -v'
```
Expected: exits 0, files land at `~/.config/hypr/hyprland.conf`, `~/.config/hypr/hypridle.conf`,
`~/.config/autostart/torch-welcome.desktop`.

- [ ] **Step 6: Verify the new `exec-once` programs actually run** (per the Phase 1 Gotcha:
  `exec-once` only fires at Hyprland's initial launch, not on `hyprctl reload` — dispatch them manually
  rather than trusting a reload)

```bash
ssh -p 2222 torch@localhost '
  export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1
  hyprctl dispatch exec mako
  hyprctl dispatch exec swayosd-server
  sleep 1
  pgrep -x mako
  pgrep -x swayosd-server
'
```
Expected: both `pgrep` calls print a PID.

- [ ] **Step 7: Commit**

```bash
git add dotfiles/dot_config/hypr dotfiles/dot_config/autostart
git commit -m "feat: chezmoi-managed Hyprland core config"
```

---

### Task 5: QoL keybinds (`bindings.conf`)

**Files:**
- Create: `dotfiles/dot_config/hypr/bindings.conf`

**Interfaces:**
- Consumes: `source = ~/.config/hypr/bindings.conf` line already written into `hyprland.conf` (Task 4).
- Produces: the five keybind behaviors verified in Step 3 below.

- [ ] **Step 1: Write the keybinds**

Translated from real Omarchy v3.8.4 source (`bin/omarchy-swayosd-client`, `bin/omarchy-capture-screenshot`,
verified directly), stripped of Omarchy's own wrapper-script layer per the design's §1 scope boundary
(wofi-native, no `omarchy-menu`/walker):

`dotfiles/dot_config/hypr/bindings.conf`:
```
# Screenshot / capture / clipboard
bind = , Print, exec, grim ~/Pictures/Screenshots/$(date +%Y%m%d-%H%M%S).png
bind = SUPER SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = SUPER, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy

# Power menu
bind = SUPER, ESCAPE, exec, wlogout

# Media / OSD — bindl (not plain bind) so these still work while the
# session is locked, matching real Omarchy's bindeld/bindld usage for the
# same keys
bindl = , XF86AudioRaiseVolume, exec, swayosd-client --output-volume raise
bindl = , XF86AudioLowerVolume, exec, swayosd-client --output-volume lower
bindl = , XF86AudioMute, exec, swayosd-client --output-volume mute-toggle
bindl = , XF86MonBrightnessUp, exec, swayosd-client --brightness raise
bindl = , XF86MonBrightnessDown, exec, swayosd-client --brightness lower
```

- [ ] **Step 2: Deploy via chezmoi**

```bash
scp -P 2222 dotfiles/dot_config/hypr/bindings.conf torch@localhost:~/torchos-dotfiles/dot_config/hypr/bindings.conf
ssh -p 2222 torch@localhost 'chezmoi diff'
```
Read the diff, then:
```bash
ssh -p 2222 torch@localhost 'chezmoi apply -v && hyprctl reload'
```
(`bind`/`bindl`/`source` lines, unlike `exec-once`, do take effect on `hyprctl reload`.)

- [ ] **Step 3: Exercise each bind via the QEMU monitor and diff before/after screenshots**

For each bind, take a `grim` screenshot, send the key combo through the QEMU monitor socket
(`image/vm/monitor.sock`), wait briefly, screenshot again, and confirm a visible effect:

```bash
# Example for the region-screenshot bind (repeat the pattern per bind):
ssh -p 2222 torch@localhost 'export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1; grim /tmp/before.png'
echo 'sendkey super-shift-s' | socat - unix-connect:image/vm/monitor.sock
sleep 1
ssh -p 2222 torch@localhost 'export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1; grim /tmp/after.png'
```
Per bind, the concrete pass condition:
- `Print`: a new file appears under `~/Pictures/Screenshots/` (`ssh ... 'ls ~/Pictures/Screenshots/'`).
- `SUPER SHIFT, S`: `wl-paste` afterward returns image data (`ssh ... 'wl-paste | file -'` reports an
  image type).
- `SUPER, V`: the wofi dmenu appears in the after-screenshot (visually, via Read tool).
- `SUPER, ESCAPE`: the wlogout menu appears in the after-screenshot.
- Volume/brightness keys: swayosd's OSD bar appears in the after-screenshot.

Refer to `CLAUDE.md`'s `qemu-vm` Gotcha for the full `sendkey` character-name mapping if a bind uses a
key not covered by the plain examples above.

- [ ] **Step 4: Commit**

```bash
git add dotfiles/dot_config/hypr/bindings.conf
git commit -m "feat: Group A QoL keybinds"
```

---

### Task 6: Palette theming — waybar / wofi / wlogout

**Files:**
- Create: `dotfiles/dot_config/waybar/config`
- Create: `dotfiles/dot_config/waybar/style.css`
- Create: `dotfiles/dot_config/wofi/config`
- Create: `dotfiles/dot_config/wofi/style.css`
- Create: `dotfiles/dot_config/wlogout/layout`
- Create: `dotfiles/dot_config/wlogout/style.css`
- Create: `scripts/verify_palette.py`

**Interfaces:**
- Consumes: locked palette hexes from Global Constraints.
- Produces: `scripts/verify_palette.py <screenshot.png> x,y,#hex ...` — a reusable CLI tool (exit 0 if
  every sampled pixel is within tolerance of its expected color, exit 1 otherwise), following the same
  delta-tolerance pattern as `scripts/branding/generate_wallpaper.py`'s `check()`.

- [ ] **Step 1: waybar config + CSS**

`dotfiles/dot_config/waybar/config`:
```json
{
    "layer": "top",
    "position": "top",
    "height": 32,
    "modules-left": ["hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["network", "battery", "pulseaudio", "tray"],
    "clock": { "format": "{:%H:%M}" },
    "battery": { "format": "{capacity}% {icon}", "format-icons": ["", "", "", "", ""] },
    "network": { "format-wifi": "{essid} ({signalStrength}%)", "format-ethernet": "{ipaddr}/{cidr}" },
    "pulseaudio": { "format": "{volume}% {icon}", "format-icons": [""] }
}
```

`dotfiles/dot_config/waybar/style.css`:
```css
* {
    font-family: "JetBrainsMono Nerd Font";
    font-size: 13px;
}

window#waybar {
    background-color: #ffffff;
    color: #2b0a00;
}

#workspaces button.active {
    background-color: #ff4500;
    color: #ffffff;
}

#clock, #network, #battery, #pulseaudio, #tray {
    padding: 0 8px;
    color: #2b0a00;
}

#battery.warning {
    color: #ff6a00;
}
```

- [ ] **Step 2: wofi config + CSS**

`dotfiles/dot_config/wofi/config`:
```
width=600
height=400
show=drun
prompt=Search...
```

`dotfiles/dot_config/wofi/style.css`:
```css
window {
    background-color: #ffffff;
    border: 2px solid #ff4500;
}

#input {
    background-color: #ffffff;
    color: #2b0a00;
    border: 1px solid #ff6a00;
}

#entry:selected {
    background-color: #ff4500;
    color: #ffffff;
}
```

- [ ] **Step 3: wlogout layout + CSS**

`dotfiles/dot_config/wlogout/layout`:
```
{
    "label" : "lock",
    "action" : "hyprlock",
    "text" : "Lock",
    "keybind" : "l"
}
{
    "label" : "logout",
    "action" : "hyprctl dispatch exit",
    "text" : "Logout",
    "keybind" : "e"
}
{
    "label" : "shutdown",
    "action" : "systemctl poweroff",
    "text" : "Shutdown",
    "keybind" : "s"
}
{
    "label" : "reboot",
    "action" : "systemctl reboot",
    "text" : "Reboot",
    "keybind" : "r"
}
```

`dotfiles/dot_config/wlogout/style.css`:
```css
window {
    background-color: rgba(255,255,255,0.95);
}

button {
    background-color: #ffffff;
    border: 2px solid #ff6a00;
    color: #2b0a00;
}

button:focus, button:active, button:hover {
    background-color: #ff4500;
    color: #ffffff;
}
```

- [ ] **Step 4: Write the pixel-sampling verification script**

`scripts/verify_palette.py`:
```python
#!/usr/bin/env python3
"""Sample specific pixels from a screenshot and assert they match the locked
TorchOS palette within tolerance. Companion to the grim screenshots taken
during Group A palette verification — sample points are picked by eye
against each real screenshot since UI layout isn't fixed here, so they're
passed as arguments rather than hardcoded.

Usage: python3 scripts/verify_palette.py shot.png x1,y1,#ff4500 x2,y2,#2b0a00 ...
"""
import sys
from PIL import Image

TOLERANCE = 12  # sum of per-channel abs delta — same threshold as
                 # scripts/branding/generate_wallpaper.py's check()


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    img = Image.open(sys.argv[1]).convert("RGB")
    failures = []
    for spec in sys.argv[2:]:
        x, y, hexval = spec.split(",")
        x, y = int(x), int(y)
        expect = hex_to_rgb(hexval)
        got = img.getpixel((x, y))
        delta = sum(abs(a - b) for a, b in zip(got, expect))
        status = "OK" if delta <= TOLERANCE else "FAIL"
        if status == "FAIL":
            failures.append(spec)
        print(f"({x},{y}) expect {hexval} got {got} delta={delta} {status}")
    if failures:
        print(f"\n{len(failures)} sample(s) failed: {failures}")
        sys.exit(1)
    print("\nall samples within tolerance")


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Deploy the theming files via chezmoi**

```bash
scp -P 2222 -r dotfiles/dot_config/waybar dotfiles/dot_config/wofi dotfiles/dot_config/wlogout torch@localhost:~/torchos-dotfiles/dot_config/
ssh -p 2222 torch@localhost 'chezmoi diff'
```
Read the diff, then:
```bash
ssh -p 2222 torch@localhost 'chezmoi apply -v'
ssh -p 2222 torch@localhost 'export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1; pkill waybar; hyprctl dispatch exec waybar'
```

- [ ] **Step 6: Screenshot and sample**

```bash
ssh -p 2222 torch@localhost 'export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/) WAYLAND_DISPLAY=wayland-1; grim /tmp/palette.png'
scp -P 2222 torch@localhost:/tmp/palette.png /tmp/torchos-palette.png
```
Read `/tmp/torchos-palette.png` with the Read tool first to find real on-screen coordinates for the
waybar active-workspace pill (expect `#ff4500`) and the waybar background (expect `#ffffff`), then:
```bash
python3 scripts/verify_palette.py /tmp/torchos-palette.png 15,15,#ff4500 400,15,#ffffff
```
Expected: `all samples within tolerance`.

- [ ] **Step 7: Commit**

```bash
git add dotfiles/dot_config/waybar dotfiles/dot_config/wofi dotfiles/dot_config/wlogout scripts/verify_palette.py
git commit -m "feat: palette theming for waybar/wofi/wlogout + verification script"
```

---

## Self-Review

**1. Spec coverage** (against `docs/superpowers/specs/2026-08-26-desktop-polish-design.md`):
- §2 app bundle → Task 1. §3 torch-welcome → Tasks 2–3. §4 palette → Task 3 (torch-welcome surface),
  Task 6 (waybar/wofi/wlogout surfaces); GTK3/4 system theme override is explicitly left as an
  implementation-plan detail by §8 and is not separately themed here beyond the four surfaces this plan
  builds — no gap, matches what §8 scoped in. §5 dotfiles → Tasks 4–6 (all listed managed files
  present). §6 keybinds → Task 5, all five rows covered. §7 verification plan → each task's own
  verification steps implement the corresponding bullet in §7 directly (package spot-checks, chezmoi
  diff discipline, torch-welcome cross-check, keybind exercise, palette pixel sampling).
- Two real gaps found during planning that the design's package table missed: `wlogout` and `chezmoi`
  themselves weren't in §2's table despite being required by §6 and §5 respectively — both added to
  Task 1's candidate list.
- One correction to §3's stated mechanism: Hyprland doesn't process XDG autostart `.desktop` files
  (unlike cachyos-hello's actual target environment) — Task 4 ships the `.desktop` file for compliance
  but wires the real launch through `exec-once`, documented inline.

**2. Placeholder scan**: no TBD/TODO/"add error handling"-style steps — every step has real, complete
file content or a real command with a stated expected result.

**3. Type consistency**: `Diagnose` struct fields (Task 3) match `torch/src/commands/diagnose.rs`'s
exact emitted JSON keys (verified by reading that file directly). The `torch-welcome` binary name is
consistent between Task 2 (workspace member), Task 3 (build/install target), and Task 4's `exec-once`
line. The `dotfiles/dot_config/hypr/bindings.conf` path is consistent between Task 4's `source` line and
Task 5's file creation.

---

## Next steps

Plan complete and saved to `docs/superpowers/plans/2026-08-27-group-a-desktop-polish.md`. Two execution
options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast
   iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with
   checkpoints.
