# Start the TorchOS desktop when a non-root user logs in on tty1 (no display manager yet).
if [[ $- == *i* && -z ${WAYLAND_DISPLAY:-} && ${XDG_VTNR:-} == 1 && $EUID -ne 0 ]] && command -v Hyprland >/dev/null; then
  exec Hyprland
fi
