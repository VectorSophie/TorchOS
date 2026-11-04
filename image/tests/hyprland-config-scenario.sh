#!/usr/bin/env bash
# Validate the shipped Hyprland Lua config with the real Hyprland of the current Arch repos (`Hyprland
# --verify-config`: unknown options, wrong dispatcher arguments, unknown rule fields and Lua errors all fail), as an
# installed user (/etc/skel) and as the live user (plus the live.lua that torch-live-setup writes). Runs inside a
# disposable archlinux:base-devel container (image/tests/run.sh); the repo is mounted read-only at /src.
set -uo pipefail
pacman -Sy --noconfirm --needed hyprland >/dev/null 2>&1 || { echo "cannot install hyprland"; exit 2; }
echo "  hyprland $(pacman -Q hyprland | cut -d' ' -f2)"
useradd -m t && install -d -o t -m 700 /run/user/1000 || exit 2
fail=0
for layout in installed live; do
  rm -rf /home/t/.config && mkdir -p /home/t/.config && cp -r /src/dotfiles/dot_config/hypr /home/t/.config/
  if [ $layout = live ]; then
    sed -n "/<<'LUA'/,/^LUA$/p" /src/image/archiso/airootfs/usr/local/bin/torch-live-setup | sed '1d;$d' > /home/t/.config/hypr/live.lua
    [ -s /home/t/.config/hypr/live.lua ] || { echo "  FAIL live: no live.lua heredoc in torch-live-setup"; fail=1; continue; }
  fi
  chown -R t /home/t
  out=$(su t -c 'cd /tmp; XDG_RUNTIME_DIR=/run/user/1000 Hyprland --verify-config -c ~/.config/hypr/hyprland.lua 2>&1' |
        sed -n '/Config parsing result/,$p' | grep -v '^=\|^$')
  if [ "$out" = "config ok" ]; then echo "  ok: $layout config verifies"; else echo "  FAIL $layout: $out"; fail=1; fi
done
exit $fail
