import SwiftUI
import AppKit

// MARK: - deck themes

/// A deck visual theme. `scheme` flips SwiftUI's system colors (.primary /
/// .secondary / controlColor) so built-in widgets and neutral keycaps adapt
/// automatically; `background` paints the panel. Transparency from settings
/// modulates solid backgrounds.
struct DeckTheme: Identifiable {
    enum Background {
        case blur                       // live glass
        case solid(hex: String)         // flat fill (× transparency)
        case gradient([String])         // top→bottom hex stops, over blur
    }
    let id: String
    let name: String
    let scheme: ColorScheme
    let background: Background
    let forcesOpaque: Bool              // ignore the transparency slider (e.g. pure black)

    static let all: [DeckTheme] = [
        DeckTheme(id: "midnight", name: "Midnight", scheme: .dark,
                  background: .solid(hex: "#0B0E1A"), forcesOpaque: false),
        DeckTheme(id: "darkness", name: "Darkness", scheme: .dark,
                  background: .solid(hex: "#000000"), forcesOpaque: true),
        DeckTheme(id: "graphite", name: "Graphite", scheme: .dark,
                  background: .solid(hex: "#1C1C1E"), forcesOpaque: false),
        DeckTheme(id: "glass", name: "Glass", scheme: .dark,
                  background: .blur, forcesOpaque: false),
        DeckTheme(id: "aurora", name: "Aurora", scheme: .dark,
                  background: .gradient(["#241B4D", "#0B132B"]), forcesOpaque: false),
        DeckTheme(id: "daylight", name: "Daylight", scheme: .light,
                  background: .solid(hex: "#F2F2F7"), forcesOpaque: false),
    ]

    static func theme(_ id: String) -> DeckTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - deck settings sheet

/// Themes, transparency, and the installed-extension manager.
struct InstalledExt: Identifiable {
    let id: String
    let url: URL
    let name: String
}

struct DeckSettingsView: View {
    @ObservedObject var settings: AppSettings
    var onDone: () -> Void
    @State private var installed: [InstalledExt] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Deck Settings").font(.system(size: 16, weight: .bold))
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    themeSection
                    transparencySection
                    extensionsSection
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 520)
        .onAppear(perform: reloadInstalled)
    }

    // MARK: theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THEME").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(DeckTheme.all) { t in
                    themeSwatch(t)
                }
            }
        }
    }

    private func themeSwatch(_ t: DeckTheme) -> some View {
        let selected = settings.deckTheme == t.id
        return Button { settings.deckTheme = t.id } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(swatchPreview(t))
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2.5 : 1))
                    .overlay(alignment: .bottomLeading) {
                        // mini tile previews
                        HStack(spacing: 3) {
                            ForEach(0..<3) { _ in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(t.scheme == .light ? Color.black.opacity(0.12)
                                                             : Color.white.opacity(0.16))
                                    .frame(width: 14, height: 14)
                            }
                        }.padding(6)
                    }
                Text(t.name).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    private func swatchPreview(_ t: DeckTheme) -> AnyShapeStyle {
        switch t.background {
        case .blur: return AnyShapeStyle(Color.gray.opacity(0.35))
        case .solid(let hex): return AnyShapeStyle(Color(hex: hex))
        case .gradient(let stops):
            return AnyShapeStyle(LinearGradient(colors: stops.map { Color(hex: $0) },
                                                startPoint: .top, endPoint: .bottom))
        }
    }

    // MARK: transparency

    private var transparencySection: some View {
        let theme = DeckTheme.theme(settings.deckTheme)
        return VStack(alignment: .leading, spacing: 6) {
            Text("TRANSPARENCY").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            if theme.forcesOpaque {
                Text("\(theme.name) is fully opaque by design.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                HStack {
                    Image(systemName: "circle.dotted")
                    Slider(value: $settings.deckOpacity, in: 0.3...1.0)
                    Image(systemName: "circle.fill")
                    Text("\(Int(settings.deckOpacity * 100))%")
                        .font(.system(size: 12).monospacedDigit()).frame(width: 38)
                }
            }
        }
    }

    // MARK: extensions manager

    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EXTENSIONS").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                Button { NSWorkspace.shared.open(WidgetRegistry.folder) } label: {
                    Image(systemName: "plus")
                }
                Button(action: reloadInstalled) { Image(systemName: "arrow.clockwise") }
            }
            if installed.isEmpty {
                Text("No extensions installed. Tap ＋ to open the folder, drop a pack in, then ↻.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(installed) { ext in
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ext.name).font(.system(size: 13))
                                Text(ext.id).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { remove(ext.url) } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
            }
        }
    }

    private func reloadInstalled() {
        WidgetRegistry.shared.reload()
        let fm = FileManager.default
        var out: [InstalledExt] = []
        if let dirs = try? fm.contentsOfDirectory(at: WidgetRegistry.folder,
                                                  includingPropertiesForKeys: nil) {
            for dir in dirs where dir.hasDirectoryPath {
                let mURL = dir.appendingPathComponent("manifest.json")
                if let data = try? Data(contentsOf: mURL),
                   let m = try? JSONDecoder().decode(WidgetManifest.self, from: data) {
                    out.append(InstalledExt(id: m.id, url: dir, name: m.name))
                }
            }
        }
        installed = out.sorted { $0.name < $1.name }
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reloadInstalled()
    }
}
