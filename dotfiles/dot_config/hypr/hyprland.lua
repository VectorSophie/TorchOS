-- TorchOS Hyprland configuration (Lua; Hyprland >= 0.57 no longer reads hyprland.conf).
-- Managed by TorchOS: put your own changes in local.lua, which is loaded last and never overwritten.
-- API: /usr/share/hypr/stubs/hl.meta.lua and https://wiki.hypr.land/configuring/

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

hl.env("XCURSOR_SIZE", "24")

hl.config({
    input = {
        kb_layout = "us",
        follow_mouse = 1,
        touchpad = { natural_scroll = false },
    },
    general = {
        gaps_in = 4,
        gaps_out = 8,
        border_size = 2,
        col = {
            active_border = "rgb(ff4500)",
            inactive_border = "rgb(2b0a00)",
        },
        layout = "dwindle",
    },
    decoration = { rounding = 6 },
    animations = { enabled = true },
    dwindle = { preserve_split = true },
})

local mainMod = "SUPER"

hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("kitty"))
hl.bind(mainMod .. " + C", hl.dsp.window.close())
hl.bind(mainMod .. " + M", hl.dsp.exit())
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd("nautilus"))
hl.bind(mainMod .. " + F", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd("wofi --show drun"))

for i = 1, 9 do
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i, follow = true }))
end

package.loaded.bindings = nil -- re-run on a config reload too
require("bindings")

-- Session programs: once per Hyprland start (the old exec-once), not again on a config reload.
hl.on("hyprland.start", function()
    hl.exec_cmd("mkdir -p ~/Pictures/Screenshots")
    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("waybar")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("mako")
    hl.exec_cmd("swayosd-server")
    hl.exec_cmd("torch-welcome")
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")
end)

-- Optional modules, loaded last so they can override anything above: live.lua (written by the live ISO only) and
-- local.lua (yours). A missing file is fine; an error inside one is reported like any config error. Unloading first
-- makes a config reload re-run them.
for _, name in ipairs({ "live", "local" }) do
    package.loaded[name] = nil
    local ok, err = pcall(require, name)
    if not ok and not tostring(err):find("module '" .. name .. "' not found", 1, true) then
        error(err, 0)
    end
end
