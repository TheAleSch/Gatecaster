import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}

// MARK: - deck view

/// Stream Deck-style control surface that lives ON the touchscreen.
/// Direct-manipulation editing (the #1 complaint about competitors):
/// toggle edit → tap a button to configure it, drag to reorder, no nesting.
struct DeckView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var settings: AppSettings
    var onHide: () -> Void

    @State private var draggingID: UUID?
    @State private var volume = 50.0
    @State private var lastVolumeSent = Date.distantPast

    private var pageIndex: Int { min(store.currentPage, store.layout.pages.count - 1) }

    var body: some View {
        VStack(spacing: 6) {
            header
            pageBar
            if !store.layout.pages[pageIndex].widgets.isEmpty || store.editing {
                widgetRail
            }
            HStack(alignment: .top, spacing: 10) {
                grid
                if store.layout.showVolumeSlider { volumeSlider }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .padding(.top, 4)
        .gcActiveBlur(cornerRadius: 16, blur: settings.panelBlur, opacity: settings.keyboardOpacity)
    }

    // MARK: widget rail (live tiles: clock / media / installed extensions)

    private var widgetRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.layout.pages[pageIndex].widgets) { w in
                    WidgetTile(widget: w, cell: 64,
                               editing: store.editing,
                               onDelete: { removeWidget(w) })
                }
                if store.editing { addWidgetButton }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 64 * 2 + 8)
        }
    }

    private var addWidgetButton: some View {
        Menu {
            Button("Clock") { addWidget(kind: "clock", w: 3, h: 2) }
            Button("Media controls") { addWidget(kind: "media", w: 3, h: 2) }
            let exts = WidgetRegistry.shared.manifests
            if !exts.isEmpty {
                Divider()
                ForEach(exts) { m in
                    Button(m.name) { addWidget(kind: "ext:\(m.id)", w: 2, h: 2) }
                }
            }
            Divider()
            Button("Open Extensions Folder…") {
                NSWorkspace.shared.open(WidgetRegistry.folder)
            }
            Button("Reload Extensions") { WidgetRegistry.shared.reload() }
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: [6]))
                .overlay(VStack(spacing: 2) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Widget").font(.system(size: 10))
                }.foregroundColor(.secondary))
                .frame(width: 64 * 2, height: 64 * 2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private func addWidget(kind: String, w: Int, h: Int) {
        store.layout.pages[pageIndex].widgets.append(
            DeckWidget(kind: kind, spanW: w, spanH: h))
    }
    private func removeWidget(_ w: DeckWidget) {
        store.layout.pages[pageIndex].widgets.removeAll { $0.id == w.id }
    }

    // MARK: chrome (matches keyboard/trackpad panels; top bar = engine drag zone)

    private var header: some View {
        HStack(spacing: 10) {
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5)
            Text("Deck").font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                store.editing.toggle()
            } label: {
                Image(systemName: store.editing ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.system(size: 24))
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(store.editing ? .accentColor : .secondary)
            settingsMenu
            ResizeBean()
            Button(action: onHide) {
                Image(systemName: "chevron.down.circle.fill").font(.system(size: 26))
                    .frame(width: 40, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private var settingsMenu: some View {
        Menu {
            Button("Import Layout…") { importLayout() }
            Button("Export Layout…") { exportLayout() }
            Divider()
            Button("Add Page") {
                store.layout.pages.append(DeckPage(name: "Page \(store.layout.pages.count + 1)"))
                store.currentPage = store.layout.pages.count - 1
            }
            Button("Delete Current Page") {
                guard store.layout.pages.count > 1 else { return }
                store.layout.pages.remove(at: pageIndex)
                store.currentPage = max(0, store.currentPage - 1)
            }
            Divider()
            Button("More Columns") { store.layout.columns = min(8, store.layout.columns + 1) }
            Button("Fewer Columns") { store.layout.columns = max(2, store.layout.columns - 1) }
            Divider()
            Button(store.layout.showVolumeSlider ? "Hide Volume Slider" : "Show Volume Slider") {
                store.layout.showVolumeSlider.toggle()
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 24))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .foregroundColor(.secondary)
    }

    private var pageBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.layout.pages.indices, id: \.self) { i in
                    PageChip(name: store.layout.pages[i].name,
                             selected: i == pageIndex,
                             editing: store.editing,
                             rename: { store.layout.pages[i].name = $0 })
                        .onTapGesture { store.currentPage = i }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
    }

    // MARK: grid

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8),
                         count: max(2, store.layout.columns))
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(store.layout.pages[pageIndex].buttons) { btn in
                    DeckButtonView(button: binding(for: btn),
                                   editing: store.editing,
                                   onDelete: { delete(btn) })
                        .onDrag {
                            draggingID = btn.id
                            return NSItemProvider(object: btn.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text],
                                delegate: DeckReorderDelegate(
                                    item: btn.id,
                                    buttons: buttonsBinding,
                                    draggingID: $draggingID))
                }
                if store.editing {
                    Button {
                        store.layout.pages[pageIndex].buttons.append(DeckButton())
                    } label: {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.4),
                                          style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .overlay(Image(systemName: "plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.secondary))
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var buttonsBinding: Binding<[DeckButton]> {
        Binding(get: { store.layout.pages[pageIndex].buttons },
                set: { store.layout.pages[pageIndex].buttons = $0 })
    }

    private func binding(for btn: DeckButton) -> Binding<DeckButton> {
        Binding(
            get: {
                store.layout.pages[pageIndex].buttons.first(where: { $0.id == btn.id }) ?? btn
            },
            set: { newValue in
                if let i = store.layout.pages[pageIndex].buttons.firstIndex(where: { $0.id == btn.id }) {
                    store.layout.pages[pageIndex].buttons[i] = newValue
                }
            })
    }

    private func delete(_ btn: DeckButton) {
        store.layout.pages[pageIndex].buttons.removeAll { $0.id == btn.id }
    }

    // MARK: volume slider (first non-button control; knobs come later)

    private var volumeSlider: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13)).foregroundColor(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(height: max(8, h * volume / 100))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        volume = max(0, min(100, 100 * (1 - g.location.y / h)))
                        // osascript per event is heavy — throttle to ~10 Hz
                        if Date().timeIntervalSince(lastVolumeSent) > 0.1 {
                            lastVolumeSent = Date()
                            DeckRunner.setVolume(Int(volume))
                        }
                    }
                    .onEnded { _ in DeckRunner.setVolume(Int(volume)) })
            }
            Text("\(Int(volume))").font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .frame(width: 44)
    }

    // MARK: import / export

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MyDeck.gatedeck"
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { store.export(to: url) }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            if !store.importLayout(from: url) {
                NSSound.beep()
            }
        }
    }
}

// MARK: - page chip

private struct PageChip: View {
    let name: String
    let selected: Bool
    let editing: Bool
    var rename: (String) -> Void
    @State private var showRename = false
    @State private var draft = ""

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(selected
                ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
            .foregroundColor(selected ? .white : .primary)
            .onLongPressGesture {
                guard editing else { return }
                draft = name; showRename = true
            }
            .popover(isPresented: $showRename) {
                HStack {
                    TextField("Page name", text: $draft)
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                    Button("Save") { rename(draft); showRename = false }
                }
                .padding(10)
            }
    }
}

// MARK: - drag-to-reorder

private struct DeckReorderDelegate: DropDelegate {
    let item: UUID
    @Binding var buttons: [DeckButton]
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != item,
              let from = buttons.firstIndex(where: { $0.id == dragging }),
              let to = buttons.firstIndex(where: { $0.id == item }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            buttons.move(fromOffsets: IndexSet(integer: from),
                         toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { draggingID = nil; return true }
}

// MARK: - single button

private struct DeckButtonView: View {
    @Binding var button: DeckButton
    let editing: Bool
    var onDelete: () -> Void
    @State private var showEditor = false
    @State private var pressed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: button.colorHex).opacity(pressed ? 0.55 : 0.85))
            VStack(spacing: 4) {
                Image(systemName: button.symbol)
                    .font(.system(size: 22, weight: .semibold))
                Text(button.title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundColor(.white)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if editing {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.9))
                        .background(Circle().fill(Color.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if editing { showEditor = true } else { fire() }
        }
        .popover(isPresented: $showEditor, arrowEdge: .bottom) {
            DeckButtonEditor(button: $button, onDelete: {
                showEditor = false
                onDelete()
            })
        }
    }

    private func fire() {
        pressed = true
        DeckRunner.run(button.action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pressed = false }
    }
}

// MARK: - button editor

private struct DeckButtonEditor: View {
    @Binding var button: DeckButton
    var onDelete: () -> Void

    private static let symbols = [
        "square.grid.2x2", "safari", "envelope.fill", "message.fill", "camera.viewfinder",
        "folder.fill", "terminal.fill", "music.note", "play.fill", "pause.fill",
        "forward.fill", "speaker.wave.2.fill", "speaker.slash.fill", "mic.fill",
        "video.fill", "display", "keyboard", "lock.fill", "moon.fill", "sun.max.fill",
        "calendar", "doc.fill", "trash.fill", "gearshape.fill", "globe", "star.fill",
        "bolt.fill", "house.fill", "rectangle.3.group", "scissors", "paintbrush.fill",
        "wand.and.stars",
    ]
    private static let colors = [
        "#3478F6", "#30B0C7", "#32D74B", "#FFD60A", "#FF9F0A",
        "#FF453A", "#AF52DE", "#FF2D55", "#8E8E93", "#1C1C1E",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Button").font(.system(size: 14, weight: .bold))

            TextField("Title", text: $button.title)
                .textFieldStyle(.roundedBorder)

            // icon: a visible grid, not a buried menu (the Loupedeck complaint)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { sym in
                    Image(systemName: sym)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(button.symbol == sym
                                ? Color.accentColor.opacity(0.8)
                                : Color.secondary.opacity(0.12)))
                        .foregroundColor(button.symbol == sym ? .white : .primary)
                        .onTapGesture { button.symbol = sym }
                }
            }
            TextField("Or any SF Symbol name", text: $button.symbol)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))

            HStack(spacing: 6) {
                ForEach(Self.colors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(
                            button.colorHex == hex ? 0.8 : 0), lineWidth: 2))
                        .onTapGesture { button.colorHex = hex }
                }
            }

            Divider()

            Picker("Action", selection: $button.action.kind) {
                ForEach(DeckActionKind.allCases) { Text($0.label).tag($0) }
            }
            if button.action.kind != .none {
                TextField("Value", text: $button.action.value)
                    .textFieldStyle(.roundedBorder)
                Text(button.action.kind.hint)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Test") { DeckRunner.run(button.action) }
                Spacer()
                Button(role: .destructive, action: onDelete) { Text("Delete") }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
