// Clipboard and file sharing between the macOS guest and the host (Linux or Windows; guest side).
// Protocol and host side: scripts/vm-share/kvm-share.py. Built and installed by
// scripts/vm-share/guest/install.sh (swiftc in the guest, as VMShare.app: macOS's Local Network
// privacy only lets a bundle with NSLocalNetworkUsageDescription ask for access; a bare binary
// started by launchd gets EHOSTUNREACH for the host). A LaunchAgent starts it at login.
//
// - connects to TCP 7329 on the host (192.168.122.1 bridged / Windows, 10.0.2.2 user networking),
//   retries
// - clipboard: text and images (PNG) both ways; copied Finder files are sent and offered as files
// - menu bar item (arrows): drop files on it to send them to the host's ~/Downloads, or use
//   "Send Files to Host…"; files sent by the host land in ~/Downloads and are shown in Finder
import AppKit
import Foundation

let port: UInt16 = 7329
let hosts = ["192.168.122.1", "10.0.2.2"]
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/VMShare")
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/VMShare")
let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
let clipMax = 64 << 20
let clipFilesMax: Int64 = 1 << 30
let chunk = 1 << 20

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// ---- socket I/O (blocking, on background threads) ----

final class Conn {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    static var lastError: Int32 = 0     // of the last failed open()

    static func open(_ host: String) -> Conn? {
        lastError = 0
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        // non-blocking connect with a 2 s timeout, then back to blocking
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 && errno != EINPROGRESS { lastError = errno; close(fd); return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if r != 0 && (poll(&pfd, 1, 2000) != 1 ||
                      getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            lastError = err != 0 ? err : ETIMEDOUT
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, flags)
        return Conn(fd: fd)
    }

    func writeAll(_ d: Data) throws {
        try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { throw POSIXError(.EPIPE) }
                off += n
            }
        }
    }

    func readExact(_ n: Int) throws -> Data {
        var d = Data(count: n)
        var off = 0
        try d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            while off < n {
                let r = Darwin.read(fd, p.baseAddress! + off, n - off)
                if r <= 0 { throw POSIXError(.ECONNRESET) }
                off += r
            }
        }
        return d
    }

    func sendHeader(_ h: [String: Any], payloadLen: Int) throws {
        var h = h
        h["len"] = payloadLen
        let j = try JSONSerialization.data(withJSONObject: h)
        var n = UInt32(j.count).bigEndian
        try writeAll(Data(bytes: &n, count: 4) + j)
    }

    func send(_ h: [String: Any], _ payload: Data = Data()) throws {
        try sendHeader(h, payloadLen: payload.count)
        if !payload.isEmpty { try writeAll(payload) }
    }

    func recvHeader() throws -> [String: Any] {
        let n = try readExact(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        if n > 1 << 20 { throw POSIXError(.EMSGSIZE) }
        guard let h = try JSONSerialization.jsonObject(with: readExact(Int(n))) as? [String: Any]
        else { throw POSIXError(.EBADMSG) }
        return h
    }

    func shutdownBoth() { Darwin.shutdown(fd, SHUT_RDWR) }
}

// a batch-relative path from the host, or nil if it could escape the batch directory
func safeRel(_ p: Any?) -> String? {
    guard let s = p as? String, !s.isEmpty, !s.hasPrefix("/"), !s.contains("\0") else { return nil }
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return nil }
    return s
}

func uniqueDest(_ folder: URL, _ name: String) -> URL {
    let fm = FileManager.default
    var cand = folder.appendingPathComponent(name)
    let ext = (name as NSString).pathExtension
    let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    var n = 2
    while fm.fileExists(atPath: cand.path) {
        cand = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        n += 1
    }
    return cand
}

// (relative path, url, isDir) for everything under the given files/folders
func walkBatch(_ urls: [URL]) -> [(String, URL, Bool)] {
    var out: [(String, URL, Bool)] = []
    let fm = FileManager.default
    for u in urls {
        let top = u.lastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
        if !isDir.boolValue {
            out.append((top, u, false))
            continue
        }
        out.append((top, u, true))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let en = fm.enumerator(at: u, includingPropertiesForKeys: keys) else { continue }
        let basePath = u.standardizedFileURL.path
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let rel = String(f.standardizedFileURL.path.dropFirst(basePath.count + 1))
            if v?.isDirectory == true {
                out.append(("\(top)/\(rel)", f, true))
            } else if v?.isRegularFile == true {
                out.append(("\(top)/\(rel)", f, false))
            }
        }
    }
    return out
}

// drop target covering the menu-bar button; clicks still open the button's menu
final class DropView: NSView {
    weak var share: Share?
    weak var button: NSStatusBarButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { button?.performClick(nil) }
    override func rightMouseDown(with event: NSEvent) { button?.performClick(nil) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard share?.current() != nil else { return [] }
        button?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { button?.highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { return false }
        share?.sendFiles(urls, purpose: "drop")
        return true
    }
}

final class Share: NSObject {
    var token = ""
    var conn: Conn?
    let sendQ = DispatchQueue(label: "vmshare.send")
    let lock = NSLock()
    let pb = NSPasteboard.general
    var lastChange = 0
    var lastHash = ""
    var statusItem: NSStatusItem!
    var stateItem: NSMenuItem!

    func start() {
        token = (try? String(contentsOf: supportDir.appendingPathComponent("token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if token.isEmpty { log("no token in \(supportDir.path)/token") }
        try? FileManager.default.createDirectory(at: cacheDir.appendingPathComponent("in"),
                                                 withIntermediateDirectories: true)
        setupMenu()
        lastChange = pb.changeCount
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        Thread.detachNewThread { [weak self] in self?.connectLoop() }
    }

    // ---- menu bar item, also a drop target (the status item window forwards drags to us) ----
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                              accessibilityDescription: "Host sharing")
            b.toolTip = "Host sharing: drop files here to send them to the host's Downloads"
            // the drop target is a view over the button (the item's window doesn't exist yet)
            let drop = DropView(frame: b.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.share = self
            drop.button = b
            b.addSubview(drop)
        }
        let m = NSMenu()
        stateItem = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
        m.addItem(stateItem)
        m.addItem(.separator())
        let send = NSMenuItem(title: "Send Files to Host…", action: #selector(chooseFiles),
                              keyEquivalent: "")
        send.target = self
        m.addItem(send)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VM Sharing", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "")
        m.addItem(quit)
        statusItem.menu = m
    }

    func setState(_ connected: Bool, _ host: String = "") {
        DispatchQueue.main.async {
            self.stateItem.title = connected ? "Connected to host (\(host))" : "Not connected"
            self.statusItem.button?.appearsDisabled = !connected
        }
    }

    @objc func chooseFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Send to Host"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { sendFiles(p.urls, purpose: "drop") }
    }


    // ---- connection ----
    func connectLoop() {
        var reported: [String: Int32] = [:]
        while true {
            for h in hosts {
                guard let c = Conn.open(h) else {
                    let e = Conn.lastError
                    if reported[h] != e {
                        reported[h] = e
                        log("\(h): \(String(cString: strerror(e)))" +
                            (e == EHOSTUNREACH ? " (Local Network access denied?)" : ""))
                    }
                    continue
                }
                reported[h] = nil
                do {
                    try c.send(["t": "hello", "token": token, "version": 1,
                                "agent": ProcessInfo.processInfo.operatingSystemVersionString])
                    let hello = try c.recvHeader()
                    if hello["t"] as? String != "hello" { throw POSIXError(.EBADMSG) }
                } catch {
                    log("\(h): handshake failed (token?)")
                    close(c.fd)
                    continue
                }
                log("connected to \(h)")
                lock.lock(); conn = c; lock.unlock()
                setState(true, h)
                reader(c)
                lock.lock(); conn = nil; lock.unlock()
                close(c.fd)
                setState(false)
                log("disconnected from \(h)")
                break
            }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    func current() -> Conn? { lock.lock(); defer { lock.unlock() }; return conn }

    func reader(_ c: Conn) {
        var batches: [String: URL] = [:]
        do {
            while true {
                let h = try c.recvHeader()
                let t = h["t"] as? String ?? ""
                let n = h["len"] as? Int ?? 0
                switch t {
                case "clip":
                    if n > clipMax * 2 { throw POSIXError(.EMSGSIZE) }
                    let data = try c.readExact(n)
                    var parts: [(String, Data)] = []
                    var off = 0
                    for p in h["parts"] as? [[String: Any]] ?? [] {
                        let l = p["len"] as? Int ?? 0
                        if off + l > data.count { break }
                        parts.append((p["kind"] as? String ?? "", data.subdata(in: off..<off + l)))
                        off += l
                    }
                    DispatchQueue.main.async { self.setClip(parts) }
                case "file", "dir":
                    guard let rel = safeRel(h["path"]), let batch = h["batch"] as? String,
                          !batch.isEmpty, batch.allSatisfy({ $0.isLetter || $0.isNumber })
                    else { throw POSIXError(.EINVAL) }
                    let root = batches[batch] ?? cacheDir.appendingPathComponent("in/\(batch)")
                    batches[batch] = root
                    let dest = root.appendingPathComponent(rel)
                    let fm = FileManager.default
                    if t == "dir" {
                        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                        continue
                    }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    fm.createFile(atPath: dest.path, contents: nil)
                    let fh = try FileHandle(forWritingTo: dest)
                    var left = n
                    while left > 0 {
                        let d = try c.readExact(min(chunk, left))
                        fh.write(d)
                        left -= d.count
                    }
                    try fh.close()
                    if let mode = h["mode"] as? Int {
                        try? fm.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: dest.path)
                    }
                case "end":
                    let batch = h["batch"] as? String ?? ""
                    let root = batches.removeValue(forKey: batch)
                        ?? cacheDir.appendingPathComponent("in/\(batch)")
                    let names = (h["names"] as? [Any] ?? []).compactMap { safeRel($0) }
                    let purpose = h["purpose"] as? String ?? ""
                    DispatchQueue.main.async { self.placeFiles(root, names, purpose) }
                default:
                    if n > 0 { _ = try c.readExact(n) }
                }
            }
        } catch {
            log("reader: \(error)")
        }
    }

    // ---- host -> guest ----
    func setClip(_ parts: [(String, Data)]) {
        pb.clearContents()
        for (kind, d) in parts {
            if kind == "text", let s = String(data: d, encoding: .utf8) {
                pb.setString(s, forType: .string)
            } else if kind == "image" {
                pb.setData(d, forType: .png)
                if let rep = NSBitmapImageRep(data: d), let tiff = rep.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)       // most apps paste TIFF
                }
            }
        }
        lastChange = pb.changeCount
        lastHash = hashParts(parts)
        log("host clipboard -> guest: \(parts.map { "\($0.0) \($0.1.count) B" })")
    }

    func placeFiles(_ root: URL, _ names: [String], _ purpose: String) {
        let fm = FileManager.default
        let items = names.map { root.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        if purpose == "drop" {
            var placed: [URL] = []
            for src in items {
                let dest = uniqueDest(downloads, src.lastPathComponent)
                if (try? fm.moveItem(at: src, to: dest)) != nil { placed.append(dest) }
            }
            try? fm.removeItem(at: root)
            log("received from host: \(placed.map { $0.lastPathComponent })")
            if !placed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(placed) }
            return
        }
        if items.isEmpty { return }
        pb.clearContents()
        pb.writeObjects(items as [NSURL])
        lastChange = pb.changeCount
        lastHash = "files:" + items.map { $0.path }.joined(separator: "\n")
        log("host clipboard files -> guest: \(items.map { $0.lastPathComponent })")
        pruneClipBatches(keep: root)
    }

    func pruneClipBatches(keep: URL) {
        let fm = FileManager.default
        let inbox = cacheDir.appendingPathComponent("in")
        let dirs = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys:
                                                    [.contentModificationDateKey])) ?? [])
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
        for d in dirs.dropFirst(8) where d != keep { try? fm.removeItem(at: d) }
    }

    // ---- guest -> host ----
    func hashParts(_ parts: [(String, Data)]) -> String {
        var h = Hasher()
        for (k, d) in parts { h.combine(k); h.combine(d) }
        return String(h.finalize())
    }

    func poll() {
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard current() != nil else { return }
        let types = pb.types ?? []
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let key = "files:" + urls.map { $0.path }.joined(separator: "\n")
            if key == lastHash { return }
            lastHash = key
            var size: Int64 = 0
            for (_, u, isDir) in walkBatch(urls) where !isDir {
                size += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            if size > clipFilesMax {
                log("copied files are \(size >> 20) MiB: not put on the host clipboard (drop them on the menu bar item)")
                return
            }
            sendFiles(urls, purpose: "clip")
            return
        }
        var parts: [(String, Data)] = []
        if let s = pb.string(forType: .string), let d = s.data(using: .utf8), d.count <= clipMax {
            parts.append(("text", d))
        }
        if let png = pb.data(forType: .png) {
            parts.append(("image", png))
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            parts.append(("image", png))
        }
        parts = parts.filter { $0.1.count <= clipMax }
        if parts.isEmpty { return }
        let h = hashParts(parts)
        if h == lastHash { return }
        lastHash = h
        let payload = parts.reduce(Data()) { $0 + $1.1 }
        let hdr: [String: Any] = ["t": "clip", "parts": parts.map { ["kind": $0.0, "len": $0.1.count] }]
        log("clipboard -> host: \(parts.map { "\($0.0) \($0.1.count) B" })")
        sendQ.async { [weak self] in
            guard let c = self?.current() else { return }
            do { try c.send(hdr, payload) } catch { c.shutdownBoth() }
        }
    }

    func sendFiles(_ urls: [URL], purpose: String) {
        let batch = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let names = urls.map { $0.lastPathComponent }
        log("\(purpose) -> host: \(names)")
        sendQ.async { [weak self] in
            guard let c = self?.current() else { return }
            do {
                for (rel, url, isDir) in walkBatch(urls) {
                    if isDir {
                        try c.send(["t": "dir", "batch": batch, "path": rel])
                        continue
                    }
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                    let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                    try c.sendHeader(["t": "file", "batch": batch, "path": rel, "mode": mode],
                                     payloadLen: size)
                    let fh = try FileHandle(forReadingFrom: url)
                    var left = size
                    while left > 0 {
                        var d = fh.readData(ofLength: min(chunk, left))
                        if d.isEmpty { d = Data(count: min(chunk, left)) }   // shrank: pad
                        try c.writeAll(d)
                        left -= d.count
                    }
                    try? fh.close()
                }
                try c.send(["t": "end", "batch": batch, "purpose": purpose, "names": names])
            } catch {
                log("send failed: \(error)")
                c.shutdownBoth()
            }
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let share = Share()
share.start()
app.run()
