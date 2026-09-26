#!/usr/bin/env python3
"""QEMU monitor helper.  qmon.py keys ret alt-n | shot out.png | cmd 'info status' | quit"""
import os, socket, subprocess, sys, tempfile, time

SOCK = os.environ.get("TORCH_MONITOR", os.path.join(os.path.dirname(__file__), "../../vm/monitor.sock"))


def mon(cmds, gap=0.4):
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    s.settimeout(1)
    try:
        s.recv(4096)
    except OSError:
        pass
    out = ""
    for c in cmds:
        s.sendall((c + "\n").encode())
        time.sleep(gap)
        try:
            out += s.recv(65536).decode(errors="ignore")
        except OSError:
            pass
    return out


def keys(*ks, hold=600):
    mon([f"sendkey {k} {hold}" for k in ks], gap=hold / 1000 + 0.3)  # long hold: see README


def shot(png):
    ppm = tempfile.mktemp(suffix=".ppm")
    mon([f"screendump {ppm}"], gap=1.5)
    subprocess.run(["convert", ppm, png], check=True)
    os.remove(ppm)


if __name__ == "__main__":
    c, a = sys.argv[1], sys.argv[2:]
    if c == "keys":
        keys(*a)
    elif c == "shot":
        shot(a[0])
    elif c == "cmd":
        print(mon(a))
    elif c == "quit":
        mon(["quit"])
