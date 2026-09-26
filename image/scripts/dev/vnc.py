#!/usr/bin/env python3
"""Minimal VNC (RFB, no auth) input client.  vnc.py type 'text' | press Return | click X Y"""
import os, socket, struct, sys, time

PORT = int(os.environ.get("TORCH_VNC_PORT", "5901"))
KS = {"Return": 0xFF0D, "Tab": 0xFF09, "Escape": 0xFF1B, "BackSpace": 0xFF08, "Down": 0xFF54, "Up": 0xFF52}
SHIFTED = set('~!@#$%^&*()_+{}|:"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ')
SHIFT_L, CTRL_L = 0xFFE1, 0xFFE3


def conn():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.recv(12); s.sendall(b"RFB 003.008\n")
    n = s.recv(1)[0]; s.recv(n); s.sendall(b"\x01")
    s.recv(4); s.sendall(b"\x01")
    struct.unpack(">HH", s.recv(4)); s.recv(16)
    s.recv(struct.unpack(">I", s.recv(4))[0])
    return s


def _key(s, sym, down):
    s.sendall(struct.pack(">BBxxI", 4, down, sym))


def press(name, mods=()):
    s = conn()
    for m in mods: _key(s, m, 1)
    sym = KS.get(name, ord(name) if len(name) == 1 else 0)
    _key(s, sym, 1); _key(s, sym, 0)
    for m in reversed(mods): _key(s, m, 0)
    s.close()


def type_text(text):
    s = conn()
    for c in text:
        sh = c in SHIFTED
        if sh: _key(s, SHIFT_L, 1)
        _key(s, ord(c), 1); _key(s, ord(c), 0)
        if sh: _key(s, SHIFT_L, 0)
        time.sleep(0.06)
    s.close()


def click(x, y):
    s = conn()
    for m in (0, 1, 0):
        s.sendall(struct.pack(">BBHH", 5, m, int(x), int(y))); time.sleep(0.15)
    s.close()


if __name__ == "__main__":
    c, a = sys.argv[1], sys.argv[2:]
    {"type": lambda: type_text(a[0]), "press": lambda: press(a[0]), "click": lambda: click(a[0], a[1])}[c]()
