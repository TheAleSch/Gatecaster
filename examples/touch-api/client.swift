#!/usr/bin/env swift
// Gatecaster Touch API — reference client (Swift, Foundation + Network only).
//
// Connects to the local Gatecaster socket over a Unix-domain stream, subscribes
// to the `fingers` and `gestures` channels, and prints a live readout: an
// in-place finger summary line plus one line per gesture event.
//
// With `--suppress` it demonstrates kiosk mode: it tells Gatecaster to stop
// injecting pointer/click/scroll/keystroke input and holds that until Ctrl-C.
// Suppression is leased to the socket connection, so simply exiting releases it
// — there is no heartbeat and no way to leave touch wedged off.
//
// Protocol reference: docs/TOUCH_API.md. Implementation: Sources/Gatecaster/TouchAPI.swift.
//
// Run (as a script — no build step, no package):
//   swift client.swift              # read-only: print fingers + gestures
//   swift client.swift --suppress   # also suppress system input (kiosk demo)
//
// To embed in a real app, lift `LineReader`, the `TouchClient` connection
// handling, and the Codable models below; they have no script-only dependencies.

import Foundation
import Network

// The socket Gatecaster creates on launch (local-only; no network listener).
let sockPath = ("~/Library/Application Support/Gatecaster/api.sock" as NSString)
    .expandingTildeInPath

let suppress = CommandLine.arguments.contains("--suppress")

// MARK: - Wire models
//
// Only the fields this client uses are decoded. Codable ignores unknown keys by
// default, which is exactly the forward-compat rule the protocol asks for: a
// newer Gatecaster can add fields (or whole message types) without breaking us.

struct Hello: Decodable {
    let v: Int
    let ready: Bool?
    let caps: [String]?
    struct Screen: Decodable { let x, y, w, h: Double }
    let screen: Screen?
}

struct Finger: Decodable {
    let id: Int
    let phase: String
    let sx: Double          // screen pixels, already mapped through calibration
    let sy: Double          // + the active display — usable directly, no math.
}

struct FingerFrame: Decodable {
    let fingers: [Finger]
    let dropped: Int        // always present; >0 means the server shed frames for us.
}

struct Gesture: Decodable {
    let gesture: String
    let phase: String?      // pinch/rotate/scroll carry a phase; swipe does not.
    let value: Double?      // pinch = ratio delta, rotate = degrees.
    let dx: Double?
    let dy: Double?
    let direction: String?  // swipe only.
    let fingers: Int?       // swipe only.
}

// Just enough to route a line to the right decoder by its `type` tag.
struct Envelope: Decodable { let type: String? }

// MARK: - NDJSON framing
//
// A single receive may carry several frames *and* a partial trailing line, or a
// fraction of one line split across two receives. Accumulate raw bytes and only
// hand back complete lines, keeping the remainder buffered — the one piece every
// correct NDJSON client must get right.
final class LineReader {
    private var buf = Data()
    private let newline = UInt8(ascii: "\n")

    /// Append received bytes; return every complete line that just became available.
    func push(_ chunk: Data) -> [Data] {
        buf.append(chunk)
        var lines: [Data] = []
        while let nl = buf.firstIndex(of: newline) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

// MARK: - Rendering

func renderFingers(_ f: FingerFrame) -> String {
    let dropNote = f.dropped > 0 ? "  (dropped \(f.dropped))" : ""
    if f.fingers.isEmpty { return "fingers: (none)" + dropNote }
    let parts = f.fingers.map { c -> String in
        let ph = String(c.phase.prefix(4))
        return "#\(c.id):\(ph) (\(Int(c.sx.rounded())),\(Int(c.sy.rounded())))"
    }
    return "fingers[\(f.fingers.count)]: " + parts.joined(separator: "  ") + dropNote
}

func renderGesture(_ g: Gesture) -> String {
    switch g.gesture {
    case "pinch", "rotate":
        return "gesture \(g.gesture) value=\(g.value ?? 0) phase=\(g.phase ?? "?")"
    case "scroll":
        return "gesture scroll dx=\(g.dx ?? 0) dy=\(g.dy ?? 0) phase=\(g.phase ?? "?")"
    case "swipe":
        return "gesture swipe \(g.direction ?? "?") fingers=\(g.fingers ?? 0)"
    default:
        // Forward-compat: a newer Gatecaster may emit a gesture we predate.
        return "gesture \(g.gesture)"
    }
}

// MARK: - Client

final class TouchClient {
    private let queue = DispatchQueue(label: "touchclient")
    private let reader = LineReader()
    private var gotHello = false
    private var conn: NWConnection?

    func start() { connect() }

    private func connect() {
        // NWConnection drives an async state machine on our queue; no run-loop
        // blocking and no manual fd juggling. The Unix endpoint is the socket file.
        let endpoint = NWEndpoint.unix(path: sockPath)
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.conn = conn
        gotHello = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Subscribe (replaces any prior set). Commands are valid the moment
                // we're connected; the server processes them after its hello.
                self.send(["subscribe": ["fingers", "gestures"]])
                if suppress {
                    self.send(["suppress": ["input"]])
                    FileHandle.standardError.write(Data(
                        ("kiosk mode: system input suppressed — the pointer will not " +
                         "move. Press Ctrl-C to release.\n").utf8))
                }
            case .failed, .cancelled:
                // Socket missing or refused: Gatecaster isn't up yet, or it quit.
                // A resilient client treats "not there yet" as normal — retry.
                self.retry()
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(conn)
    }

    private func retry() {
        conn?.cancel()
        FileHandle.standardError.write(Data("waiting for Gatecaster …\n".utf8))
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.connect() }
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for line in self.reader.push(data) { self.handle(line) }
            }
            if isComplete || error != nil {
                // EOF or error: connection dropped. Our suppress lease was already
                // released by the close; reconnect.
                self.retry()
                return
            }
            self.receive(conn)   // keep draining
        }
    }

    private func handle(_ line: Data) {
        let dec = JSONDecoder()
        if !gotHello {
            // The server sends exactly one `hello` first.
            gotHello = true
            if let h = try? dec.decode(Hello.self, from: line) {
                print("connected: v\(h.v) caps=\(h.caps ?? [])")
                if h.ready == true, let s = h.screen {
                    print("ready: screen \(Int(s.w))x\(Int(s.h)) @ (\(Int(s.x)),\(Int(s.y)))")
                } else {
                    // Geometry still zero/untrusted; sx/sy in finger frames are live.
                    FileHandle.standardError.write(Data(
                        "not ready (display unresolved) — sx/sy still valid; geometry untrusted\n".utf8))
                }
            }
            return
        }
        guard let env = try? dec.decode(Envelope.self, from: line) else { return }
        switch env.type {
        case "fingers":
            if let f = try? dec.decode(FingerFrame.self, from: line) {
                // Rewrite the live finger line in place (carriage return + clear).
                FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + renderFingers(f)).utf8))
            }
        case "gesture":
            if let g = try? dec.decode(Gesture.self, from: line) {
                // Clear the in-place line, then print the gesture on its own line.
                FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + renderGesture(g) + "\n").utf8))
            }
        default:
            break   // Ignore unknown message types (forward-compat).
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let conn,
              var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(UInt8(ascii: "\n"))   // one NDJSON command per line.
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Closing the socket releases the suppress lease automatically; we send an
    /// explicit clear too (harmless, makes intent obvious) and wait briefly so it
    /// flushes before the process exits.
    func shutdown() {
        if suppress { send(["suppress": false]) }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.conn?.cancel()
            print("\nbye")
            exit(0)
        }
    }
}

let client = TouchClient()

// Ctrl-C: release suppression and exit cleanly. A plain signal handler can't run
// arbitrary code safely, so just flip a dispatch source that does the work on a
// normal queue.
let sigsrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigsrc.setEventHandler { client.shutdown() }
sigsrc.resume()
signal(SIGINT, SIG_IGN)   // hand SIGINT to the dispatch source instead of default

client.start()
dispatchMain()
