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

BUILD_USER="${SUDO_USER:-torch}"

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

# yay bootstrap: makepkg refuses to run as root, so the BUILD runs as the
# invoking non-root user — but `makepkg -si` installs via its own internal
# `sudo pacman -U`, which has no TTY/credential cache in a non-interactive
# session and fails here. Build unprivileged, then install the resulting
# package with the pacman we're already running as root (this script's own
# root context), skipping the nested sudo entirely.
if ! command -v yay &>/dev/null; then
  echo "bootstrapping yay..."
  tmp=$(mktemp -d)
  chown "$BUILD_USER" "$tmp"
  runuser -u "$BUILD_USER" -- bash -c "
    set -euo pipefail
    cd '$tmp'
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git yay-bin
    cd yay-bin
    makepkg --noconfirm
  "
  pacman -U --noconfirm "$tmp"/yay-bin/*.pkg.tar.zst
  rm -rf "$tmp"
fi

if [[ ${#AUR[@]} -gt 0 ]]; then
  echo "installing ${#AUR[@]} AUR packages: ${AUR[*]}"
  # yay's own package-install step also elevates via its own internal
  # `sudo pacman` call (same reason as the yay bootstrap above — it's a
  # normal pacman -U/-S call yay runs itself, not something this script's
  # root context already covers). In real interactive use
  # (`sudo ./install-apps.sh` at a terminal) that's just a second, normal
  # sudo password prompt. For headless/scripted invocation (no tty), set
  # YAY_SUDO_PASSWORD in the environment and this feeds it to sudo's -S
  # (stdin) mode via yay's own --sudoflags — never hardcode a password in
  # this script itself.
  #
  # `yes` feeding a pipe that its reader (yay) can close early (e.g. "up
  # to date, nothing to do") gets SIGPIPE — a classic bash gotcha: with
  # pipefail on, that makes the *pipeline's* exit status 141 even though
  # yay itself exited 0, which then trips `set -e` and kills the whole
  # script right here. Check yay's own exit code via PIPESTATUS instead
  # of trusting the pipeline's composite status.
  if [[ -n "${YAY_SUDO_PASSWORD:-}" ]]; then
    # Using `pipeline; then/else` (not `pipeline || true`) so nothing runs
    # between the pipeline and reading PIPESTATUS — even `true` on the far
    # side of `||` counts as its own pipeline and clobbers PIPESTATUS
    # before the next line could read it.
    if yes "$YAY_SUDO_PASSWORD" | runuser -u "$BUILD_USER" -- yay -S --needed --noconfirm --sudoflags -S "${AUR[@]}"; then
      :
    else
      yay_status=${PIPESTATUS[1]}
      if [[ $yay_status -ne 0 ]]; then
        echo "yay exited with status $yay_status" >&2
        exit "$yay_status"
      fi
    fi
  else
    runuser -u "$BUILD_USER" -- yay -S --needed --noconfirm "${AUR[@]}"
  fi
fi

echo "done."
