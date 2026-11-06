#!/usr/bin/env python3
"""Drive Calamares (already maximized in the live session) from Welcome to Install with a test user.
Env: TORCH_TEST_PW (required, throwaway password), TORCH_TEST_USER (default tester),
     TORCH_PARTITION_ACTION (optional shell command run in the live session on the partition page, for tests that
     pick a non-default choice; see image/tests/vm/rejected.sh).
Then poll ~/.cache/calamares/session.log over SSH. Exit 0 = success, 1 = Calamares reported failure, 3 = no verdict."""
import os, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import qmon, vnc

HERE = os.path.dirname(os.path.abspath(__file__))
pw = os.environ["TORCH_TEST_PW"]
user = os.environ.get("TORCH_TEST_USER", "tester")


def live(cmd):
    return subprocess.run([HERE + "/vmssh.sh", cmd], capture_output=True, text=True).stdout


def ctrl_a():
    s = vnc.conn()
    for d, sym in ((1, vnc.CTRL_L), (1, ord("a")), (0, ord("a")), (0, vnc.CTRL_L)):
        vnc._key(s, sym, d)
    s.close()


live("""hyprctl dispatch 'hl.dsp.focus({ window = "class:io.calamares.calamares" })'""")
for _ in range(3):                       # welcome -> location -> keyboard -> partitions (erase disk is default)
    qmon.keys("alt-n", hold=200); time.sleep(3)
if os.environ.get("TORCH_PARTITION_ACTION"):
    print(live(os.environ["TORCH_PARTITION_ACTION"]), end="")
qmon.keys("alt-n", hold=200); time.sleep(3)   # -> users
vnc.type_text("Test User"); vnc.press("Tab"); ctrl_a(); vnc.type_text(user); vnc.press("Tab"); ctrl_a()
vnc.type_text("torchos-test"); vnc.press("Tab"); vnc.type_text(pw); vnc.press("Tab"); vnc.type_text(pw)
time.sleep(1); qmon.keys("alt-n", hold=200); time.sleep(3)   # -> summary
qmon.keys("alt-i", hold=200)                                  # Install
print("install started; polling")
for _ in range(120):
    time.sleep(10)
    out = live("grep -E 'completion: |onInstallationFailed' ~/.cache/calamares/session.log | tail -1")
    if "succeeded" in out:
        print("INSTALL OK"); break
    if "onInstallationFailed" in out or "completion: failed" in out:   # 3.4.2 logs the latter last
        print("INSTALL FAILED:", out); sys.exit(1)
else:
    print("TIMEOUT: no verdict in session.log"); sys.exit(3)   # not an installer verdict
