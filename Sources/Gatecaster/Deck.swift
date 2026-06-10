import AppKit
import Combine
import Foundation

// MARK: - model

/// What a deck button does when tapped.
enum DeckActionKind: String, Codable, CaseIterable, Identifiable {
    case none       // placeholder / spacer
    case app        // open an application (name or full path)
    case url        // open a URL in the default browser
    case keystroke  // post a keyboard shortcut, e.g. "cmd+shift+4"
    case shortcut   // run an Apple Shortcut by name
    case shell      // run a shell command (zsh)
    case volume     // set output volume to a fixed percent
    case media      // media key: play/pause, next, previous
    case page       // switch the deck to another page (by name or number)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .app: return "Open App"
        case .url: return "Open URL"
        case .keystroke: return "Keystroke"
        case .shortcut: return "Apple Shortcut"
        case .shell: return "Shell Command"
        case .volume: return "Set Volume"
        case .media: return "Media Key"
        case .page: return "Switch Page"
        }
    }
    var hint: String {
        switch self {
        case .none: return "Does nothing — a spacer."
        case .app: return "App name (e.g. Safari) or a full path to a .app."
        case .url: return "Any URL, e.g. https://github.com or vscode://…"
        case .keystroke: return "Modifiers + key, e.g. cmd+shift+4, ctrl+left, f11"
        case .shortcut: return "Exact name of a Shortcut from the Shortcuts app."
        case .shell: return "Runs in zsh, e.g. open ~/Downloads"
        case .volume: return "0–100"
        case .media: return "playpause, next, or previous"
        case .page: return "Page name or 1-based number to switch to."
        }
    }
}

struct DeckAction: Codable, Hashable {
    var kind: DeckActionKind = .none
    var value: String = ""
}

struct DeckButton: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = "Button"
    var symbol = "square.grid.2x2"   // SF Symbol name
    var colorHex = ""                // empty = neutral keycap (matches keyboard)
    var action = DeckAction()
    // Explicit grid placement (cell coordinates). nil = auto first-fit by the
    // packer. Set when the user drags a tile to a cell. Integers (not pixels) so
    // positions survive a Block-Size change — the cell pitch can grow/shrink and
    // the item still lands on the same logical cell.
    var gridCol: Int?
    var gridRow: Int?
}

struct DeckPage: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Page"
    var buttons: [DeckButton] = []
    var widgets: [DeckWidget] = []      // wider live tiles (clock/media/extensions)
    var order: [UUID] = []              // unified pack + drag order across both

    /// Pack/drag order across widgets and buttons. Falls back to
    /// widgets-then-buttons for layouts saved before `order` existed, and keeps
    /// itself in sync as items are added/removed.
    var resolvedOrder: [UUID] {
        let all = widgets.map(\.id) + buttons.map(\.id)
        guard !order.isEmpty else { return all }
        let live = Set(all)
        var result = order.filter { live.contains($0) }
        let have = Set(result)
        for id in all where !have.contains(id) { result.append(id) }   // new items → end
        return result
    }
}

struct DeckLayout: Codable {
    var columns = 4
    var showVolumeSlider = true
    // When true (default), tiles always auto-pack top-left ("tidy") and a drag
    // REORDERS an item within the pack. When false, a drag places an item at an
    // absolute cell (gridCol/gridRow), kept until moved again.
    var autoArrange = true
    var pages: [DeckPage] = []
}

// MARK: - store (persistence + import/export)

/// Owns the deck layout. Persists to ~/gatecaster-deck.json (debounced,
/// atomic). Layouts are deliberately one portable JSON file: export/import
/// moves a whole deck between machines with no cloud and no account.
final class DeckStore: ObservableObject {
    static let shared = DeckStore()

    @Published var layout = DeckLayout()
    @Published var currentPage = 0
    @Published var editing = false

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("gatecaster-deck.json")

    private var bag: AnyCancellable?

    private init() {
        load()
        if layout.pages.isEmpty { layout = Self.starter }
        bag = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let l = try? JSONDecoder().decode(DeckLayout.self, from: data) else { return }
        layout = l
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(layout) {
            try? data.write(to: Self.url, options: [.atomic])
        }
    }

    func export(to url: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(layout) { try? data.write(to: url, options: [.atomic]) }
    }

    @discardableResult
    func importLayout(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let l = try? JSONDecoder().decode(DeckLayout.self, from: data),
              !l.pages.isEmpty else { return false }
        layout = l
        currentPage = 0
        return true
    }

    // Starter deck so the first open isn't an empty void.
    private static let starter = DeckLayout(
        columns: 4, showVolumeSlider: false,
        pages: [DeckPage(name: "Main", buttons: [
            DeckButton(title: "Safari", symbol: "safari",
                       action: DeckAction(kind: .app, value: "Safari")),
            DeckButton(title: "Mail", symbol: "envelope.fill",
                       action: DeckAction(kind: .app, value: "Mail")),
            DeckButton(title: "Screenshot", symbol: "camera.viewfinder",
                       action: DeckAction(kind: .keystroke, value: "cmd+shift+4")),
            DeckButton(title: "Mission\nControl", symbol: "rectangle.3.group",
                       action: DeckAction(kind: .keystroke, value: "ctrl+up")),
            DeckButton(title: "Lock", symbol: "lock.fill",
                       action: DeckAction(kind: .keystroke, value: "cmd+ctrl+q")),
            DeckButton(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
                       action: DeckAction(kind: .url, value: "https://github.com")),
            DeckButton(title: "Downloads", symbol: "folder.fill",
                       action: DeckAction(kind: .shell, value: "open ~/Downloads")),
        ], widgets: [
            DeckWidget(kind: "clock", spanW: 2, spanH: 1),
            DeckWidget(kind: "volume", spanW: 1, spanH: 2),
        ])])
}

// MARK: - action runner

enum DeckRunner {
    /// Run an action. Failures are non-fatal: log and move on — a deck button
    /// must never wedge the app.
    static func run(_ a: DeckAction) {
        switch a.kind {
        case .none:
            break
        case .app:
            openApp(a.value)
        case .url:
            if let u = URL(string: a.value) { NSWorkspace.shared.open(u) }
        case .keystroke:
            postKeystroke(a.value)
        case .shortcut:
            runProcess("/usr/bin/shortcuts", ["run", a.value])
        case .shell:
            runProcess("/bin/zsh", ["-lc", a.value])
        case .volume:
            let v = max(0, min(100, Int(a.value) ?? 50))
            runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(v)"])
        case .media:
            switch a.value.lowercased() {
            case "next", "forward":      mediaKey(17)
            case "previous", "prev", "back", "backward": mediaKey(18)
            default:                     mediaKey(16)   // play/pause
            }
        case .page:
            switchPage(a.value)
        }
    }

    /// Switch the deck to another page by 1-based number or by name.
    static func switchPage(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            let pages = DeckStore.shared.layout.pages
            guard !pages.isEmpty else { return }
            if let n = Int(v), n >= 1, n <= pages.count {
                DeckStore.shared.currentPage = n - 1
            } else if let i = pages.firstIndex(where: {
                $0.name.caseInsensitiveCompare(v) == .orderedSame
            }) {
                DeckStore.shared.currentPage = i
            }
        }
    }

    /// Media keys are NX system-defined events (subtype 8), NOT F-keys — that's
    /// why sending "fn+f8" did nothing. Codes: 16 play/pause, 17 next, 18 prev.
    static func mediaKey(_ code: Int32) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (Int(code) << 16) | (down ? 0xA00 : 0xB00)
            if let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true); post(false)
    }

    static func setVolume(_ percent: Int) {
        let v = max(0, min(100, percent))
        runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(v)"])
    }

    private static func openApp(_ value: String) {
        let fm = FileManager.default
        var path = value
        if !value.hasSuffix(".app") && !value.hasPrefix("/") {
            for dir in ["/Applications", "/System/Applications", "/Applications/Utilities"] {
                let candidate = "\(dir)/\(value).app"
                if fm.fileExists(atPath: candidate) { path = candidate; break }
            }
        }
        let url = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url,
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            log("app not found: \(value)")
        }
    }

    private static func runProcess(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("process failed: \(exe) \(error)") }
    }

    // MARK: keystroke parsing ("cmd+shift+4", "ctrl+up", "f11", "space")

    private static let keycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "backslash": 42, "slash": 44, "comma": 43, "period": 47,
        "quote": 39, "semicolon": 41, "minus": 27, "equal": 24,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "backspace": 51, "esc": 53, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    /// Insert arbitrary text (e.g. an emoji) into the focused app via a
    /// synthesized Unicode keystroke — no clipboard, no key mapping needed.
    static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let chars = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Reverse map for shortcut capture: keyCode → token our parser accepts.
    static func keyName(for code: CGKeyCode) -> String? { keyNames[code] }
    private static let keyNames: [CGKeyCode: String] = {
        var m: [CGKeyCode: String] = [:]
        for (name, code) in keycodes where m[code] == nil { m[code] = name }
        // canonical names for codes that have multiple aliases
        m[36] = "return"; m[53] = "esc"; m[51] = "delete"
        m[48] = "tab"; m[49] = "space"; m[42] = "backslash"
        return m
    }()

    static func postKeystroke(_ spec: String) {
        let parts = spec.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyName = parts.last, let code = keycodes[keyName] else {
            log("bad keystroke: \(spec)"); return
        }
        var flags = CGEventFlags()
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: log("unknown modifier: \(mod)")
            }
        }
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            down.flags = flags; down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            up.flags = flags; up.post(tap: .cghidEventTap)
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[deck] \(msg)\n".utf8))
    }
}
