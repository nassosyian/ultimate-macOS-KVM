#!/usr/bin/env python3
"""
Offline test of file drops on QEMU's GTK window: on a private Xvfb display, a paused QEMU
(no disk) with QEMU_GTK_DROP_SOCKET, a GTK drag source offering two files, and xdotool dragging
them onto the QEMU window; a stand-in for the sharing daemon records what QEMU sends.
    scripts/vm-share/test-drop.py [path/to/qemu-system-x86_64]
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
QEMU = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    HERE, "../../src/qemu/build/qemu-system-x86_64")
DISP = ":98"

SOURCE = r'''
import sys, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk
uris = sys.argv[1:]
w = Gtk.Window(title="drag source")
w.set_default_size(200, 200)
w.move(1300, 0)
area = Gtk.EventBox()
area.add(Gtk.Label(label="drag me"))
area.drag_source_set(Gdk.ModifierType.BUTTON1_MASK,
                     [Gtk.TargetEntry.new("text/uri-list", 0, 0)], Gdk.DragAction.COPY)
area.connect("drag-data-get", lambda w, ctx, sd, info, t: sd.set_uris(uris))
w.add(area)
w.show_all()
Gtk.main()
'''


def main():
    tmp = tempfile.mkdtemp(prefix="kvm-drop-test-")
    sock_path = f"{tmp}/share.sock"
    files = [f"{tmp}/a b.txt", f"{tmp}/ünï.pdf"]
    for f in files:
        open(f, "w").write("x")
    got = []
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)

    def accept():
        c, _ = srv.accept()
        got.append(c.makefile().readline())
    threading.Thread(target=accept, daemon=True).start()

    env = dict(os.environ, DISPLAY=DISP, QEMU_GTK_DROP_SOCKET=sock_path, GDK_BACKEND="x11")
    env.pop("WAYLAND_DISPLAY", None)
    procs = [subprocess.Popen(["Xvfb", DISP, "-screen", "0", "1600x1000x24", "-nolisten", "tcp"],
                              stderr=subprocess.DEVNULL)]
    time.sleep(1)
    try:
        procs.append(subprocess.Popen(
            [QEMU, "-machine", "q35", "-nodefaults", "-vga", "std", "-m", "64", "-S",
             "-display", "gtk,zoom-to-fit=off"], env=env,
            stdout=open(f"{tmp}/qemu.log", "w"), stderr=subprocess.STDOUT))
        uris = [f"file://{f}" for f in files]
        uris = [subprocess.run([sys.executable, "-c",
                                "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))", u[7:]],
                               capture_output=True, text=True).stdout.strip() for u in uris]
        uris = ["file://" + u for u in uris]
        procs.append(subprocess.Popen([sys.executable, "-c", SOURCE, *uris], env=env))
        time.sleep(3)
        xd = lambda *a: subprocess.run(["xdotool", *map(str, a)], env=env)
        xd("mousemove", 1400, 100)
        xd("mousedown", 1)
        for x in range(1390, 300, -60):
            xd("mousemove", x, 120)
            time.sleep(0.05)
        xd("mousemove", 300, 250)
        time.sleep(0.5)
        xd("mouseup", 1)
        for _ in range(30):
            if got:
                break
            time.sleep(0.1)
        ok = bool(got) and json.loads(got[0]) == {"t": "drop", "paths": uris}
        print(("ok   " if ok else "FAIL ") + "drop on the QEMU window -> daemon socket",
              "" if ok else f"got {got!r}, want {uris!r}")
        return 0 if ok else 1
    finally:
        for p in reversed(procs):
            p.terminate()
        time.sleep(0.5)
        if not got:
            print(open(f"{tmp}/qemu.log").read())
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
