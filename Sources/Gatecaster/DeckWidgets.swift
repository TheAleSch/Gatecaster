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

// MARK: - widget tile views

/// Renders one widget at spanW×spanH cells. Dispatches by kind; extension
/// widgets render generically from their manifest.
struct WidgetTile: View {
    let widget: DeckWidget
    let cell: CGFloat
    let editing: Bool
    var onDelete: () -> Void

    private var size: CGSize {
        CGSize(width: cell * CGFloat(widget.spanW) + 8 * CGFloat(widget.spanW - 1),
               height: cell * CGFloat(widget.spanH) + 8 * CGFloat(widget.spanH - 1))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if editing {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.9))
                        .background(Circle().fill(Color.black.opacity(0.4)))
                }
                .buttonStyle(.plain).padding(4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch widget.kind {
        case "clock": ClockWidget()
        case "media": MediaWidget()
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

/// Built-in: live time + date.
private struct ClockWidget: View {
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 2) {
            Text(now, format: .dateTime.hour().minute().second())
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
            Text(now, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
        .onReceive(tick) { now = $0 }
    }
}

/// Built-in: now-playing-ish media controls via media keys.
private struct MediaWidget: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Media").font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 14) {
                btn("backward.fill") { DeckRunner.postKeystroke("fn+f7") }
                btn("playpause.fill") { DeckRunner.postKeystroke("fn+f8") }
                btn("forward.fill") { DeckRunner.postKeystroke("fn+f9") }
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
