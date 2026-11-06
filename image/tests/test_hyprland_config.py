"""Regression tests for the Hyprland configuration. Hyprland 0.57 reads only Lua (hyprland.lua) and silently replaces
anything else with its own stock config, so a reintroduced hyprlang file or `exec-once` would go unnoticed until a VM
boots the stock desktop. `hyprctl dispatch` takes Lua expressions too. hyprland-config-scenario.sh runs the real
Hyprland --verify-config on the same files."""
import os
import re
import subprocess
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
HYPR = os.path.join(ROOT, "dotfiles", "dot_config", "hypr")
LIVE_SETUP = os.path.join(ROOT, "image", "archiso", "airootfs", "usr", "local", "bin", "torch-live-setup")
# Every place that ships files into an image or a home directory.
SHIPPED = ["dotfiles", "image/archiso", "image/calamares", "pkg"]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def shipped_files(paths=SHIPPED):
    """Tracked and new (not ignored) files: a freshly added legacy file must fail too."""
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "--cached", "--others", "--exclude-standard", "--", *paths],
                         capture_output=True, text=True, check=True)
    return [p for p in out.stdout.splitlines() if os.path.isfile(os.path.join(ROOT, p))]


class HyprlandConfig(unittest.TestCase):
    def test_lua_entry_point_and_modules(self):
        for name in ("hyprland.lua", "bindings.lua", "local.lua"):
            self.assertTrue(os.path.isfile(os.path.join(HYPR, name)), name)

    def test_no_legacy_compositor_config(self):
        # hypridle.conf / hyprpaper.conf belong to their own programs, which still read hyprlang.
        legacy = [p for p in shipped_files()
                  if re.search(r"(^|/)(hyprland|bindings)\.conf$|/hypr/conf\.d/", p)]
        self.assertEqual(legacy, [])

    def test_no_hyprlang_keywords_shipped(self):
        # Only where Hyprland config comes from (dotfiles, live-ISO files); a PKGBUILD's `source=(` is not hyprlang.
        bad = []
        for p in shipped_files(["dotfiles", "image/archiso"]):
            try:
                text = read(os.path.join(ROOT, p))
            except UnicodeDecodeError:
                continue
            for n, line in enumerate(text.splitlines(), 1):
                if re.match(r"\s*(exec-once|exec|bind[a-z]*|source|windowrulev?2?)\s*=", line):
                    bad.append(f"{p}:{n}: {line.strip()}")
        self.assertEqual(bad, [])

    def test_hyprctl_dispatch_uses_lua(self):
        # 0.57: `hyprctl dispatch 'hl.dsp.exit()'`; the old `hyprctl dispatch exit` is a Lua syntax error.
        bad = []
        for p in shipped_files():
            try:
                text = read(os.path.join(ROOT, p))
            except UnicodeDecodeError:
                continue
            for m in re.finditer(r"hyprctl\s+dispatch\s+(\S+)", text):
                if not m.group(1).lstrip("'\"").startswith("hl."):
                    bad.append(f"{p}: {m.group(0)}")
        self.assertEqual(bad, [])

    def test_live_session_starts_installer(self):
        live = read(LIVE_SETUP)
        self.assertIn("/.config/hypr/live.lua", live)
        self.assertRegex(live, r'hl\.on\("hyprland\.start".*calamares-launch')
        self.assertIn('hl.bind("SUPER + I", hl.dsp.exec_cmd("calamares-launch"))', live)

    def test_optional_modules_loaded_last(self):
        lua = read(os.path.join(HYPR, "hyprland.lua"))
        last_require = lua.rindex("pcall(require, name)")
        self.assertGreater(last_require, lua.index('hl.on("hyprland.start"'))
        self.assertIn('ipairs({ "live", "local" })', lua)

    def test_chezmoi_never_replaces_local_lua(self):
        # /usr/share/torchos/dotfiles is a chezmoi source too; `chezmoi apply` would overwrite the user's local.lua.
        ignore = read(os.path.join(ROOT, "dotfiles", ".chezmoiignore")).splitlines()
        self.assertIn(".config/hypr/local.lua", ignore)

    def test_waybar_workspaces_needs_lua_dispatch(self):
        # Hyprland 0.57 runs every IPC `dispatch X` as hl.dispatch(X); waybar's hyprland/workspaces sends Lua-form
        # dispatches (clicks, scroll) only from 0.16.0 on (Waybar PR #5013). Older waybar: the bar's buttons do nothing.
        bar = read(os.path.join(ROOT, "dotfiles", "dot_config", "waybar", "config"))
        if '"hyprland/workspaces"' not in bar:
            self.skipTest("bar does not use hyprland/workspaces")
        pkgbuild = read(os.path.join(ROOT, "pkg", "torchos", "PKGBUILD"))
        m = re.search(r"'waybar>=([0-9.]+)'", pkgbuild)
        self.assertIsNotNone(m, "torch-config must require a minimum waybar version")
        self.assertGreaterEqual(tuple(int(x) for x in m.group(1).split(".")), (0, 16, 0))

    def test_packaged_as_skeleton(self):
        pkgbuild = read(os.path.join(ROOT, "pkg", "torchos", "PKGBUILD"))
        self.assertIn('cp -a "$srcdir/src/dotfiles/dot_config" "$pkgdir/etc/skel/.config"', pkgbuild)


if __name__ == "__main__":
    unittest.main()
