import CoreGraphics
import Darwin
import Foundation

// MARK: - Values handed in from the Engine (main thread)

/// One contact as the API exposes it: normalized 0–1 calibrated panel space
/// (`nx`/`ny`) plus the screen-pixel point (`sx`/`sy`) the Engine already mapped
/// through calibration + the active display. Coordinate math stays in the Engine
/// (one source of truth); the server only formats and ships these.
struct APIContact {
    let id: Int
    let nx: Double, ny: Double
    let sx: Double, sy: Double
}

/// A recognized gesture event, built at the Engine's emission sites after its
/// intent latch has decided. Only the fields relevant to `kind` are set.
struct APIGesture {
    let kind: String              // "pinch" | "rotate" | "scroll" | "swipe"
    var value: Double? = nil      // pinch ratio delta / rotate degrees
    var phase: String? = nil      // "began" | "changed" | "ended"
    var dx: Double? = nil, dy: Double? = nil   // scroll deltas (px)
    var direction: String? = nil  // swipe direction
    var fingers: Int? = nil       // swipe finger count
}

// MARK: - Touch API socket server

/// Out-of-process multi-touch API over a Unix-domain stream socket (NDJSON).
/// Lets external apps subscribe to normalized touches + recognized gestures, and
/// (games / kiosks) suppress Gatecaster's own input injection. Protocol reference:
/// `docs/DEVELOPER_API.md` §3 and `docs/TOUCH_API.md`.
///
/// Threading: every byte of socket I/O and all connection-state mutation happen on
/// one serial queue (`q`); the Engine calls `publishFingers`/`publishGesture` on the
/// main thread and we hop onto `q`. Nothing here ever blocks the main run loop —
/// which is mandatory, because the HID callbacks that generate our synthetic input
/// run on it (see CLAUDE.md: "No nextEvent tracking loops").
final class TouchAPIServer {
    static let protocolVersion = 1

    /// Resolved socket path: ~/Library/Application Support/Gatecaster/api.sock
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gatecaster", isDirectory: true)
            .appendingPathComponent("api.sock")
    }

    /// Geometry advertised in `hello` so clients can map normalized → screen. Stored
    /// (not a closure) and only ever touched on `q`: the app layer pushes updates via
    /// `updateGeometry` whenever the display resolves or changes. Reading `engine.bounds`
    /// directly from `q` would race the main thread's hotplug writes (a torn CGRect).
    private var geo: (screen: CGRect, cal: (xMin: Double, xMax: Double, yMin: Double, yMax: Double))
        = (.zero, (0, 0, 0, 0))

    func updateGeometry(screen: CGRect,
                        cal: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)) {
        q.async { [weak self] in self?.geo = (screen, cal) }
    }

    /// Called whenever the union of clients' suppress masks changes. The app layer
    /// applies it (sets `Pointer.suppressInput`, `GestureSynth.suppressGestures`,
    /// and the Engine's edge-trigger flag). Invoked on the main queue so those
    /// flags are written on the same thread the Engine reads them.
    var onSuppress: ((_ input: Bool, _ gestures: Bool, _ edges: Bool) -> Void)?

    private let q = DispatchQueue(label: "com.gatecaster.touchapi")
    private let maxConns = 16
    private var listenFD: Int32 = -1
    private var loggedSuppress = false       // so the suppress-active warning logs once per change
    private var acceptSource: DispatchSourceRead?
    private var conns: [ObjectIdentifier: Conn] = [:]

    // Global phase state (shared across clients so a frame is encoded once, then
    // broadcast). A client that connects mid-touch may first see `moved` for a
    // finger already down — documented and harmless.
    private var lastAccIds = Set<Int>()
    private var lastRawIds = Set<Int>()
    private var prevById = [Int: APIContact]()     // last-seen contact, for ended/cancelled coords
    private var prevPalm = Set<Int>()              // ids that were palm-rejected last frame

    // MARK: lifecycle

    func start() {
        q.async { [weak self] in self?.openSocket() }
    }

    // Mirror HidTouch/Engine's deinit-cleanup pattern. Cleanup is SYNCHRONOUS here,
    // not via stop()'s `q.async { [weak self] … }`: in deinit self is already at zero
    // refcount, so a weak-self async block resolves to nil and cleans up nothing.
    // Doing it inline is safe — there are no references left to schedule racing work
    // against self, and cancel()/close() are thread-safe. (In practice this server
    // lives for the whole app, so this runs only at process teardown.)
    deinit {
        acceptSource?.cancel()
        if listenFD >= 0 { Darwin.close(listenFD) }
        for (_, c) in conns { c.onClosed = nil; c.close() }
        try? FileManager.default.removeItem(at: Self.socketURL)
    }

    func stop() {
        q.async { [weak self] in
            guard let self = self else { return }
            // Drop each connection's onClosed first so tearing down N clients doesn't
            // fire N intermediate recomputeSuppress() calls (which would briefly
            // un-suppress between teardowns); we apply one final clear below.
            for (_, c) in self.conns { c.onClosed = nil; c.close() }
            self.conns.removeAll()
            self.acceptSource?.cancel(); self.acceptSource = nil
            if self.listenFD >= 0 { Darwin.close(self.listenFD); self.listenFD = -1 }
            try? FileManager.default.removeItem(at: Self.socketURL)
            self.recomputeSuppress()
        }
    }

    private func openSocket() {
        let url = Self.socketURL
        let dir = url.deletingLastPathComponent()
        // Create the dir owner-only. The socket carries the whole touch stream
        // (incl. anything the user types on the on-screen keyboard) and lets a
        // client suppress input, so it must NOT be reachable by other local users.
        // createDirectory's permissions only apply if it creates the dir, so chmod
        // unconditionally afterward to tighten an existing, looser one.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        // A stale socket file from a previous run (or crash) blocks bind() with
        // EADDRINUSE — remove it first. The path is ours; nothing else uses it.
        try? FileManager.default.removeItem(at: url)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { logErr("socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            logErr("socket path too long: \(path)"); Darwin.close(fd); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: path.utf8.count + 1) { dst in
                _ = strcpy(dst, path)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { logErr("bind() failed: \(errno)"); Darwin.close(fd); return }
        // Defense in depth: even with the 0700 dir, restrict the socket node itself
        // to owner read/write (macOS checks the socket file's mode on connect()).
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { logErr("listen() failed"); Darwin.close(fd); return }
        setNonBlocking(fd)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        acceptSource = src
    }

    private func acceptPending() {
        // Drain the backlog: the read source coalesces, so loop until EAGAIN.
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { break }
            // Cap concurrent clients so a runaway connector can't exhaust fds/memory.
            // The real consumer count is tiny (a game, a kiosk app); 16 is plenty.
            if conns.count >= maxConns { Darwin.close(cfd); continue }
            setNonBlocking(cfd)
            let conn = Conn(fd: cfd, queue: q)
            conn.onLine = { [weak self, weak conn] line in
                if let self = self, let conn = conn { self.handleCommand(line, from: conn) }
            }
            conn.onClosed = { [weak self, weak conn] in
                guard let self = self, let conn = conn else { return }
                self.conns[ObjectIdentifier(conn)] = nil
                self.recomputeSuppress()
            }
            conns[ObjectIdentifier(conn)] = conn
            sendHello(to: conn)
            conn.resume()
        }
    }

    // MARK: client → server commands

    private func handleCommand(_ line: Data, from conn: Conn) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return }   // tolerate junk lines

        if let subs = obj["subscribe"] as? [String] {
            conn.subs = Set(subs)
        }
        if let s = obj["suppress"] {
            conn.suppress = Self.parseSuppress(s)
            recomputeSuppress()
        }
    }

    /// `true` → all categories; `false`/`[]` → none; array → exactly those names.
    /// Any other type is malformed; we still fail safe (no suppression) but log it,
    /// so a client that sent e.g. `{"suppress":null}` can see why nothing happened
    /// instead of being silently ignored.
    private static func parseSuppress(_ v: Any) -> Set<String> {
        if let b = v as? Bool { return b ? ["input", "gestures", "edges"] : [] }
        if let arr = v as? [String] { return Set(arr) }
        FileHandle.standardError.write(Data(
            "[gatecaster api] ignoring malformed suppress value (\(type(of: v))); expected bool or [string]\n".utf8))
        return []
    }

    private func recomputeSuppress() {
        var input = false, gestures = false, edges = false
        for (_, c) in conns {
            if c.suppress.contains("input") { input = true }
            if c.suppress.contains("gestures") { gestures = true }
            if c.suppress.contains("edges") { edges = true }
        }
        // A client holding input suppressed is invisible to the user (the Mac just
        // stops responding to touch); log the transition so it's diagnosable. There's
        // deliberately no TTL — the socket close is the lease (see DEVELOPER_API.md §3).
        let anySuppress = input || gestures || edges
        if anySuppress != loggedSuppress {
            loggedSuppress = anySuppress
            logErr(anySuppress ? "input suppression ON (a client owns touch)" : "input suppression cleared")
        }
        // Apply on main: these flags are read by the Engine / Pointer on the main
        // run loop, so writing them there avoids any cross-thread visibility games.
        DispatchQueue.main.async { [onSuppress] in onSuppress?(input, gestures, edges) }
    }

    private func sendHello(to conn: Conn) {
        // `ready` is false if a client connects before the display has resolved
        // (geometry still zero) — the client then knows the screen/panel bounds are
        // not yet trustworthy rather than computing a degenerate transform.
        let ready = geo.screen.width > 0 && geo.screen.height > 0
        let msg: [String: Any] = [
            "v": Self.protocolVersion, "type": "hello", "ready": ready,
            "caps": ["fingers", "rawFingers", "gestures", "suppress"],
            "screen": ["x": geo.screen.origin.x, "y": geo.screen.origin.y,
                       "w": geo.screen.width, "h": geo.screen.height],
            "panel": ["xMin": geo.cal.xMin, "xMax": geo.cal.xMax,
                      "yMin": geo.cal.yMin, "yMax": geo.cal.yMax],
        ]
        if let d = Self.encode(msg) { conn.enqueue(d) }
    }

    // MARK: Engine → clients (called on the main thread)

    func publishFingers(raw: [APIContact], accepted: [APIContact]) {
        let t = Date().timeIntervalSince1970     // stamp on the caller's thread, pre-hop
        q.async { [weak self] in self?.emitFingers(raw: raw, accepted: accepted, t: t) }
    }

    func publishGesture(_ g: APIGesture) {
        let t = Date().timeIntervalSince1970
        q.async { [weak self] in self?.emitGesture(g, t: t) }
    }

    private func emitFingers(raw: [APIContact], accepted: [APIContact], t: Double) {
        let accIds = Set(accepted.map(\.id))
        let rawIds = Set(raw.map(\.id))
        let wantAcc = conns.values.contains { $0.subs.contains("fingers") }
        let wantRaw = conns.values.contains { $0.subs.contains("rawFingers") }
        // Even with no subscribers we must keep phase state current, or the first
        // frame after someone subscribes would mis-label every live finger as `began`.
        guard wantAcc || wantRaw else { updatePhaseState(raw: raw, accepted: accepted, accIds: accIds); return }

        if wantAcc {
            var arr = accepted.map { fingerJSON($0, phase: lastAccIds.contains($0.id) ? "moved" : "began", palm: false) }
            for gone in lastAccIds.subtracting(accIds) {       // dropped from accepted
                guard let c = prevById[gone] else { continue }
                // Still present in raw → palm rejection ate it mid-touch (cancelled),
                // otherwise the user genuinely lifted (ended).
                arr.append(fingerJSON(c, phase: rawIds.contains(gone) ? "cancelled" : "ended", palm: false))
            }
            sendToSubscribers(of: "fingers", body: fingerFrame(arr, t: t))
        }
        if wantRaw {
            var arr = raw.map { fingerJSON($0, phase: lastRawIds.contains($0.id) ? "moved" : "began",
                                           palm: !accIds.contains($0.id)) }
            for gone in lastRawIds.subtracting(rawIds) {
                guard let c = prevById[gone] else { continue }
                // Carry the contact's LAST-seen palm verdict into its terminal frame,
                // so a raw-channel client doing its own rejection isn't told a contact
                // that was a palm all along suddenly isn't one as it lifts.
                arr.append(fingerJSON(c, phase: "ended", palm: prevPalm.contains(gone)))
            }
            sendToSubscribers(of: "rawFingers", body: fingerFrame(arr, t: t))
        }
        updatePhaseState(raw: raw, accepted: accepted, accIds: accIds)
    }

    private func updatePhaseState(raw: [APIContact], accepted: [APIContact], accIds: Set<Int>) {
        lastAccIds = accIds
        lastRawIds = Set(raw.map(\.id))
        // Cache last-seen geometry + palm verdict so ended/cancelled frames carry
        // accurate coords and palm state. Keep only currently-live ids so neither
        // structure grows without bound.
        var next = [Int: APIContact]()
        var palms = Set<Int>()
        for c in raw { next[c.id] = c; if !accIds.contains(c.id) { palms.insert(c.id) } }
        prevById = next
        prevPalm = palms
    }

    private func fingerFrame(_ contacts: [[String: Any]], t: Double) -> [String: Any] {
        // `dropped` is always present (0 in the normal case) so a client can read it
        // unconditionally; sendToSubscribers overwrites it per-connection when lagging.
        ["v": Self.protocolVersion, "type": "fingers", "t": t, "dropped": 0, "fingers": contacts]
    }

    private func fingerJSON(_ c: APIContact, phase: String, palm: Bool) -> [String: Any] {
        ["id": c.id, "x": round6(c.nx), "y": round6(c.ny),
         "sx": round2(c.sx), "sy": round2(c.sy), "phase": phase, "palm": palm]
    }

    private func emitGesture(_ g: APIGesture, t: Double) {
        guard conns.values.contains(where: { $0.subs.contains("gestures") }) else { return }
        var body: [String: Any] = ["v": Self.protocolVersion, "type": "gesture",
                                   "t": t, "gesture": g.kind]
        if let v = g.value { body["value"] = round6(v) }
        if let p = g.phase { body["phase"] = p }
        if let dx = g.dx { body["dx"] = round2(dx) }
        if let dy = g.dy { body["dy"] = round2(dy) }
        if let d = g.direction { body["direction"] = d }
        if let f = g.fingers { body["fingers"] = f }
        sendToSubscribers(of: "gestures", body: body)
    }

    /// Encode once for the common case; per-connection re-encode only happens for a
    /// lagging client that has frames to report as `dropped`.
    private func sendToSubscribers(of channel: String, body: [String: Any]) {
        guard let shared = Self.encode(body) else { return }
        for (_, c) in conns where c.subs.contains(channel) {
            if c.dropped == 0 {
                c.enqueue(shared)
            } else {
                let n = c.dropped
                var withDrop = body; withDrop["dropped"] = n
                // Only clear the counter once we've actually built the frame that
                // reports it; if encoding somehow fails, the count survives to the
                // next frame rather than being silently lost.
                if let d = Self.encode(withDrop) { c.dropped = 0; c.enqueue(d) }
            }
        }
    }

    // MARK: helpers

    private static func encode(_ obj: [String: Any]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        d.append(0x0A)   // NDJSON: one object per line
        return d
    }
    private func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func logErr(_ m: String) {
        FileHandle.standardError.write(Data("[gatecaster api] \(m)\n".utf8))
    }
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

// MARK: - One client connection

/// Wraps a client socket: a read source that parses inbound NDJSON command lines,
/// and a non-blocking outbound buffer with a write source armed only when bytes are
/// pending. Backpressure: if the outbound buffer exceeds `outCap`, whole frames are
/// dropped at frame boundaries (preserving NDJSON line integrity) and counted in
/// `dropped`, reported on the next delivered frame. The driver never blocks.
private final class Conn {
    let fd: Int32
    private let q: DispatchQueue
    private let readSrc: DispatchSourceRead
    private var writeSrc: DispatchSourceWrite?
    private var inbuf = Data()
    private var outbuf = Data()
    private var closed = false

    // Set by the server (all touched only on `q`).
    var subs = Set<String>()
    var suppress = Set<String>()
    var dropped = 0

    var onLine: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    private let outCap = 256 * 1024      // ~256 KB backlog before we shed frames
    private let inCap = 8 * 1024          // commands are tiny; cap inbound separately
    private let readChunk = 4096

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.q = queue
        readSrc = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSrc.setEventHandler { [weak self] in self?.onReadable() }
    }

    func resume() { readSrc.resume() }

    private func onReadable() {
        var tmp = [UInt8](repeating: 0, count: readChunk)
        while true {
            let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, readChunk) }
            if n > 0 {
                inbuf.append(contentsOf: tmp[0..<n])
                drainLines()
            } else if n == 0 {
                close(); return                    // EOF: client hung up
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                close(); return
            }
        }
    }

    private func drainLines() {
        while let nl = inbuf.firstIndex(of: 0x0A) {
            let line = inbuf.subdata(in: inbuf.startIndex..<nl)
            inbuf.removeSubrange(inbuf.startIndex...nl)
            if !line.isEmpty { onLine?(line) }
        }
        // Guard against a client that streams bytes with no newline (never a valid
        // command) — a valid command is a short JSON line, so anything past inCap is
        // junk or abuse; drop it rather than let the buffer grow.
        if inbuf.count > inCap { inbuf.removeAll(keepingCapacity: false) }
    }

    /// Append a complete, newline-terminated frame and try to flush. Dropping only
    /// ever happens here at a frame boundary, so the byte stream stays line-valid.
    func enqueue(_ frame: Data) {
        guard !closed else { return }
        if outbuf.count + frame.count > outCap {
            dropped += 1                            // lagging consumer: shed this frame
            return
        }
        outbuf.append(frame)
        flush()
    }

    private func flush() {
        while !outbuf.isEmpty {
            let n = outbuf.withUnsafeBytes { write(fd, $0.baseAddress, outbuf.count) }
            if n > 0 {
                outbuf.removeSubrange(outbuf.startIndex..<outbuf.index(outbuf.startIndex, offsetBy: n))
            } else if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { armWrite(); return }
                if errno == EINTR { continue }
                close(); return
            } else {
                // write() == 0: the socket can't take bytes right now. Treat it like
                // EAGAIN — arm the write source and wait, NOT a spin (returning while
                // armed would re-fire flush() in a tight loop and starve the queue).
                armWrite(); return
            }
        }
        disarmWrite()
    }

    private func armWrite() {
        if writeSrc != nil { return }
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: q)
        w.setEventHandler { [weak self] in self?.flush() }
        w.resume()
        writeSrc = w
    }

    private func disarmWrite() {
        writeSrc?.cancel(); writeSrc = nil
    }

    func close() {
        if closed { return }
        closed = true
        readSrc.cancel()
        writeSrc?.cancel(); writeSrc = nil
        Darwin.close(fd)
        onClosed?()
    }
}
