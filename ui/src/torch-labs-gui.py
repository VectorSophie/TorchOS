import gi
import subprocess
import json

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib


class TorchLabsManager(Gtk.Window):
    def __init__(self):
        super().__init__(title="Torch Labs Manager")
        self.set_default_size(600, 400)
        self.set_border_width(10)

        main_hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.add(main_hbox)

        # Left: Lab List
        list_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        main_hbox.pack_start(list_vbox, True, True, 0)

        label_list = Gtk.Label(label="Available Labs")
        list_vbox.pack_start(label_list, False, False, 0)

        self.liststore = Gtk.ListStore(str)
        self.treeview = Gtk.TreeView(model=self.liststore)
        renderer_text = Gtk.CellRendererText()
        column_text = Gtk.TreeViewColumn("Name", renderer_text, text=0)
        self.treeview.append_column(column_text)
        self.treeview.get_selection().connect("changed", self.on_selection_changed)

        scrolled_window = Gtk.ScrolledWindow()
        scrolled_window.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scrolled_window.add(self.treeview)
        list_vbox.pack_start(scrolled_window, True, True, 0)

        # Right: Info and Actions
        details_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        main_hbox.pack_start(details_vbox, False, False, 0)

        self.info_label = Gtk.Label(label="Select a lab to see details")
        self.info_label.set_justify(Gtk.Justification.LEFT)
        details_vbox.pack_start(self.info_label, True, True, 0)

        actions_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        details_vbox.pack_start(actions_box, False, False, 0)

        btn_create = Gtk.Button(label="Create Lab")
        btn_create.connect("clicked", self.on_create_clicked)
        actions_box.pack_start(btn_create, False, False, 0)

        self.btn_enter = Gtk.Button(label="Enter Lab")
        self.btn_enter.connect("clicked", self.on_enter_clicked)
        actions_box.pack_start(self.btn_enter, False, False, 0)

        self.btn_reset = Gtk.Button(label="Reset Lab")
        self.btn_reset.connect("clicked", self.on_reset_clicked)
        actions_box.pack_start(self.btn_reset, False, False, 0)

        self.btn_delete = Gtk.Button(label="Delete Lab")
        self.btn_delete.connect("clicked", self.on_delete_clicked)
        actions_box.pack_start(self.btn_delete, False, False, 0)

        self.refresh_labs()
        self.update_button_sensitivity(False)

    def refresh_labs(self):
        self.liststore.clear()
        try:
            result = subprocess.run(
                ["torch", "lab", "list"], capture_output=True, text=True
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if line.strip().startswith("- "):
                        lab_name = line.strip()[2:]
                        self.liststore.append([lab_name])
        except Exception as e:
            print(f"Error refreshing labs: {e}")

    def on_selection_changed(self, selection):
        model, treeiter = selection.get_selected()
        if treeiter is not None:
            lab_name = model[treeiter][0]
            self.update_info(lab_name)
            self.update_button_sensitivity(True)
        else:
            self.info_label.set_text("Select a lab to see details")
            self.update_button_sensitivity(False)

    def update_info(self, lab_name):
        try:
            result = subprocess.run(
                ["torch", "lab", "info", lab_name], capture_output=True, text=True
            )
            if result.returncode == 0:
                self.info_label.set_text(result.stdout)
            else:
                self.info_label.set_text(f"Error getting info for {lab_name}")
        except Exception as e:
            self.info_label.set_text(f"Exception: {e}")

    def update_button_sensitivity(self, sensitive):
        self.btn_enter.set_sensitive(sensitive)
        self.btn_reset.set_sensitive(sensitive)
        self.btn_delete.set_sensitive(sensitive)

    def on_create_clicked(self, widget):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Create New Lab",
        )
        dialog.format_secondary_text("Enter name for the new lab:")
        entry = Gtk.Entry()
        dialog.get_content_area().pack_end(entry, False, False, 0)
        dialog.show_all()
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            name = entry.get_text()
            if name:
                subprocess.run(["torch", "lab", "create", name])
                self.refresh_labs()
        dialog.destroy()

    def on_enter_clicked(self, widget):
        model, treeiter = self.treeview.get_selection().get_selected()
        if treeiter is not None:
            lab_name = model[treeiter][0]
            # Opening in a terminal since 'enter' is interactive
            subprocess.Popen(
                ["gnome-terminal", "--", "torch", "lab", "enter", lab_name]
            )

    def on_reset_clicked(self, widget):
        model, treeiter = self.treeview.get_selection().get_selected()
        if treeiter is not None:
            lab_name = model[treeiter][0]
            subprocess.run(["torch", "lab", "reset", lab_name])
            self.update_info(lab_name)

    def on_delete_clicked(self, widget):
        model, treeiter = self.treeview.get_selection().get_selected()
        if treeiter is not None:
            lab_name = model[treeiter][0]
            subprocess.run(["torch", "lab", "delete", lab_name])
            self.refresh_labs()


if __name__ == "__main__":
    win = TorchLabsManager()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
