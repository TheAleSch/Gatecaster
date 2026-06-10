import SwiftUI
import AppKit
import Foundation

// MARK: - widget model

/// A widget occupies a wider slot than a button (W×H cells) and shows live
/// content. Two sources:
///  - `builtin`  — shipped with the app (clock, media).
///  - `extension` — a third-party pack installed in the Extensions folder,
///    referenced by its manifest id. Declarative + sandboxed (see below).
struct DeckWidget: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: String = "clock"          // "clock" | "media" | "ext:<extensionId>"
    var spanW = 2                        // width in grid cells
    var spanH = 2                        // height in grid cells
    var config: [String: String] = [:]  // per-instance settings (extension fields)
    // Explicit grid placement (cell coordinates). nil = auto first-fit. See the
    // matching note on DeckButton — integers so they survive a Block-Size change.
    var gridCol: Int?
    var gridRow: Int?

    // Tolerant decode (forward/backward-compat): a widget saved before `config`
    // or the span fields existed, or with a missing id, decodes to its default
    // rather than hard-failing — Swift's synthesized decoder otherwise demands
    // every non-optional key be present (defaults only feed memberwise init, not
    // Decodable), so one missing field in a saved/exported deck would, via the
    // `try?` in DeckStore.load/importLayout, silently discard the whole layout.
    // gridCol/gridRow stay Optional: absent → nil → auto first-fit.
    init() {}
    init(id: UUID = UUID(), kind: String = "clock", spanW: Int = 2, spanH: Int = 2,
         config: [String: String] = [:], gridCol: Int? = nil, gridRow: Int? = nil) {
        self.id = id; self.kind = kind; self.spanW = spanW; self.spanH = spanH
        self.config = config; self.gridCol = gridCol; self.gridRow = gridRow
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, spanW, spanH, config, gridCol, gridRow
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "clock"
        spanW = try c.decodeIfPresent(Int.self, forKey: .spanW) ?? 2
        spanH = try c.decodeIfPresent(Int.self, forKey: .spanH) ?? 2
        config = try c.decodeIfPresent([String: String].self, forKey: .config) ?? [:]
        gridCol = try c.decodeIfPresent(Int.self, forKey: .gridCol)
        gridRow = try c.decodeIfPresent(Int.self, forKey: .gridRow)
    }

    var isExtension: Bool { kind.hasPrefix("ext:") }
    var extensionId: String? { isExtension ? String(kind.dropFirst(4)) : nil }
}

// MARK: - third-party extension manifest (declarative; no arbitrary code)

/// A widget extension is a folder under
/// ~/Library/Application Support/Gatecaster/Extensions/<id>/ containing
/// manifest.json. It is DECLARATIVE: it describes a tile (title, icon, color),
/// optional live fields populated by a `refresh` command's JSON stdout, and
/// buttons that fire the SAME safe DeckAction types (app/url/keystroke/
/// shortcut/shell/volume). There is no linked/native third-party code — the
/// only execution is the actions and the refresh command the user installed,
/// which run with the user's privileges (documented; v1 marketplace reviews).
struct WidgetManifest: Codable, Identifiable {
    var id: String                       // reverse-DNS, e.g. com.spotify.nowplaying
    var name: String
    var symbol: String?                  // SF Symbol for the header
    var colorHex: String?
    var minW: Int?                       // smallest span the widget renders well at
    var minH: Int?
    var defaultW: Int?                   // span when first dropped (defaults to min)
    var defaultH: Int?
    var fields: [ManifestField]?         // labels shown; value via refreshKey
    var buttons: [ManifestButton]?       // action buttons in the tile
    var refresh: ManifestRefresh?        // optional polling command → JSON

    // Tolerant decode (forward/backward-compat). A future manifest schema that
    // adds keys must still load older manifests, and a hand-written manifest
    // missing an optional key must not nuke the whole registry reload (the `try?`
    // in WidgetRegistry.reload would otherwise drop the entire extension). `id`
    // and `name` have no natural default, so they fall back to "" — a nameless
    // manifest is harmless (sorts empty) and far better than a hard failure.
    init(id: String = "", name: String = "", symbol: String? = nil,
         colorHex: String? = nil, minW: Int? = nil, minH: Int? = nil,
         defaultW: Int? = nil, defaultH: Int? = nil,
         fields: [ManifestField]? = nil, buttons: [ManifestButton]? = nil,
         refresh: ManifestRefresh? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.colorHex = colorHex
        self.minW = minW; self.minH = minH; self.defaultW = defaultW; self.defaultH = defaultH
        self.fields = fields; self.buttons = buttons; self.refresh = refresh
    }
    enum CodingKeys: String, CodingKey {
        case id, name, symbol, colorHex, minW, minH, defaultW, defaultH
        case fields, buttons, refresh
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        minW = try c.decodeIfPresent(Int.self, forKey: .minW)
        minH = try c.decodeIfPresent(Int.self, forKey: .minH)
        defaultW = try c.decodeIfPresent(Int.self, forKey: .defaultW)
        defaultH = try c.decodeIfPresent(Int.self, forKey: .defaultH)
        fields = try c.decodeIfPresent([ManifestField].self, forKey: .fields)
        buttons = try c.decodeIfPresent([ManifestButton].self, forKey: .buttons)
        refresh = try c.decodeIfPresent(ManifestRefresh.self, forKey: .refresh)
    }

    struct ManifestField: Codable, Hashable {
        var label: String
        var refreshKey: String?          // key into refresh JSON; else static `value`
        var value: String?

        // Tolerant decode — a field with no `label` falls back to "" rather than
        // failing the parent manifest's whole decode (forward/backward-compat).
        init(label: String = "", refreshKey: String? = nil, value: String? = nil) {
            self.label = label; self.refreshKey = refreshKey; self.value = value
        }
        enum CodingKeys: String, CodingKey { case label, refreshKey, value }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            refreshKey = try c.decodeIfPresent(String.self, forKey: .refreshKey)
            value = try c.decodeIfPresent(String.self, forKey: .value)
        }
    }
    struct ManifestButton: Codable, Hashable {
        var label: String?
        var symbol: String?
        var action: DeckAction
        // Toggle button: tracks an on/off state and can show alternate
        // label/icon when on. `actionAlt` fires when turning off (if absent,
        // `action` fires both ways — e.g. a shortcut that itself toggles).
        var toggle: Bool?
        var altLabel: String?
        var altSymbol: String?
        var actionAlt: DeckAction?
        // Multi-state button: cycles through these on each tap, showing the
        // current state's label/icon and firing its action. Supersedes toggle.
        var states: [ManifestState]?

        // Tolerant decode (forward/backward-compat): a button missing `action`
        // falls back to a no-op DeckAction (default kind .none) instead of
        // failing the manifest decode — a button that does nothing is a far
        // better failure mode than a dropped extension.
        init(label: String? = nil, symbol: String? = nil, action: DeckAction = DeckAction(),
             toggle: Bool? = nil, altLabel: String? = nil, altSymbol: String? = nil,
             actionAlt: DeckAction? = nil, states: [ManifestState]? = nil) {
            self.label = label; self.symbol = symbol; self.action = action
            self.toggle = toggle; self.altLabel = altLabel; self.altSymbol = altSymbol
            self.actionAlt = actionAlt; self.states = states
        }
        enum CodingKeys: String, CodingKey {
            case label, symbol, action, toggle, altLabel, altSymbol, actionAlt, states
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            action = try c.decodeIfPresent(DeckAction.self, forKey: .action) ?? DeckAction()
            toggle = try c.decodeIfPresent(Bool.self, forKey: .toggle)
            altLabel = try c.decodeIfPresent(String.self, forKey: .altLabel)
            altSymbol = try c.decodeIfPresent(String.self, forKey: .altSymbol)
            actionAlt = try c.decodeIfPresent(DeckAction.self, forKey: .actionAlt)
            states = try c.decodeIfPresent([ManifestState].self, forKey: .states)
        }
    }

    /// One state of a multi-state button.
    struct ManifestState: Codable, Hashable {
        var label: String?
        var symbol: String?
        var action: DeckAction

        // Tolerant decode — missing `action` → no-op default (see ManifestButton).
        init(label: String? = nil, symbol: String? = nil, action: DeckAction = DeckAction()) {
            self.label = label; self.symbol = symbol; self.action = action
        }
        enum CodingKeys: String, CodingKey { case label, symbol, action }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            action = try c.decodeIfPresent(DeckAction.self, forKey: .action) ?? DeckAction()
        }
    }
    struct ManifestRefresh: Codable, Hashable {
        var command: String              // zsh; stdout must be a flat JSON object
        var everySeconds: Double         // poll interval (min clamped to 2s)

        // Tolerant decode (forward/backward-compat): missing `command` → "" (no
        // poll runs) and missing `everySeconds` → 2 (the clamp floor) instead of
        // failing the manifest decode.
        init(command: String = "", everySeconds: Double = 2) {
            self.command = command; self.everySeconds = everySeconds
        }
        enum CodingKeys: String, CodingKey { case command, everySeconds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
            everySeconds = try c.decodeIfPresent(Double.self, forKey: .everySeconds) ?? 2
        }
    }
}

/// Discovers and caches installed extension manifests.
final class WidgetRegistry: ObservableObject {
    static let shared = WidgetRegistry()
    @Published private(set) var manifests: [WidgetManifest] = []

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Gatecaster/Extensions", isDirectory: true)
    }

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var found: [WidgetManifest] = []
        if let dirs = try? fm.contentsOfDirectory(at: Self.folder,
                                                  includingPropertiesForKeys: nil) {
            for dir in dirs {
                let manifestURL = dir.appendingPathComponent("manifest.json")
                if let data = try? Data(contentsOf: manifestURL),
                   let m = try? JSONDecoder().decode(WidgetManifest.self, from: data) {
                    found.append(m)
                }
            }
        }
        manifests = found.sorted { $0.name < $1.name }
    }

    func manifest(id: String) -> WidgetManifest? { manifests.first { $0.id == id } }
}

// MARK: - live values for extension refresh commands

/// Runs an extension's refresh command on a timer and publishes the parsed
/// JSON. One instance per visible extension widget.
final class WidgetDataSource: ObservableObject {
    @Published var values: [String: String] = [:]
    private var timer: Timer?

    func start(_ refresh: WidgetManifest.ManifestRefresh) {
        stop()
        let interval = max(2, refresh.everySeconds)
        let run = { [weak self] in self?.poll(refresh.command) }
        run()
        let t = Timer(timeInterval: interval, repeats: true) { _ in run() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }

    private func poll(_ command: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe(); p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let strings = obj.mapValues { "\($0)" }
                DispatchQueue.main.async { self?.values = strings }
            }
        }
    }
}

// MARK: - widget sizing (per-kind minimum + default spans)

/// Smallest span a widget renders well at. Resizing clamps to this; extensions
/// declare their own via the manifest (minW/minH).
func widgetMinSpan(_ w: DeckWidget) -> (w: Int, h: Int) {
    switch w.kind {
    case "volume":  return (1, 2)
    case "clock":   return (2, 1)
    case "media":   return (2, 1)
    case "claude":  return (2, 2)
    case "battery": return (1, 1)
    case "cpu":     return (1, 1)
    case "ram":     return (2, 1)
    case "emoji":   return (3, 1)
    case "timer":   return (2, 2)
    default:
        if let id = w.extensionId, let m = WidgetRegistry.shared.manifest(id: id) {
            return (max(1, m.minW ?? 2), max(1, m.minH ?? 1))
        }
        return (1, 1)
    }
}

/// Span a widget gets when first dropped (defaults to its minimum).
func widgetDefaultSpan(_ kind: String) -> (w: Int, h: Int) {
    switch kind {
    case "volume":  return (1, 2)
    case "clock":   return (2, 1)
    case "media":   return (2, 1)
    case "claude":  return (2, 2)
    case "battery": return (1, 1)
    case "cpu":     return (1, 1)
    case "ram":     return (2, 2)
    case "emoji":   return (4, 3)
    case "timer":   return (2, 2)
    default:
        let id = kind.hasPrefix("ext:") ? String(kind.dropFirst(4)) : kind
        if let m = WidgetRegistry.shared.manifest(id: id) {
            return (max(1, m.defaultW ?? m.minW ?? 2), max(1, m.defaultH ?? m.minH ?? 2))
        }
        return (2, 2)
    }
}

// MARK: - drag regions (volume bars opt OUT of the deck's scroll routing)

/// Panel-local frames (top-left points, from SwiftUI `.global`) of on-screen
/// volume bars. The deck routes one-finger drags below its header to a native
/// ScrollView by default (the engine drives the scroll, since SwiftUI gestures
/// don't receive our synthetic drags on a non-key panel). The volume bar is the
/// one widget that needs a real mouse DRAG instead, so it publishes its frame
/// here and `AppDelegate.deckScrollRegion` excludes these rects — making the
/// engine send a leftDown/leftDrag the bar's gesture can track. Keyed by widget
/// id; entries are removed on disappear. Main-thread only (engine callbacks and
/// SwiftUI both touch it on main).
enum DeckDragRegions {
    static var volumeRects: [UUID: CGRect] = [:]
}

// MARK: - widget tile views

/// Renders one widget; the grid sizes it to its span, so the tile fills its
/// placed frame. In edit mode it shows a gear (per-widget settings), a trash
/// (delete), and a bottom-right resize handle that changes the span in cells.
struct WidgetTile: View {
    @Binding var widget: DeckWidget
    let editing: Bool
    var cell: CGFloat = 80          // one grid cell, in points
    var step: CGFloat = 88          // cell + spacing: pitch between cells
    var maxCols: Int = 8
    var minW: Int = 1               // smallest span (per-kind / manifest)
    var minH: Int = 1
    var onDelete: () -> Void

    @State private var showConfig = false
    // Live resize preview (cells). The model is only updated on release, so the
    // handle never moves mid-drag — that feedback loop was the "jumps all over".
    @State private var previewW: Int?
    @State private var previewH: Int?

    private func ghostSize(_ cells: Int) -> CGFloat {
        cell * CGFloat(cells) + (step - cell) * CGFloat(cells - 1)
    }

    var body: some View {
        content
            // In edit mode the tile is a drag/resize target, so its live controls
            // (volume bar, media keys, timer, emoji, extension chips) go inert —
            // a tap there must not fire an action while you're arranging the deck.
            // The gear/trash/resize overlays are added AFTER this, so they stay live.
            .allowsHitTesting(!editing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: GC.Radius.tile)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: GC.Radius.tile)
                .strokeBorder(Color.primary.opacity(GC.Op.hairline), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: GC.Radius.tile))
            .overlay(alignment: .topLeading) { if previewW != nil { resizeGhost } }
            .overlay(alignment: .topTrailing) { if editing { editControls } }
            .overlay(alignment: .bottomTrailing) { if editing { resizeHandle } }
            .popover(isPresented: $showConfig) {
                WidgetConfigEditor(widget: $widget)
                    .gcPopoverChrome()   // opaque + system appearance: don't inherit the deck's glass/theme
            }
    }

    /// Snapped target outline drawn during a resize drag (anchored top-left,
    /// can extend past the current tile to show the new span).
    private var resizeGhost: some View {
        let w = previewW ?? widget.spanW
        let h = previewH ?? widget.spanH
        return RoundedRectangle(cornerRadius: GC.Radius.tile)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: GC.Radius.tile)
                .fill(Color.accentColor.opacity(0.12)))
            .frame(width: ghostSize(w), height: ghostSize(h), alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                Text("\(w)×\(h)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white).padding(4)
            }
            .allowsHitTesting(false)
    }

    private var editControls: some View {
        HStack(spacing: 4) {
            if WidgetConfigEditor.hasSettings(kind: widget.kind) {
                iconBtn("gearshape.fill", tint: .black, label: "Widget settings") { showConfig = true }
            }
            iconBtn("trash.fill", tint: .red, label: "Delete widget") { onDelete() }
        }
        .padding(4)
    }

    private func iconBtn(_ symbol: String, tint: Color, label: String,
                         _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white).frame(width: 22, height: 22)
                .background(Circle().fill(tint == .red
                    ? Color.red.opacity(0.85) : Color.black.opacity(0.5)))
        }
        .buttonStyle(GCPressStyle())
        .accessibilityLabel(label)
    }

    /// Drag to resize in whole cells. Updates only a PREVIEW during the drag
    /// (the model — and thus the tile size and this handle — stay put, so the
    /// gesture origin is stable and snapping is crisp). Commits on release.
    /// `highPriorityGesture` so the ScrollView doesn't steal the drag.
    private var resizeHandle: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.95))
            Image(systemName: "arrow.down.right")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle().size(width: 44, height: 44))   // forgiving hit area
        .padding(3)
        .highPriorityGesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                previewW = Swift.max(minW, Swift.min(maxCols,
                            widget.spanW + Int((g.translation.width / step).rounded())))
                previewH = Swift.max(minH, Swift.min(6,
                            widget.spanH + Int((g.translation.height / step).rounded())))
            }
            .onEnded { _ in
                if let w = previewW { widget.spanW = w }
                if let h = previewH { widget.spanH = h }
                previewW = nil; previewH = nil
            })
    }

    @ViewBuilder private var content: some View {
        switch widget.kind {
        case "clock":
            ClockWidget(h24: widget.config["h24"] == "1",
                        zones: (widget.config["zones"] ?? "")
                            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty })
        case "media": MediaWidget()
        case "volume": VolumeWidget(id: widget.id)
        case "claude": ClaudeUsageWidget(config: $widget.config)
        case "battery": BatteryWidget()
        case "cpu": CPUWidget()
        case "ram": RamWidget()
        case "emoji": EmojiWidget()
        case "timer": TimerWidget(config: $widget.config)
        default:
            if let id = widget.extensionId,
               let m = WidgetRegistry.shared.manifest(id: id) {
                ExtensionWidget(manifest: m, config: $widget.config)
            } else {
                MissingWidget(id: widget.extensionId ?? widget.kind)
            }
        }
    }
}

/// Per-widget settings popover (the gear). Options vary by widget kind.
struct WidgetConfigEditor: View {
    @Binding var widget: DeckWidget

    /// Kinds that actually have options — the gear is hidden for the rest
    /// (a popover saying "No settings" reads as broken, not informative).
    static func hasSettings(kind: String) -> Bool {
        kind == "claude" || kind == "clock"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Widget Settings").font(.system(size: 14, weight: .bold))
            switch widget.kind {
            case "claude":
                Text("Show").font(.system(size: 12, weight: .medium))
                Picker("", selection: cfg("display", "both")) {
                    Text("Tokens").tag("tokens")
                    Text("Percent").tag("percent")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented).labelsHidden()
                TextField("5-hour token limit", text: cfgText("limit5h"))
                    .textFieldStyle(.roundedBorder)
                TextField("Weekly token limit", text: cfgText("limitWeek"))
                    .textFieldStyle(.roundedBorder)
                Text("Percent needs a limit. Usage is summed from local Claude Code logs on this Mac only — not Claude.ai or the official plan limit.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case "clock":
                Toggle("24-hour clock", isOn: cfgBool("h24"))
                TextField("Time zones (comma-separated)", text: cfgText("zones"))
                    .textFieldStyle(.roundedBorder)
                Text("e.g. America/Los_Angeles, Europe/Zurich, Asia/Tokyo. Leave empty for local time. Tip: use IANA names.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text("No settings for this widget.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Text("Size \(widget.spanW)×\(widget.spanH)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(14).frame(width: 280)
    }

    private func cfgText(_ k: String) -> Binding<String> {
        Binding(get: { widget.config[k] ?? "" },
                set: { widget.config[k] = $0.isEmpty ? nil : $0 })
    }
    private func cfg(_ k: String, _ d: String) -> Binding<String> {
        Binding(get: { widget.config[k] ?? d }, set: { widget.config[k] = $0 })
    }
    private func cfgBool(_ k: String) -> Binding<Bool> {
        Binding(get: { widget.config[k] == "1" }, set: { widget.config[k] = $0 ? "1" : nil })
    }
}

/// Built-in: live time + date. Uses a DateFormatter (with en_US_POSIX) so the
/// 24-hour setting is honored reliably, and supports multiple time zones.
private struct ClockWidget: View {
    var h24 = false
    var zones: [String] = []          // IANA ids; empty = local single clock
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if zones.isEmpty {
                VStack(spacing: 2) {
                    Text(timeString(nil)).font(.system(size: 30, weight: .semibold).monospacedDigit())
                    Text(dateString(nil)).font(.system(size: 12)).foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(zones, id: \.self) { z in
                        HStack {
                            Text(zoneLabel(z)).font(.system(size: 12)).foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(timeString(TimeZone(identifier: z)))
                                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(tick) { now = $0 }
    }

    private func fmt(_ tz: TimeZone?) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let tz { f.timeZone = tz }
        return f
    }
    private func timeString(_ tz: TimeZone?) -> String {
        let f = fmt(tz); f.dateFormat = h24 ? "HH:mm:ss" : "h:mm:ss a"; return f.string(from: now)
    }
    private func dateString(_ tz: TimeZone?) -> String {
        let f = fmt(tz); f.dateFormat = "EEEE, MMM d"; return f.string(from: now)
    }
    private func zoneLabel(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }
}

/// Built-in: output volume. Drag or tap anywhere on the bar to set; tap-to-set
/// works even with click-only synthetic touches. Throttled to ~10 Hz.
private struct VolumeWidget: View {
    let id: UUID
    @State private var volume = 50.0
    @State private var lastSent = Date.distantPast

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13)).foregroundColor(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.8))
                        .frame(height: max(8, h * volume / 100))
                }
                .contentShape(Rectangle())
                // Publish the bar's screen-global frame (.global) so the engine excludes it
                // from deck scroll routing and instead sends a real mouse drag —
                // without this, a touch-drag here scrolls (the bar never updates).
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { DeckDragRegions.volumeRects[id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { f in
                            DeckDragRegions.volumeRects[id] = f
                        }
                })
                // highPriorityGesture: non-activating panel gesture disambiguation
                // drops plain .gesture() — this ensures the volume bar always wins.
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard h > 0 else { return }   // avoid NaN → Int(NaN) crash
                        volume = max(0, min(100, 100 * (1 - g.location.y / h)))
                        if Date().timeIntervalSince(lastSent) > 0.1 {
                            lastSent = Date(); DeckRunner.setVolume(Int(volume))
                        }
                    }
                    .onEnded { _ in DeckRunner.setVolume(Int(volume)) })
            }
            Text("\(Int(volume))").font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(8)
        .onDisappear { DeckDragRegions.volumeRects[id] = nil }
    }
}

/// Built-in: now-playing-ish media controls via media keys.
private struct MediaWidget: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Media").font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 14) {
                btn("backward.fill") { DeckRunner.mediaKey(18) }
                btn("playpause.fill") { DeckRunner.mediaKey(16) }
                btn("forward.fill") { DeckRunner.mediaKey(17) }
            }
        }
    }
    private func btn(_ symbol: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// Third-party: declarative tile driven by a manifest + optional refresh poll.
private struct ExtensionWidget: View {
    let manifest: WidgetManifest
    @Binding var config: [String: String]       // persists toggle/multi-state across redraws
    @StateObject private var data = WidgetDataSource()

    private func isOn(_ i: Int) -> Bool { config["on.\(i)"] == "1" }
    private func setOn(_ i: Int, _ v: Bool) { config["on.\(i)"] = v ? "1" : nil }
    private func stateIndex(_ i: Int) -> Int { Int(config["st.\(i)"] ?? "") ?? 0 }
    private func setStateIndex(_ i: Int, _ v: Int) { config["st.\(i)"] = v == 0 ? nil : String(v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: manifest.symbol ?? "puzzlepiece.extension.fill")
                    .foregroundColor(Color(hex: manifest.colorHex ?? "#8E8E93"))
                Text(manifest.name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            ForEach(manifest.fields ?? [], id: \.label) { f in
                HStack {
                    Text(f.label).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Text(value(for: f)).font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            if let buttons = manifest.buttons, !buttons.isEmpty {
                // Native ScrollView; the engine drives it with scroll-wheel
                // events so a tall pack (e.g. Figma's shortcuts) scrolls.
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                              spacing: 6) {
                        ForEach(buttons.indices, id: \.self) { i in
                            chip(buttons[i], index: i)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let r = manifest.refresh { data.start(r) } }
        .onDisappear { data.stop() }
    }

    private func chip(_ b: WidgetManifest.ManifestButton, index: Int) -> some View {
        // Resolve current appearance + highlight across the three button kinds:
        // multi-state (states[]), toggle (on/off), or plain.
        let symbol: String?
        let label: String?
        let highlighted: Bool
        if let states = b.states, !states.isEmpty {
            let i = min(stateIndex(index), states.count - 1)
            symbol = states[i].symbol ?? b.symbol
            label = states[i].label ?? b.label
            highlighted = i != 0
        } else {
            let on = isOn(index)
            symbol = (on ? b.altSymbol : nil) ?? b.symbol
            label = (on ? b.altLabel : nil) ?? b.label
            highlighted = on
        }
        return Button {
            if let states = b.states, !states.isEmpty {
                let i = min(stateIndex(index), states.count - 1)
                DeckRunner.run(states[i].action)
                setStateIndex(index, (i + 1) % states.count)
            } else if b.toggle == true {
                if isOn(index) { setOn(index, false); DeckRunner.run(b.actionAlt ?? b.action) }
                else { setOn(index, true); DeckRunner.run(b.action) }
            } else {
                DeckRunner.run(b.action)
            }
        } label: {
            VStack(spacing: 3) {
                if let s = symbol { Image(systemName: s).font(.system(size: 16)) }
                if let l = label {
                    Text(l).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .foregroundColor(highlighted ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    private func value(for f: WidgetManifest.ManifestField) -> String {
        if let key = f.refreshKey, let v = data.values[key] { return v }
        return f.value ?? "—"
    }
}

/// Shown when a widget references an extension that isn't installed — never a
/// mystery "?" (the Stream Deck complaint); keeps its config, badges clearly.
private struct MissingWidget: View {
    let id: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Missing extension").font(.system(size: 11, weight: .semibold))
            Text(id).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - built-in: Claude usage

/// Reads Claude Code's local session logs (~/.claude/projects/**/*.jsonl) and
/// reconstructs usage the way ccusage does:
///  - de-duplicates entries by message id + request id (logs repeat across
///    resumed sessions / multiple files);
///  - groups entries into 5-hour SESSION BLOCKS — a block starts at the first
///    message (floored to the hour, UTC) and ends 5h later or after a >5h gap,
///    matching Claude's own window, not a naive "last 5 hours";
///  - reports the ACTIVE block's tokens (the 5-hour number), the rolling
///    7-day total (weekly), and the largest historical block (used as an
///    auto limit so % is meaningful without knowing your plan cap).
/// Purely local; no network. Off-thread on a 60s timer.
final class ClaudeUsage: ObservableObject {
    @Published var window5h = 0          // tokens in the currently-active 5h block
    @Published var week = 0              // rolling 7-day total
    @Published var maxBlock = 0          // largest block ever (auto-limit denominator)
    @Published var available = true
    private var timer: Timer?

    func start() {
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = Self.scan()
            DispatchQueue.main.async {
                self?.window5h = r.active; self?.week = r.week
                self?.maxBlock = r.maxBlock; self?.available = r.ok
            }
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? iso.date(from: s)
    }
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private static func floorHour(_ d: Date) -> Date {
        utcCal.date(from: utcCal.dateComponents([.year, .month, .day, .hour], from: d)) ?? d
    }

    static func scan() -> (active: Int, week: Int, maxBlock: Int, ok: Bool) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { return (0, 0, 0, false) }

        // 1) collect + de-dup entries (date, tokens)
        var seen = Set<String>()
        var entries: [(date: Date, tokens: Int)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = parseDate(tsStr) else { continue }
                let tok = tokens(in: obj)
                if tok == 0 { continue }
                if let key = dedupKey(obj) {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                entries.append((ts, tok))
            }
        }
        if entries.isEmpty { return (0, 0, 0, false) }
        entries.sort { $0.date < $1.date }

        // 2) 7-day rolling total
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let week = entries.filter { $0.date >= weekAgo }.reduce(0) { $0 + $1.tokens }

        // 3) 5-hour session blocks (ccusage algorithm)
        let blockSecs: TimeInterval = 5 * 3600
        var blocks: [(start: Date, tokens: Int)] = []
        var start: Date?, last: Date?, sum = 0
        for e in entries {
            if let s = start, let l = last,
               e.date.timeIntervalSince(s) < blockSecs,
               e.date.timeIntervalSince(l) < blockSecs {
                sum += e.tokens; last = e.date
            } else {
                if let s = start { blocks.append((s, sum)) }
                start = floorHour(e.date); last = e.date; sum = e.tokens
            }
        }
        if let s = start { blocks.append((s, sum)) }

        let maxBlock = blocks.map(\.tokens).max() ?? 0
        // active = the last block if it's still within its 5h window
        var active = 0
        if let lastBlock = blocks.last,
           now.timeIntervalSince(lastBlock.start) < blockSecs {
            active = lastBlock.tokens
        }
        return (active, week, maxBlock, true)
    }

    /// ccusage-style de-dup key: message id + request id when present.
    private static func dedupKey(_ obj: [String: Any]) -> String? {
        let mid = (obj["message"] as? [String: Any])?["id"] as? String
        let rid = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
        if mid == nil && rid == nil { return nil }
        return "\(mid ?? "")|\(rid ?? "")"
    }

    private static func tokens(in obj: [String: Any]) -> Int {
        if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
            return sumUsage(u)
        }
        if let u = obj["usage"] as? [String: Any] { return sumUsage(u) }
        return 0
    }
    private static func sumUsage(_ u: [String: Any]) -> Int {
        ["input_tokens", "output_tokens",
         "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
    }
}

/// Compact token formatter: 1234 → "1.2k", 1_200_000 → "1.2M".
func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

/// Built-in Claude usage tile: two rolling-window bars (5-hour, weekly). If the
/// widget config carries `limit5h` / `limitWeek` token caps, the bars show a
/// percentage of that cap; otherwise the 5-hour bar is shown relative to the
/// weekly total as a rough at-a-glance fill.
struct ClaudeUsageWidget: View {
    @Binding var config: [String: String]
    @StateObject private var usage = ClaudeUsage()

    private var limit5h: Int? { config["limit5h"].flatMap { Int($0) } }
    private var limitWeek: Int? { config["limitWeek"].flatMap { Int($0) } }
    private var display: String { config["display"] ?? "both" }  // tokens | percent | both

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(Color(hex: "#D97757"))
                Text("Claude Usage").font(.system(size: 12, weight: .semibold))
            }
            if usage.available {
                // 5h bar: explicit limit, else auto-calibrate to the largest
                // block seen so far (ccusage's "-t max" trick).
                meter(title: "5-hour", value: usage.window5h, limit: limit5h,
                      fallbackMax: max(usage.maxBlock, 1), tint: Color(hex: "#D97757"))
                meter(title: "Week", value: usage.week, limit: limitWeek,
                      fallbackMax: max(usage.week, 1), tint: Color(hex: "#3478F6"))
            } else {
                Text("No Claude logs found")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { usage.start() }
        .onDisappear { usage.stop() }
    }

    /// Readout respects the display mode: tokens, percent (needs a limit), or both.
    private func readout(_ value: Int, _ limit: Int?) -> String {
        let total = formatTokens(value)
        guard let lim = limit, lim > 0 else {
            return display == "percent" ? "— set limit" : total
        }
        let pct = Int(Swift.min(1.0, Double(value) / Double(lim)) * 100)
        switch display {
        case "tokens":  return "\(total) / \(formatTokens(lim))"
        case "percent": return "\(pct)%"
        default:        return "\(pct)%  ·  \(total)"
        }
    }

    @ViewBuilder
    private func meter(title: String, value: Int, limit: Int?,
                       fallbackMax: Int, tint: Color) -> some View {
        let cap = Double(limit ?? fallbackMax)
        let frac = cap > 0 ? Swift.min(1.0, Double(value) / cap) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(readout(value, limit))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: Swift.max(4, geo.size.width * frac))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - built-in: Battery

/// Battery level + charging state via `pmset -g batt` (no extra entitlements).
private struct BatteryWidget: View {
    @State private var percent = 0
    @State private var charging = false
    @State private var present = true
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 80 || geo.size.width < 120
            if compact {
                StatCompact(symbol: icon, tint: tint,
                            value: present ? "\(percent)%" : "—")
            } else {
                StatFull(title: "Battery", symbol: icon, tint: tint,
                         value: present ? "\(percent)%" : "No battery",
                         percent: present ? percent : nil)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }
    private var tint: Color {
        if charging { return .green }
        return percent <= 20 ? .red : .accentColor
    }
    private var icon: String {
        charging ? "battery.100.bolt"
            : percent <= 20 ? "battery.25" : "battery.100"
    }
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let out = shell("/usr/bin/pmset", ["-g", "batt"])
            var pct = 0, chg = false, has = false
            if let m = out.range(of: #"(\d+)%"#, options: .regularExpression) {
                pct = Int(out[m].dropLast()) ?? 0; has = true
            }
            let low = out.lowercased()
            chg = low.contains("charging") || low.contains("charged") || low.contains("ac power")
            if low.contains("discharging") { chg = false }
            DispatchQueue.main.async { percent = pct; charging = chg; present = has }
        }
    }
}

// MARK: - built-in: CPU load

/// System-wide CPU usage (%), sampled from host_processor_info deltas.
private struct CPUWidget: View {
    @State private var usage = 0
    @State private var prevTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 80 || geo.size.width < 120
            let tint: Color = usage > 80 ? .red : .accentColor
            if compact {
                StatCompact(symbol: "cpu", tint: tint, value: "\(usage)%")
            } else {
                StatFull(title: "CPU", symbol: "cpu", tint: tint,
                         value: "\(usage)%", percent: usage)
            }
        }
        .onAppear(perform: sample)
        .onReceive(tick) { _ in sample() }
    }

    private func sample() {
        // Compute the count from the struct size (HOST_CPU_LOAD_INFO_COUNT isn't
        // reliably imported into Swift); host_cpu_load_info_data_t is the value type.
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let u = info.cpu_ticks.0, s = info.cpu_ticks.1, i = info.cpu_ticks.2, n = info.cpu_ticks.3
        if let p = prevTicks {
            let du = Double(u &- p.user), ds = Double(s &- p.sys)
            let di = Double(i &- p.idle), dn = Double(n &- p.nice)
            let busy = du + ds + dn, total = busy + di
            if total > 0 { usage = Int((busy / total) * 100) }
        }
        prevTicks = (u, s, i, n)
    }
}

// MARK: - shared stat tile layouts

/// Compact single-cell stat: centered icon + value (e.g. "62%").
private struct StatCompact: View {
    let symbol: String
    let tint: Color
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundColor(tint)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full stat tile: header (icon + title), big value, progress bar.
private struct StatFull: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var percent: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundColor(tint)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            Text(value).font(.system(size: 26, weight: .semibold).monospacedDigit())
            if let percent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(tint)
                            .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - built-in: RAM

/// Memory usage via host_statistics64 + total from ProcessInfo; swap from sysctl.
private struct RamWidget: View {
    @State private var percent = 0
    @State private var usedGB = 0.0
    @State private var freeGB = 0.0
    @State private var swapGB = 0.0
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 80 || geo.size.width < 120
            let tint: Color = percent > 85 ? .red : (percent > 70 ? .orange : .accentColor)
            if compact {
                StatCompact(symbol: "memorychip", tint: tint, value: "\(percent)%")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip").foregroundColor(tint)
                        Text("RAM").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(percent)%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule().fill(tint)
                                .frame(width: max(4, g.size.width * CGFloat(percent) / 100))
                        }
                    }
                    .frame(height: 6)
                    row("Used", String(format: "%.1f GB", usedGB))
                    row("Free", String(format: "%.1f GB", freeGB))
                    if swapGB > 0.05 { row("Swap", String(format: "%.1f GB", swapGB)) }
                }
                .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: sample)
        .onReceive(tick) { _ in sample() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    private func sample() {
        DispatchQueue.global(qos: .utility).async {
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            var stats = vm_statistics64_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
            let kr = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            let page = Double(vm_kernel_page_size)
            var usedBytes = 0.0
            if kr == KERN_SUCCESS {
                let active = Double(stats.active_count)
                let wired = Double(stats.wire_count)
                let compressed = Double(stats.compressor_page_count)
                usedBytes = (active + wired + compressed) * page
            }
            // swap
            var swap = xsw_usage()
            var sz = MemoryLayout<xsw_usage>.size
            var swapUsed = 0.0
            if sysctlbyname("vm.swapusage", &swap, &sz, nil, 0) == 0 {
                swapUsed = Double(swap.xsu_used)
            }
            let gb = 1024.0 * 1024.0 * 1024.0
            let pct = total > 0 ? Int(usedBytes / total * 100) : 0
            DispatchQueue.main.async {
                percent = pct
                usedGB = usedBytes / gb
                freeGB = max(0, (total - usedBytes) / gb)
                swapGB = swapUsed / gb
            }
        }
    }
}

/// Run a process and return its stdout as a string (utility queue caller).
private func shell(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - built-in: Countdown timer

/// A countdown timer styled after the iOS dial. The iOS clock sets the time by
/// dragging a knob around the ring — but on the deck a one-finger drag is routed
/// to engine scrolling, so dragging a knob would fight the scroll engine. Instead
/// this uses **tap controls**: preset chips, ±1:00 / ±0:10 steppers, and a
/// start/pause + reset pair. The ring is a live progress indicator, not a drag
/// target. The configured duration persists in the widget config; the running
/// state is transient (resets when the deck reloads), which matches how a kitchen
/// timer behaves and keeps state simple.
private struct TimerWidget: View {
    @Binding var config: [String: String]

    // Total configured duration (seconds) and remaining time while running.
    @State private var total: Int = 300
    @State private var remaining: Int = 300
    @State private var running = false
    @State private var endDate: Date?       // wall-clock target, so it stays
                                            // accurate even if ticks are missed
    @State private var firedAt: Date?       // de-dupes the completion chime

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let presets: [(label: String, secs: Int)] =
        [("1m", 60), ("3m", 180), ("5m", 300), ("10m", 600), ("25m", 1500)]

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 150 || geo.size.width < 150
            VStack(spacing: compact ? 6 : 10) {
                dial(compact: compact)
                if !compact { presetRow }
                controlRow(compact: compact)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(compact ? 6 : 10)
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in step() }
    }

    // MARK: ring + readout

    private func dial(compact: Bool) -> some View {
        let frac = total > 0 ? Double(remaining) / Double(total) : 0
        let ring: CGFloat = compact ? 64 : 104
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.12),
                            style: StrokeStyle(lineWidth: compact ? 6 : 9))
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, frac))))
                .stroke(ringTint,
                        style: StrokeStyle(lineWidth: compact ? 6 : 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: remaining)
            Text(clock(remaining))
                .font(.system(size: compact ? 18 : 30, weight: .semibold).monospacedDigit())
                .foregroundColor(remaining == 0 ? .red : .primary)
        }
        .frame(width: ring, height: ring)
        .frame(maxWidth: .infinity)
    }

    private var ringTint: Color {
        if remaining == 0 { return .red }
        return remaining <= 10 && running ? .orange : .accentColor
    }

    // MARK: controls

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.secs) { p in
                Button { setTotal(p.secs) } label: {
                    Text(p.label)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(total == p.secs
                            ? Color.accentColor.opacity(0.25)
                            : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            if !running && remaining == total {
                stepBtn("minus", compact) { adjust(-60) }
                stepBtn("plus", compact) { adjust(+60) }
            }
            Button(action: toggle) {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 14 : 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                    .background(Circle().fill(running ? Color.orange : Color.green))
            }
            .buttonStyle(.plain)
            .disabled(remaining == 0)
            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: compact ? 13 : 16, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
    }

    private func stepBtn(_ symbol: String, _ compact: Bool,
                         _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                .background(Circle().fill(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    // MARK: logic

    private func clock(_ s: Int) -> String {
        let m = s / 60, sec = s % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func load() {
        if let t = Int(config["seconds"] ?? ""), t > 0 { total = t }
        remaining = total
    }

    private func setTotal(_ s: Int) {
        total = s; remaining = s; running = false; endDate = nil; firedAt = nil
        config["seconds"] = String(s)
    }

    private func adjust(_ delta: Int) {
        let s = max(10, min(24 * 3600, total + delta))
        setTotal(s)
    }

    private func toggle() {
        if running {
            running = false; endDate = nil
            remaining = max(0, remaining)        // freeze where we are
        } else {
            guard remaining > 0 else { return }
            running = true
            endDate = Date().addingTimeInterval(Double(remaining))
        }
    }

    private func reset() {
        running = false; endDate = nil; firedAt = nil; remaining = total
    }

    private func step() {
        guard running, let end = endDate else { return }
        let left = Int(ceil(end.timeIntervalSinceNow))
        if left <= 0 {
            remaining = 0; running = false; endDate = nil
            if firedAt == nil { firedAt = Date(); chime() }
        } else {
            remaining = left
        }
    }

    /// Completion alert: the system "complete" sound + a screen flash via the
    /// shared media-free path (just NSSound here to avoid stealing focus).
    private func chime() {
        NSSound(named: "Glass")?.play()
    }
}

// MARK: - built-in: Emoji picker

/// A scrollable emoji grid (macOS-style). Tapping types the emoji into the
/// focused app via a synthesized Unicode keystroke. Recently-used row on top.
private struct EmojiWidget: View {
    @State private var recent: [String] = []
    @State private var category = 0

    private static let categories: [(name: String, symbol: String, emoji: [String])] = [
        ("Smileys", "face.smiling",
         "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤗 🤭 🤫 🤔 🤐 😐 😑 😶 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐".split(separator: " ").map(String.init)),
        ("Gestures", "hand.raised",
         "👍 👎 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👋 🤚 🖐️ ✋ 🖖 👏 🙌 🤝 🙏 💪 🫶 ❤️ 🔥 ⭐️ ✨ 🎉 ✅ ❌ ⚠️ 💯".split(separator: " ").map(String.init)),
        ("Objects", "lightbulb",
         "💻 ⌨️ 🖥️ 🖱️ 📱 ⏰ 📅 📌 📎 ✏️ 📝 📚 💡 🔋 🔌 🎧 🎵 📷 🎥 🔍 🔒 🔑 🛠️ ⚙️ 🚀 ☕️ 🍕 🍔 🎮 🏆".split(separator: " ").map(String.init)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Segmented control (icons).
            HStack(spacing: 0) {
                ForEach(Self.categories.indices, id: \.self) { i in
                    let sel = i == category
                    Image(systemName: Self.categories[i].symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(sel ? Color.accentColor : Color.clear))
                        .foregroundColor(sel ? .white : .secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { category = i }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
            .padding(.horizontal, 8).padding(.top, 6)

            // Native ScrollView — the engine drives it with synthesized
            // scroll-wheel events (see Engine.deckScrollAt). Indicators hidden
            // for a clean, iOS-like touch look.
            ScrollView { grid }.id(category)
                .scrollIndicators(.hidden)
        }
    }

    private var grid: some View {
        let cols = [GridItem(.adaptive(minimum: 46), spacing: 6)]
        return VStack(alignment: .leading, spacing: 6) {
            if !recent.isEmpty {
                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(recent, id: \.self) { e in cell(e) }
                }
                Divider()
            }
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(Self.categories[category].emoji, id: \.self) { e in cell(e) }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func cell(_ e: String) -> some View {
        Text(e).font(.system(size: 30))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                DeckRunner.typeText(e)
                recent.removeAll { $0 == e }
                recent.insert(e, at: 0)
                if recent.count > 12 { recent.removeLast() }
            }
    }
}

