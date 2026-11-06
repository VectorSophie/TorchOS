#!/usr/bin/env bash
# E. Live desktop on Hyprland >= 0.57 (Lua config): the live session must start Calamares by itself, maximized,
#    with no help from the harness; TorchOS's config must be the one Hyprland loaded (styling, binds, session
#    programs exactly once, keyboard shortcuts, reload); SUPER+I must bring the installer back.
#    The installed user's desktop is checked in supported.sh (after a real greeter login).
source "$(dirname "$0")/lib.sh"
[ -f "${ISO:-}" ] || { echo "no ISO in image/out" >&2; exit 2; }
echo "== E live desktop from $ISO ($(ts))"
start_iso
# Nothing is started over SSH: wait_ssh only runs `true`, wait_calamares only looks at the client list.
wait_ssh live 60 || abort "live session reachable over SSH"
wait_calamares || abort "live session started Calamares by itself"
pass "live session started Calamares by itself"
shot E-live-autostart
CAL="sum(c['class']=='io.calamares.calamares' for c in d)"
MAX="[c['fullscreen'] for c in d if c['class']=='io.calamares.calamares']"
assert "exactly one Calamares window" test "$(hj live clients "$CAL")" = 1
assert "Calamares is maximized (fullscreen state 1 = maximized)" test "$(hj live clients "$MAX")" = "[1]"
# The race seen on the first Lua ISO: a window that maps after Calamares (torch-welcome) un-maximized it, because
# 0.57 defaults misc:on_focus_under_fullscreen to 2. Force that order instead of relying on boot timing.
live 'pkill -x torch-welcome; sleep 1; hyprctl dispatch "hl.dsp.exec_cmd(\"torch-welcome\")" >/dev/null'; sleep 6
assert "torch-welcome reopened after Calamares" test "$(nproc_of live torch-welcome)" = 1
assert "Calamares stays maximized when a window opens after it" test "$(hj live clients "$MAX")" = "[1]"
shot E-after-welcome
assert "live.lua (installer autostart) present for the live user" live 'test -s ~/.config/hypr/live.lua'
assert_torch_desktop live E 38
echo "--- installation shortcut"
live 'sudo pkill -x calamares'; sleep 4
assert "Calamares closed" test "$(hj live clients "$CAL")" = 0
python3 image/scripts/dev/qmon.py keys meta_l-i; sleep 15
assert "SUPER+I launches Calamares again" test "$(hj live clients "$CAL")" = 1
assert "and it is maximized" test "$(hj live clients "$MAX")" = "[1]"
shot E-super-i

echo "--- waybar workspace buttons: click and scroll (Hyprland 0.57 Lua IPC, Waybar PR #5013)"
live 'sudo pkill -x calamares'; sleep 3
assert "waybar is the pinned 0.16.0 from the torchos repo" live 'waybar --version | grep -q "0\.16\.0"'
assert "ydotool available in the live session (test only)" \
  live 'sudo pacman -Sy --noconfirm --needed ydotool >/dev/null 2>&1 && (sudo nohup ydotoold >/dev/null 2>&1 &); sleep 2; test -S /tmp/.ydotool_socket'
# bar.sh click <ws> | scroll <dy> | ws: drive the REAL pointer (uinput) over waybar on the first output.
live 'cat > /tmp/bar.sh' <<'BAR'
export YDOTOOL_SOCKET=/tmp/.ydotool_socket
ws() { hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
bar() { hyprctl layers -j | python3 -c '
import json,sys
for mon, m in json.load(sys.stdin).items():
    for lv in m["levels"].values():
        for l in lv:
            if l["namespace"] == "waybar" and l["x"] == 0 and l["y"] == 0: print(l["x"], l["y"], l["w"], l["h"]); sys.exit()'; }
# libinput doubles relative motion in this VM: move from the origin by half the distance (even targets).
to() { sudo -E ydotool mousemove --absolute -x 0 -y 0; sudo -E ydotool mousemove -x $(($1 / 2)) -y $(($2 / 2)); sleep 0.3; }
read -r X Y W H < <(bar); [ -n "$H" ] || { echo "no waybar layer on the first output"; exit 2; }
case $1 in
  ws) ws ;;
  click) for x in $(seq $((X + 6)) 12 $((X + 240))); do
           to $((x / 2 * 2)) $(((Y + H / 2) / 2 * 2)); sudo -E ydotool click 0xC0 >/dev/null; sleep 0.6
           [ "$(ws)" = "$2" ] && { echo "click at x=$x -> workspace $2"; exit 0; }
         done; echo "no click reached workspace $2 (still $(ws))"; exit 1 ;;
  scroll) to $(((X + 20) / 2 * 2)) $(((Y + H / 2) / 2 * 2)); sudo -E ydotool mousemove --wheel -x 0 -y "$2"; sleep 1; ws ;;
esac
BAR
# Two workspaces on the first output: 1 and 3 (a kitty keeps 3 open), start on 1.
live 'hyprctl dispatch "hl.dsp.focus({ workspace = 3 })" >/dev/null; hyprctl dispatch "hl.dsp.exec_cmd(\"kitty\")" >/dev/null; sleep 3; hyprctl dispatch "hl.dsp.focus({ workspace = 1 })" >/dev/null; sleep 1'
assert "start on workspace 1" test "$(live 'bash /tmp/bar.sh ws')" = 1
bar_round() {  # bar_round <label> <expect: works|broken>
  local c s1 s2
  c=$(live 'bash /tmp/bar.sh click 3'); echo "$1 click: $c"
  s1=$(live 'hyprctl dispatch "hl.dsp.focus({ workspace = 1 })" >/dev/null; bash /tmp/bar.sh scroll 1')
  s2=$(live 'bash /tmp/bar.sh scroll -1'); echo "$1 scroll: 1 -> $s1 -> $s2"
  if [ "$2" = works ]; then
    assert "$1: clicking workspace 3 in waybar switches to it" has '^click at x=[0-9]+ -> workspace 3$' "$c"
    assert "$1: scrolling on waybar leaves workspace 1, scrolling back returns (1 -> $s1 -> $s2)" \
      sh -c '[ "$1" != 1 ] && [ "$2" = 1 ]' _ "$s1" "$s2"
  else
    assert "$1: clicking waybar does NOT switch workspace (the defect)" has '^no click reached workspace 3' "$c"
    assert "$1: scrolling on waybar does NOT switch workspace (1 -> $s1 -> $s2)" sh -c '[ "$1" = 1 ] && [ "$2" = 1 ]' _ "$s1" "$s2"
  fi
  live 'hyprctl dispatch "hl.dsp.focus({ workspace = 1 })" >/dev/null'
}
bar_round "waybar 0.16.0" works
shot E-waybar-0.16
# A/B in the same session (live RAM overlay, test only): the [extra] 0.15.0 build must show the defect.
live 'sudo pacman -Sw --noconfirm extra/waybar >/dev/null 2>&1; sudo pacman -U --noconfirm /var/cache/pacman/pkg/waybar-0.15.0-*.pkg.tar.zst >/dev/null 2>&1; pkill -x waybar; sleep 1; hyprctl dispatch "hl.dsp.exec_cmd(\"waybar\")" >/dev/null; sleep 4'
assert "waybar 0.15.0 from [extra] now running" live 'waybar --version | grep -q "0\.15\.0" && pgrep -x waybar >/dev/null'
assert "Hyprland 0.57 refuses hyprlang IPC dispatch (what 0.15.0 sends)" \
  has 'your syntax might need to be updated' "$(live 'hyprctl dispatch workspace 3; echo')"
bar_round "waybar 0.15.0" broken
finish
