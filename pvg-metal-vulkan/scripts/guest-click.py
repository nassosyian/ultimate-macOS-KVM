#!/usr/bin/env python3
"""Move the trace VM's USB tablet to absolute screen pixel X Y (1920x1080) and optionally click,
through QMP input-send-event (HMP mouse_move is relative-only and the tablet ignores it).

Usage: guest-click.py X Y [click|double|right|move|drag X2 Y2]
"""
import json
import os
import socket
import sys
import time

SOCK = os.environ.get("VM_QMP") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "kvm-osx", "qmp.sock")
W, H = (int(v) for v in __import__("os").environ.get("GUEST_RES", "1920x1080").split("x"))


def qmp():
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    f.readline()
    return f


def send(f, events):
    f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": events}}) + "\n")
    f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            if "error" in r:
                print(r["error"], file=sys.stderr)
            return


def move(f, x, y):
    send(f, [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
             {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}}])


def button(f, down, b="left"):
    send(f, [{"type": "btn", "data": {"button": b, "down": down}}])


f = qmp()
x, y = int(sys.argv[1]), int(sys.argv[2])
action = sys.argv[3] if len(sys.argv) > 3 else "click"
move(f, x, y)
time.sleep(0.15)
if action in ("click", "double", "right"):
    for _ in range(2 if action == "double" else 1):
        button(f, True, "right" if action == "right" else "left")
        time.sleep(0.08)
        button(f, False, "right" if action == "right" else "left")
        time.sleep(0.08)
elif action == "drag":
    x2, y2 = int(sys.argv[4]), int(sys.argv[5])
    button(f, True)
    for i in range(1, 31):
        move(f, x + (x2 - x) * i / 30, y + (y2 - y) * i / 30)
        time.sleep(0.03)
    button(f, False)
