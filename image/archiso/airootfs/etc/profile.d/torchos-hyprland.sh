# Live ISO only: start the desktop when the autologin user lands on tty1. Installed systems use greetd.
if [[ $- == *i* && -z ${WAYLAND_DISPLAY:-} && ${XDG_VTNR:-} == 1 && $EUID -ne 0 ]] && command -v start-hyprland >/dev/null; then
  exec start-hyprland
fi
