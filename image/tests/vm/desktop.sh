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
finish
