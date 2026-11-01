#!/usr/bin/env python3
"""
Clipboard and file sharing between the Linux host and the macOS guest (host side).

    kvm-share.py [daemon]          run the daemon (started by scripts/run-pvg-vm.sh)
    kvm-share.py send FILE...      send files/folders to the guest's ~/Downloads
    kvm-share.py status            is the guest agent connected?

The guest agent (scripts/vm-share/guest/VMShare.swift) connects to TCP port 7329 on its default
gateway: 192.168.122.1 (virbr0, bridged networking) or 10.0.2.2 (user networking, which reaches
the host's 127.0.0.1). It proves itself with the token in ~/.config/kvm-osx/share-token (copied
into the guest by scripts/vm-share/install-guest.sh).

Clipboard: text and images (PNG) both ways, both together when the source offers both; copied
files are transferred and offered as files (Nemo/Nautilus paste them, other apps get paths).
Drops: files dropped on the VM window (QEMU's GTK window, qemu-rdw) or given to `send` go to the
guest's ~/Downloads; files the guest sends land in ~/Downloads here.

Protocol (both directions): u32 big-endian header length, JSON header, then header["len"] bytes.
  hello {token, version}                      first message from the guest
  clip  {parts: [{kind: text|image, len}]}    payload: the parts' bytes in order
  file  {batch, path, len, mode}              one file of a batch, path relative ("a/b.txt")
  dir   {batch, path}                         an (empty) directory of a batch
  end   {batch, purpose: clip|drop, names}    batch complete; names = its top-level entries
"""
import hashlib
import json
import os
import queue
import secrets
import shutil
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

PORT = int(os.environ.get("KVM_SHARE_PORT", "7329"))
VERSION = 1
CONF_DIR = os.path.expanduser("~/.config/kvm-osx")
TOKEN_FILE = os.path.join(CONF_DIR, "share-token")
SOCK_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "kvm-osx")
# control socket (drops, `send`, `status`): a unix socket path, or tcp:HOST:PORT where Python has
# no AF_UNIX (Windows); QEMU_GTK_DROP_SOCKET takes the same forms
WINDOWS = os.name == "nt"
# overrides for tests (a private X server, port and folders)
CTL_SOCK = os.environ.get("KVM_SHARE_CTL", "tcp:127.0.0.1:7330" if not hasattr(socket, "AF_UNIX")
                          else os.path.join(SOCK_DIR, "share.sock"))
CACHE = os.environ.get("KVM_SHARE_CACHE", os.path.expanduser("~/.cache/kvm-share"))
DOWNLOADS = os.environ.get("KVM_SHARE_DOWNLOADS", os.path.expanduser("~/Downloads"))
# virbr0 (libvirt bridge) and loopback (user networking: the guest's 10.0.2.2); Windows has no virbr0
LISTEN = tuple(os.environ.get("KVM_SHARE_LISTEN",
                              "127.0.0.1" if WINDOWS else "192.168.122.1,127.0.0.1").split(","))
CLIP_MAX = 64 << 20             # text/image clipboard parts
CLIP_FILES_MAX = 1 << 30        # files copied to the clipboard (transferred eagerly)
KEEP_CLIP_BATCHES = 8
CHUNK = 1 << 20


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def token():
    os.makedirs(CONF_DIR, exist_ok=True)
    if not os.path.exists(TOKEN_FILE):
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, (secrets.token_hex(24) + "\n").encode())
        os.close(fd)
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def safe_rel(path):
    """A batch-relative path from the peer, or None if it could escape the batch directory."""
    if not isinstance(path, str) or not path or path.startswith("/") or "\0" in path:
        return None
    parts = path.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return None
    return os.path.join(*parts)


def unique_dest(folder, name):
    base, ext = os.path.splitext(name)
    if os.path.isdir(os.path.join(folder, name)):
        base, ext = name, ""
    cand, n = name, 2
    while os.path.lexists(os.path.join(folder, cand)):
        cand = f"{base} {n}{ext}"
        n += 1
    return os.path.join(folder, cand)


def notify(summary, body=""):
    if WINDOWS:
        return          # no notify-send; the log has it
    try:
        subprocess.Popen(["notify-send", "-a", "macOS VM", "-i", "computer", summary, body],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def uri_path(uri):
    """Local path of a file:// URI (file:///C:/x on Windows), or None."""
    if not uri.startswith("file://"):
        return None
    p = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
    if WINDOWS:
        import urllib.request
        p = urllib.request.url2pathname(p)
    return p


def ctl_socket():
    """An unconnected control socket and its address (unix path or tcp:HOST:PORT)."""
    if CTL_SOCK.startswith("tcp:"):
        host, port = CTL_SOCK[4:].rsplit(":", 1)
        return socket.socket(socket.AF_INET, socket.SOCK_STREAM), (host, int(port))
    return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM), CTL_SOCK


# ---- framing ----

def send_msg(sock, hdr, payload=b""):
    hdr = dict(hdr, len=len(payload))
    h = json.dumps(hdr).encode()
    sock.sendall(struct.pack(">I", len(h)) + h + payload)


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(min(n - len(buf), CHUNK))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return bytes(buf)


def recv_hdr(sock):
    (n,) = struct.unpack(">I", recv_exact(sock, 4))
    if n > 1 << 20:
        raise ValueError("header too large")
    return json.loads(recv_exact(sock, n))


def walk_batch(paths):
    """(relative path, absolute path, is_dir) for everything under the given files/folders."""
    out = []
    for p in paths:
        p = os.path.abspath(p)
        top = os.path.basename(p.rstrip("/")) or "root"
        if os.path.isdir(p) and not os.path.islink(p):
            out.append((top, p, True))
            for dirpath, dirnames, filenames in os.walk(p):
                rel = os.path.relpath(dirpath, p)
                for d in sorted(dirnames):
                    out.append(("/".join(filter(None, [top, "" if rel == "." else rel, d])),
                                os.path.join(dirpath, d), True))
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    if os.path.isfile(full):
                        out.append(("/".join(filter(None, [top, "" if rel == "." else rel, fn])),
                                    full, False))
        elif os.path.isfile(p):
            out.append((top, p, False))
    return out


def batch_size(paths):
    return sum(os.path.getsize(a) for _, a, d in walk_batch(paths) if not d)


class Guest:
    """The connection to the guest agent: a reader thread, and a writer thread fed by a queue."""

    def __init__(self, app, sock, addr):
        self.app, self.sock, self.addr = app, sock, addr
        self.q = queue.Queue()
        self.alive = True
        threading.Thread(target=self.writer, daemon=True).start()

    def close(self):
        if self.alive:
            self.alive = False
            self.q.put(None)
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    # writer: queued jobs are callables writing to the socket, so big files stream from disk
    def writer(self):
        while True:
            job = self.q.get()
            if job is None:
                return
            try:
                job(self.sock)
            except OSError as e:
                log("send failed:", e)
                self.close()
                return

    def send_clip(self, parts):
        payload = b"".join(data for _, data in parts)
        hdr = {"t": "clip", "parts": [{"kind": k, "len": len(d)} for k, d in parts]}
        self.q.put(lambda s: send_msg(s, hdr, payload))

    def send_files(self, paths, purpose):
        batch = secrets.token_hex(8)
        names = [os.path.basename(os.path.abspath(p).rstrip("/")) or "root" for p in paths]

        def job(s):
            for rel, full, is_dir in walk_batch(paths):
                if is_dir:
                    send_msg(s, {"t": "dir", "batch": batch, "path": rel})
                    continue
                size = os.path.getsize(full)
                hdr = {"t": "file", "batch": batch, "path": rel, "len": size,
                       "mode": stat.S_IMODE(os.stat(full).st_mode)}
                h = json.dumps(hdr).encode()
                s.sendall(struct.pack(">I", len(h)) + h)
                with open(full, "rb") as f:
                    left = size
                    while left:
                        chunk = f.read(min(CHUNK, left))
                        if not chunk:       # file shrank: pad, the header promised `size`
                            chunk = b"\0" * min(CHUNK, left)
                        s.sendall(chunk)
                        left -= len(chunk)
            send_msg(s, {"t": "end", "batch": batch, "purpose": purpose, "names": names})
        self.q.put(job)
        return batch

    # reader
    def run(self):
        batches = {}
        try:
            while True:
                h = recv_hdr(self.sock)
                t, n = h.get("t"), int(h.get("len", 0))
                if t == "clip":
                    if n > CLIP_MAX * 2:
                        raise ValueError("clipboard too large")
                    data, parts, off = recv_exact(self.sock, n), [], 0
                    for p in h.get("parts", []):
                        parts.append((p["kind"], data[off:off + p["len"]]))
                        off += p["len"]
                    self.app.on_remote_clip(parts)
                elif t in ("file", "dir"):
                    rel = safe_rel(h.get("path"))
                    batch = h.get("batch", "")
                    if rel is None or not batch.isalnum():
                        raise ValueError(f"bad path {h.get('path')!r}")
                    root = batches.setdefault(batch, os.path.join(CACHE, "in", batch))
                    dest = os.path.join(root, rel)
                    if t == "dir":
                        os.makedirs(dest, exist_ok=True)
                        continue
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    with open(dest, "wb") as f:
                        left = n
                        while left:
                            chunk = self.sock.recv(min(CHUNK, left))
                            if not chunk:
                                raise ConnectionError("peer closed")
                            f.write(chunk)
                            left -= len(chunk)
                    os.chmod(dest, (h.get("mode") or 0o644) & 0o777)
                elif t == "end":
                    batch = h.get("batch", "")
                    root = batches.pop(batch, os.path.join(CACHE, "in", batch))
                    names = [x for x in (safe_rel(nm) for nm in h.get("names", [])) if x]
                    self.app.on_remote_files(root, names, h.get("purpose"))
                elif n:
                    recv_exact(self.sock, n)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
            log("guest", self.addr, "disconnected:", e)
        finally:
            self.close()
            self.app.on_guest_gone(self)


# ---- the daemon: GTK main loop owns the clipboard; network and control sockets in threads ----

def daemon():
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GdkPixbuf, GLib, Gtk

    TEXT_TARGETS = ("UTF8_STRING", "text/plain;charset=utf-8", "text/plain", "STRING", "TEXT",
                    "COMPOUND_TEXT")
    FILE_TARGETS = ("x-special/gnome-copied-files", "text/uri-list")

    class App:
        def __init__(self):
            self.tok = token()
            self.guest = None
            self.lock = threading.Lock()
            self.clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            self.clip_atom = Gdk.Atom.intern("CLIPBOARD", False)
            self.owner = Gtk.Invisible()            # holds our clipboard ownership
            self.owner.realize()
            self.owner.connect("selection-get", self.on_selection_get)
            self.offer = {}                          # target name -> bytes we serve
            self.last_sent = None                    # hash of what we last sent / received
            self.clip.connect("owner-change", self.on_owner_change)
            os.makedirs(os.path.join(CACHE, "in"), exist_ok=True)

        # -- guest connection --
        def on_guest(self, sock, addr):
            sock.settimeout(30)
            try:
                hello = recv_hdr(sock)
                if hello.get("t") != "hello" or not secrets.compare_digest(
                        str(hello.get("token", "")), self.tok):
                    log("rejected", addr, "(bad token)")
                    sock.close()
                    return
            except (OSError, ValueError, json.JSONDecodeError) as e:
                log("handshake from", addr, "failed:", e)
                sock.close()
                return
            sock.settimeout(None)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            g = Guest(self, sock, addr)
            with self.lock:
                old, self.guest = self.guest, g
            if old:
                old.close()
            log("guest connected from", addr[0], "agent", hello.get("agent", "?"))
            g.q.put(lambda s: send_msg(s, {"t": "hello", "version": VERSION}))
            g.run()

        def on_guest_gone(self, g):
            with self.lock:
                if self.guest is g:
                    self.guest = None

        def current_guest(self):
            with self.lock:
                return self.guest if self.guest and self.guest.alive else None

        # -- local clipboard -> guest --
        def on_owner_change(self, clip, event):
            if event.owner is not None and event.owner == self.owner.get_window():
                return          # we just took it (guest content)
            clip.request_targets(self.on_targets)

        def on_targets(self, clip, atoms, n=None):
            names = [a.name() for a in (atoms or [])]
            g = self.current_guest()
            if not g or not names:
                return
            ft = next((t for t in FILE_TARGETS if t in names), None)
            if ft:
                clip.request_contents(Gdk.Atom.intern(ft, False),
                                      lambda c, sd: self.got_files(sd, ft))
                return
            want_img = "image/png" in names or any(n.startswith("image/") for n in names)
            want_txt = any(t in names for t in TEXT_TARGETS)
            state = {"parts": [], "pending": int(want_img) + int(want_txt)}

            def done(kind, data):
                if data:
                    state["parts"].append((kind, data))
                state["pending"] -= 1
                if state["pending"] == 0 and state["parts"]:
                    self.send_parts(sorted(state["parts"]))

            if want_txt:
                clip.request_text(lambda c, text: done("text", text.encode() if text else None))
            if want_img:
                if "image/png" in names:
                    clip.request_contents(Gdk.Atom.intern("image/png", False),
                                          lambda c, sd: done("image", sd.get_data() or None))
                else:
                    def got_image(c, pix):
                        ok, buf = pix.save_to_bufferv("png", [], []) if pix else (False, None)
                        done("image", bytes(buf) if ok else None)
                    clip.request_image(got_image)

        def send_parts(self, parts):
            parts = [(k, d) for k, d in parts if len(d) <= CLIP_MAX]
            h = hashlib.sha256(b"".join(k.encode() + d for k, d in parts)).hexdigest()
            g = self.current_guest()
            if not parts or not g or h == self.last_sent:
                return
            self.last_sent = h
            log("clipboard -> guest:", ", ".join(f"{k} {len(d)} B" for k, d in parts))
            g.send_clip(parts)

        def got_files(self, sd, target):
            raw = (sd.get_data() or b"").decode("utf-8", "replace")
            lines = [l.strip() for l in raw.replace("\r", "").split("\n") if l.strip()]
            if target == "x-special/gnome-copied-files" and lines and lines[0] in ("copy", "cut"):
                lines = lines[1:]
            paths = [p for p in map(uri_path, lines) if p and os.path.exists(p)]
            if not paths:
                return
            h = hashlib.sha256(("files" + "\n".join(paths)).encode()).hexdigest()
            g = self.current_guest()
            if not g or h == self.last_sent:
                return
            self.last_sent = h
            try:
                size = batch_size(paths)
            except OSError:
                return
            if size > CLIP_FILES_MAX:
                log(f"copied files are {size >> 20} MiB: not put on the guest clipboard "
                    "(drag them onto the VM window instead)")
                return
            log("clipboard files -> guest:", len(paths), "items", size, "B")
            g.send_files(paths, "clip")

        # -- guest -> local clipboard (called from the reader thread) --
        def on_remote_clip(self, parts):
            GLib.idle_add(self.set_clip_parts, parts)

        def set_clip_parts(self, parts):
            self.last_sent = hashlib.sha256(b"".join(k.encode() + d for k, d in parts)).hexdigest()
            offer = {}
            for kind, data in parts:
                if kind == "text":
                    for t in TEXT_TARGETS:
                        offer[t] = data
                elif kind == "image":
                    offer["image/png"] = data
            log("guest clipboard -> host:", ", ".join(f"{k} {len(d)} B" for k, d in parts))
            self.take_clipboard(offer)
            return False

        def on_remote_files(self, root, names, purpose):
            GLib.idle_add(self.place_files, root, names, purpose)

        def place_files(self, root, names, purpose):
            if purpose == "drop":
                os.makedirs(DOWNLOADS, exist_ok=True)
                placed = []
                for nm in names:
                    src = os.path.join(root, nm)
                    if os.path.lexists(src):
                        dest = unique_dest(DOWNLOADS, os.path.basename(nm))
                        shutil.move(src, dest)
                        placed.append(dest)
                shutil.rmtree(root, ignore_errors=True)
                log("received from guest:", placed)
                if placed:
                    notify("Received from macOS", "\n".join(os.path.basename(p) for p in placed)
                           + "\nin ~/Downloads")
                return False
            paths = [os.path.join(root, nm) for nm in names if os.path.lexists(os.path.join(root, nm))]
            if not paths:
                return False
            self.last_sent = hashlib.sha256(("files" + "\n".join(paths)).encode()).hexdigest()
            uris = [GLib.filename_to_uri(p, None) for p in paths]
            offer = {"x-special/gnome-copied-files": ("copy\n" + "\n".join(uris)).encode(),
                     "text/uri-list": ("\r\n".join(uris) + "\r\n").encode()}
            for t in TEXT_TARGETS:
                offer[t] = "\n".join(paths).encode()
            log("guest clipboard files -> host:", paths)
            self.take_clipboard(offer)
            self.prune_clip_batches(root)
            return False

        def prune_clip_batches(self, keep):
            inbox = os.path.join(CACHE, "in")
            dirs = sorted((os.path.join(inbox, d) for d in os.listdir(inbox)),
                          key=os.path.getmtime, reverse=True)
            for d in dirs[KEEP_CLIP_BATCHES:]:
                if d != keep:
                    shutil.rmtree(d, ignore_errors=True)

        def take_clipboard(self, offer):
            Gtk.selection_clear_targets(self.owner, self.clip_atom)
            for i, t in enumerate(offer):
                Gtk.selection_add_target(self.owner, self.clip_atom, Gdk.Atom.intern(t, False), i)
            self.offer = offer
            if not Gtk.selection_owner_set(self.owner, self.clip_atom, Gdk.CURRENT_TIME):
                log("could not take the clipboard")

        def on_selection_get(self, widget, sd, info, time_):
            data = self.offer.get(sd.get_target().name())
            if data is not None:
                sd.set(sd.get_target(), 8, data)

        # -- drops / CLI (control socket) --
        def send_drop(self, paths):
            g = self.current_guest()
            paths = [p for p in paths if os.path.exists(p)]
            if not g:
                return "the guest agent is not connected"
            if not paths:
                return "nothing to send"
            g.send_files(paths, "drop")
            log("drop -> guest:", paths)
            return f"sending {len(paths)} item(s) to the guest's Downloads"

    app = App()

    def serve_tcp(addr):
        try:
            srv = socket.create_server((addr, PORT), reuse_port=False)
        except OSError as e:
            log(f"not listening on {addr}:{PORT}: {e}")
            return
        log(f"listening on {addr}:{PORT}")
        while True:
            c, a = srv.accept()
            threading.Thread(target=app.on_guest, args=(c, a), daemon=True).start()

    def serve_ctl():
        srv, addr = ctl_socket()
        if srv.family == socket.AF_INET:
            srv.bind(addr)          # loopback only (the default): no token needed
        else:
            os.makedirs(SOCK_DIR, exist_ok=True)
            try:
                os.unlink(addr)
            except FileNotFoundError:
                pass
            srv.bind(addr)
            os.chmod(addr, 0o600)
        srv.listen(8)
        while True:
            c, _ = srv.accept()
            with c:
                try:
                    req = json.loads(c.makefile().readline() or "{}")
                    if req.get("t") == "drop":
                        paths = [uri_path(u) or u for u in req.get("paths", [])]
                        reply = app.send_drop(paths)
                    elif req.get("t") == "status":
                        g = app.current_guest()
                        reply = f"guest connected from {g.addr[0]}" if g else "guest not connected"
                    else:
                        reply = "unknown request"
                    c.sendall((reply + "\n").encode())
                except (OSError, ValueError) as e:
                    log("control:", e)

    for a in LISTEN:
        threading.Thread(target=serve_tcp, args=(a,), daemon=True).start()
    threading.Thread(target=serve_ctl, daemon=True).start()
    log("kvm-share daemon ready; token in", TOKEN_FILE)
    if WINDOWS:
        import signal
        signal.signal(signal.SIGINT, lambda *a: GLib.idle_add(Gtk.main_quit))
        GLib.timeout_add(500, lambda: True)     # lets Python run the handler during Gtk.main
    else:
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, Gtk.main_quit)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 2, Gtk.main_quit)
    Gtk.main()


def ctl(req):
    s, addr = ctl_socket()
    try:
        s.connect(addr)
    except OSError:
        print("kvm-share daemon is not running", file=sys.stderr)
        return 1
    s.sendall((json.dumps(req) + "\n").encode())
    print(s.makefile().readline().strip())
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "daemon"
    if cmd == "daemon":
        daemon()
        return 0
    if cmd == "send" and len(argv) > 2:
        return ctl({"t": "drop", "paths": [os.path.abspath(p) for p in argv[2:]]})
    if cmd == "status":
        return ctl({"t": "status"})
    if cmd == "token":
        print(token())
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
