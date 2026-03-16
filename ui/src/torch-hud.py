import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib
import subprocess


class TorchHUD(Gtk.Window):
    def __init__(self):
        super().__init__(title="Torch HUD")
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        self.set_keep_above(True)
        self.set_decorated(False)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            self.set_visual(visual)

        self.set_default_size(800, 100)
        self.set_position(Gtk.WindowPosition.CENTER)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_name("hud-box")
        self.add(box)

        self.entry = Gtk.Entry()
        self.entry.set_placeholder_text(
            "Torch OS: create [name], reset [name], jupyter [name]..."
        )
        self.entry.connect("activate", self.on_query_submit)
        box.pack_start(self.entry, True, True, 20)

        # Global Escape to hide
        self.connect("key-press-event", self.on_key_press)

    def on_key_press(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.hide()
            return True
        return False

        style_provider = Gtk.CssProvider()
        style_provider.load_from_data(b"""
            #hud-box {
                background-color: rgba(17, 17, 17, 0.85);
                border: 2px solid #ff4500;
                border-radius: 15px;
                padding: 20px;
            }
            entry {
                background: transparent;
                border: none;
                color: white;
                font-size: 18px;
            }
        """)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            style_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def on_query_submit(self, widget):
        query = self.entry.get_text().strip()
        if not query:
            return

        print(f"Torch HUD Action: {query}")
        self.hide()

        # Simple Command Router
        parts = query.split()
        cmd = parts[0].lower()

        if cmd == "create" and len(parts) > 1:
            subprocess.Popen(["torch", "lab", "create", parts[1]])
        elif cmd == "enter" and len(parts) > 1:
            subprocess.Popen(
                ["gnome-terminal", "--", "torch", "lab", "enter", parts[1]]
            )
        elif cmd == "reset" and len(parts) > 1:
            subprocess.Popen(["torch", "lab", "reset", parts[1]])
        elif cmd == "list":
            subprocess.Popen(["gnome-terminal", "--", "torch", "lab", "list", "--wait"])
        elif cmd == "jupyter" and len(parts) > 1:
            subprocess.Popen(
                [
                    "gnome-terminal",
                    "--",
                    "torch",
                    "lab",
                    "enter",
                    parts[1],
                    "--",
                    "jupyter",
                    "notebook",
                    "--ip=0.0.0.0",
                    "--allow-root",
                ]
            )
        else:
            # Fallback to general info or error
            subprocess.Popen(
                [
                    "notify-send",
                    "Torch OS",
                    f"Unknown command: {query}\nTry: create, enter, reset, list, jupyter",
                ]
            )

        self.entry.set_text("")


if __name__ == "__main__":
    win = TorchHUD()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
