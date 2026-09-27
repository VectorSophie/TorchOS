#!/usr/bin/env python3
"""Minimal VNC (RFB, no auth) client.  vnc.py type 'text' | press Return | click X Y | shot out.png
`shot` works with any QEMU display backend (the monitor's screendump does not with -display gtk,gl=on)."""
import os, socket, struct, subprocess, sys, tempfile, time

PORT = int(os.environ.get("TORCH_VNC_PORT", "5901"))
KS = {"Return": 0xFF0D, "Tab": 0xFF09, "Escape": 0xFF1B, "BackSpace": 0xFF08, "Down": 0xFF54, "Up": 0xFF52}
SHIFTED = set('~!@#$%^&*()_+{}|:"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ')
SHIFT_L, CTRL_L = 0xFFE1, 0xFFE3


def conn():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.recv(12); s.sendall(b"RFB 003.008\n")
    n = s.recv(1)[0]; s.recv(n); s.sendall(b"\x01")
    s.recv(4); s.sendall(b"\x01")
    global SIZE
    SIZE = struct.unpack(">HH", _recv(s, 4)); _recv(s, 16)
    _recv(s, struct.unpack(">I", _recv(s, 4))[0])
    return s


def _recv(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError("VNC closed")
        b += c
    return b


def shot(png):
    s = conn()
    w, h = SIZE
    s.settimeout(30)
    # 32bpp little-endian, true colour, R/G/B shifts 16/8/0; raw encoding only; one full update.
    s.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    s.sendall(struct.pack(">BxHi", 2, 1, 0))
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    fb = bytearray(w * h * 3)
    while True:
        if _recv(s, 1)[0] != 0:          # skip non-framebuffer messages (bell, colour map)
            continue
        _recv(s, 1); (n,) = struct.unpack(">H", _recv(s, 2))
        for _ in range(n):
            x, y, rw, rh, enc = struct.unpack(">HHHHi", _recv(s, 12))
            px = _recv(s, rw * rh * 4) if enc == 0 else b""
            for row in range(rh if enc == 0 else 0):
                line = px[row * rw * 4:(row + 1) * rw * 4]
                o = ((y + row) * w + x) * 3
                fb[o:o + rw * 3] = bytes(b for i in range(0, len(line), 4) for b in (line[i + 2], line[i + 1], line[i]))
        break
    s.close()
    ppm = tempfile.mktemp(suffix=".ppm")
    with open(ppm, "wb") as f:
        f.write(b"P6 %d %d 255\n" % (w, h) + bytes(fb))
    subprocess.run(["convert", ppm, png], check=True)
    os.remove(ppm)


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
    {"type": lambda: type_text(a[0]), "press": lambda: press(a[0]), "click": lambda: click(a[0], a[1]), "shot": lambda: shot(a[0])}[c]()
