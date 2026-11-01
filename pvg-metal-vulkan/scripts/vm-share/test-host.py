#!/usr/bin/env python3
"""
Offline test of kvm-share.py: a fake guest agent against the daemon on a private Xvfb display,
a private port and temporary folders (the real clipboard and ~/Downloads are not touched).
    scripts/vm-share/test-host.py
"""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISP = ":97"
PORT = "17329"
PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                    "1f15c4890000000d49444154789c6360f8cfc0f01f0005000201a5"
                    "f0f2c50000000049454e44ae426082")

# a helper process on the test display: set or read the clipboard with GTK
CLIP_TOOL = r'''
import sys, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib
clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
cmd = sys.argv[1]
if cmd == "targets":
    ok, atoms = clip.wait_for_targets()
    print("\n".join(a.name() for a in atoms) if ok else "")
elif cmd == "get":
    sd = clip.wait_for_contents(Gdk.Atom.intern(sys.argv[2], False))
    sys.stdout.buffer.write(sd.get_data() if sd else b"")
elif cmd == "set":          # set TARGET FILE: own the clipboard for 3 s
    data = open(sys.argv[3], "rb").read()
    w = Gtk.Invisible(); w.realize()
    atom = Gdk.Atom.intern("CLIPBOARD", False)
    Gtk.selection_add_target(w, atom, Gdk.Atom.intern(sys.argv[2], False), 0)
    if sys.argv[2] == "UTF8_STRING":
        Gtk.selection_add_target(w, atom, Gdk.Atom.intern("text/plain", False), 0)
    w.connect("selection-get", lambda w, sd, i, t: sd.set(sd.get_target(), 8, data))
    Gtk.selection_owner_set(w, atom, Gdk.CURRENT_TIME)
    GLib.timeout_add(3000, Gtk.main_quit)
    Gtk.main()
'''

failures = 0


def check(name, cond, detail=""):
    global failures
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    failures += not cond


def send_msg(s, hdr, payload=b""):
    h = json.dumps(dict(hdr, len=len(payload))).encode()
    s.sendall(struct.pack(">I", len(h)) + h + payload)


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError
        b += c
    return b


def recv_msg(s, timeout=5):
    s.settimeout(timeout)
    (n,) = struct.unpack(">I", recv_exact(s, 4))
    h = json.loads(recv_exact(s, n))
    return h, recv_exact(s, h.get("len", 0))


def recv_batch(s):
    """messages until an "end": ({path: bytes or None for dirs}, end header)"""
    files = {}
    while True:
        h, p = recv_msg(s)
        if h["t"] == "file":
            files[h["path"]] = p
        elif h["t"] == "dir":
            files[h["path"]] = None
        elif h["t"] == "end":
            return files, h


def main():
    tmp = tempfile.mkdtemp(prefix="kvm-share-test-")
    env = dict(os.environ, DISPLAY=DISP, KVM_SHARE_PORT=PORT, KVM_SHARE_LISTEN="127.0.0.1",
               KVM_SHARE_CTL=f"{tmp}/ctl.sock", KVM_SHARE_CACHE=f"{tmp}/cache",
               KVM_SHARE_DOWNLOADS=f"{tmp}/Downloads")
    env.pop("WAYLAND_DISPLAY", None)
    tool = f"{tmp}/clip.py"
    open(tool, "w").write(CLIP_TOOL)
    xvfb = subprocess.Popen(["Xvfb", DISP, "-nolisten", "tcp"], stderr=subprocess.DEVNULL)
    time.sleep(1)
    daemon = subprocess.Popen([sys.executable, f"{HERE}/kvm-share.py"], env=env,
                              stdout=open(f"{tmp}/daemon.log", "w"), stderr=subprocess.STDOUT)
    setters = []

    def clip_set(target, data):
        f = f"{tmp}/clipdata-{len(setters)}"
        open(f, "wb").write(data)
        setters.append(subprocess.Popen([sys.executable, tool, "set", target, f], env=env))
        time.sleep(0.5)

    def clip_get(*args):
        return subprocess.run([sys.executable, tool, *args], env=env, capture_output=True,
                              timeout=10).stdout

    try:
        time.sleep(1.5)
        tok = subprocess.run([sys.executable, f"{HERE}/kvm-share.py", "token"], env=env,
                             capture_output=True, text=True).stdout.strip()
        bad = socket.create_connection(("127.0.0.1", int(PORT)))
        send_msg(bad, {"t": "hello", "token": "wrong"})
        bad.settimeout(3)
        check("bad token rejected", bad.recv(1) == b"")
        s = socket.create_connection(("127.0.0.1", int(PORT)))
        send_msg(s, {"t": "hello", "token": tok, "agent": "test"})
        h, _ = recv_msg(s)
        check("hello", h.get("t") == "hello")

        # host -> guest
        clip_set("UTF8_STRING", "héllo from linux".encode())
        h, p = recv_msg(s)
        check("host text -> guest", h["t"] == "clip" and h["parts"][0]["kind"] == "text"
              and p == "héllo from linux".encode(), (h, p))
        clip_set("image/png", PNG)
        h, p = recv_msg(s)
        check("host image -> guest", h["t"] == "clip" and [x["kind"] for x in h["parts"]] ==
              ["image"] and p == PNG, h)
        os.makedirs(f"{tmp}/src/dir/sub")
        open(f"{tmp}/src/a b.txt", "w").write("file A")
        open(f"{tmp}/src/dir/sub/c.bin", "wb").write(os.urandom(3 << 20))
        uris = f"copy\nfile://{tmp}/src/a%20b.txt\nfile://{tmp}/src/dir"
        clip_set("x-special/gnome-copied-files", uris.encode())
        files, end = recv_batch(s)
        check("host files -> guest", end["purpose"] == "clip" and end["names"] == ["a b.txt", "dir"]
              and files.get("a b.txt") == b"file A" and
              files.get("dir/sub/c.bin") == open(f"{tmp}/src/dir/sub/c.bin", "rb").read(),
              (end, sorted(files)))

        # guest -> host
        send_msg(s, {"t": "clip", "parts": [{"kind": "text", "len": 9}, {"kind": "image",
                                                                         "len": len(PNG)}]},
                 b"from mac!" + PNG)
        time.sleep(1)
        targets = clip_get("targets").decode().split()
        check("guest text+image -> host targets", "UTF8_STRING" in targets and
              "image/png" in targets, targets)
        check("guest text -> host", clip_get("get", "UTF8_STRING") == b"from mac!")
        check("guest image -> host", clip_get("get", "image/png") == PNG)
        send_msg(s, {"t": "file", "batch": "b1", "path": "x.txt", "mode": 0o644}, b"XX")
        send_msg(s, {"t": "dir", "batch": "b1", "path": "folder/empty"})
        send_msg(s, {"t": "end", "batch": "b1", "purpose": "clip", "names": ["x.txt", "folder"]})
        time.sleep(1)
        got = clip_get("get", "x-special/gnome-copied-files").decode().split("\n")
        paths = [l[7:] for l in got[1:]]
        check("guest files -> host clipboard", got[0] == "copy" and len(paths) == 2 and
              open(paths[0]).read() == "XX" and os.path.isdir(paths[1] + "/empty"), got)
        for i in range(2):
            send_msg(s, {"t": "file", "batch": f"d{i}", "path": "report.pdf"}, b"%PDF" + bytes([i]))
            send_msg(s, {"t": "end", "batch": f"d{i}", "purpose": "drop", "names": ["report.pdf"]})
        time.sleep(1)
        dl = sorted(os.listdir(f"{tmp}/Downloads")) if os.path.isdir(f"{tmp}/Downloads") else []
        check("guest drop -> Downloads (unique names)", dl == ["report 2.pdf", "report.pdf"], dl)

        # control socket: drop from the VM window / CLI
        out = subprocess.run([sys.executable, f"{HERE}/kvm-share.py", "send", f"{tmp}/src/a b.txt"],
                             env=env, capture_output=True, text=True).stdout
        files, end = recv_batch(s)
        check("send -> guest drop", end["purpose"] == "drop" and files == {"a b.txt": b"file A"},
              (out, end))
        out = subprocess.run([sys.executable, f"{HERE}/kvm-share.py", "status"], env=env,
                             capture_output=True, text=True).stdout
        check("status", "connected from 127.0.0.1" in out, out)

        # a hostile path closes the connection and writes nothing outside the batch
        send_msg(s, {"t": "file", "batch": "evil", "path": "../../escape.txt"}, b"no")
        s.settimeout(3)
        try:
            closed = s.recv(1) == b""
        except OSError:
            closed = True
        check("path traversal rejected", closed and not os.path.exists(f"{tmp}/escape.txt")
              and not os.path.exists(f"{tmp}/cache/escape.txt"))
    except Exception as e:      # report and clean up
        check("exception", False, repr(e))
    finally:
        for p in setters + [daemon]:
            p.terminate()
        daemon.wait(5)
        xvfb.terminate()
        if failures:
            print("daemon log:\n" + open(f"{tmp}/daemon.log").read())
        shutil.rmtree(tmp, ignore_errors=True)
    print("all passed" if not failures else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
