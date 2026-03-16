import ldtp
import time
import subprocess


def test_torch_manager_launch():
    print("Launching Torch Labs Manager...")
    subprocess.Popen(["python3", "/usr/local/bin/torch-labs-gui.py"])
    time.sleep(2)

    if ldtp.waittillguiexist("Torch Labs Manager"):
        print("Success: Torch Labs Manager window detected.")
    else:
        print("Error: Torch Labs Manager window not found.")
        return False

    buttons = [
        "Create Lab",
        "Enter Lab",
        "Reset Lab",
        "Commit Lab",
        "Launch Jupyter",
        "Delete Lab",
    ]
    for btn in buttons:
        if ldtp.guiexist("Torch Labs Manager", btn):
            print(f"Found button: {btn}")
        else:
            print(f"Missing button: {btn}")
            return False

    ldtp.closewindow("Torch Labs Manager")
    print("Test passed.")
    return True


if __name__ == "__main__":
    test_torch_manager_launch()
