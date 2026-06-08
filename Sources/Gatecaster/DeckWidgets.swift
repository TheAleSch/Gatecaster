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

    struct ManifestField: Codable, Hashable {
        var label: String
        var refreshKey: String?          // key into refresh JSON; else static `value`
        var value: String?
    }
    struct ManifestButton: Codable, Hashable {
        var label: String?
        var symbol: String?
        var action: DeckAction
    }
    struct ManifestRefresh: Codable, Hashable {
        var command: String              // zsh; stdout must be a flat JSON object
        var everySeconds: Double         // poll interval (min clamped to 2s)
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
    case "battery": return (2, 1)
    case "cpu":     return (2, 1)
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
    case "battery": return (2, 1)
    case "cpu":     return (2, 1)
    default:
        let id = kind.hasPrefix("ext:") ? String(kind.dropFirst(4)) : kind
        if let m = WidgetRegistry.shared.manifest(id: id) {
            return (max(1, m.defaultW ?? m.minW ?? 2), max(1, m.defaultH ?? m.minH ?? 2))
        }
        return (2, 2)
    }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topLeading) { if previewW != nil { resizeGhost } }
            .overlay(alignment: .topTrailing) { if editing { editControls } }
            .overlay(alignment: .bottomTrailing) { if editing { resizeHandle } }
            .popover(isPresented: $showConfig) { WidgetConfigEditor(widget: $widget) }
    }

    /// Snapped target outline drawn during a resize drag (anchored top-left,
    /// can extend past the current tile to show the new span).
    private var resizeGhost: some View {
        let w = previewW ?? widget.spanW
        let h = previewH ?? widget.spanH
        return RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
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
            iconBtn("gearshape.fill", tint: .black) { showConfig = true }
            iconBtn("trash.fill", tint: .red) { onDelete() }
        }
        .padding(4)
    }

    private func iconBtn(_ symbol: String, tint: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white).frame(width: 22, height: 22)
                .background(Circle().fill(tint == .red
                    ? Color.red.opacity(0.85) : Color.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
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
        case "clock": ClockWidget(h24: widget.config["h24"] == "1")
        case "media": MediaWidget()
        case "volume": VolumeWidget()
        case "claude": ClaudeUsageWidget(config: $widget.config)
        case "battery": BatteryWidget()
        case "cpu": CPUWidget()
        default:
            if let id = widget.extensionId,
               let m = WidgetRegistry.shared.manifest(id: id) {
                ExtensionWidget(manifest: m)
            } else {
                MissingWidget(id: widget.extensionId ?? widget.kind)
            }
        }
    }
}

/// Per-widget settings popover (the gear). Options vary by widget kind.
struct WidgetConfigEditor: View {
    @Binding var widget: DeckWidget

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

/// Built-in: live time + date.
private struct ClockWidget: View {
    var h24 = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 2) {
            Text(now, format: h24
                 ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
                 : .dateTime.hour().minute().second())
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
            Text(now, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
        .onReceive(tick) { now = $0 }
    }
}

/// Built-in: output volume. Drag or tap anywhere on the bar to set; tap-to-set
/// works even with click-only synthetic touches. Throttled to ~10 Hz.
private struct VolumeWidget: View {
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
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
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
    @StateObject private var data = WidgetDataSource()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: manifest.symbol ?? "puzzlepiece.extension.fill")
                    .foregroundColor(Color(hex: manifest.colorHex ?? "#8E8E93"))
                Text(manifest.name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
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
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(buttons.indices, id: \.self) { i in
                        let b = buttons[i]
                        Button { DeckRunner.run(b.action) } label: {
                            HStack(spacing: 3) {
                                if let s = b.symbol { Image(systemName: s) }
                                if let l = b.label { Text(l).font(.system(size: 10)) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let r = manifest.refresh { data.start(r) } }
        .onDisappear { data.stop() }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(tint)
                Text("Battery").font(.system(size: 12, weight: .semibold))
            }
            if present {
                Text("\(percent)%")
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(tint)
                            .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
                    }
                }
                .frame(height: 6)
            } else {
                Text("No battery").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundColor(.accentColor)
                Text("CPU").font(.system(size: 12, weight: .semibold))
            }
            Text("\(usage)%")
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(usage > 80 ? Color.red : Color.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(usage) / 100))
                }
            }
            .frame(height: 6)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
