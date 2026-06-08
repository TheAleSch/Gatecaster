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

    private var pageIndex: Int { min(store.currentPage, store.layout.pages.count - 1) }

    var body: some View {
        VStack(spacing: 6) {
            header
            pageBar
            packedGrid
                .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .padding(.top, 4)
        .gcActiveBlur(cornerRadius: 16, blur: settings.panelBlur, opacity: settings.keyboardOpacity)
    }

    // MARK: unified spanning grid — buttons (1×1) and widgets (W×H), first-fit
    // packed so some tiles use more cells and others fewer, all square-aligned.

    private var packedGrid: some View {
        let cols = max(2, store.layout.columns)
        let spacing: CGFloat = 8
        let packed = packLayout(columns: cols)
        return GeometryReader { geo in
            let cell = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            // In edit mode, fill the viewport with empty grid cells (plus a few
            // spare rows) so you can resize/drag into real empty space instead
            // of growing over the existing tiles.
            let viewportRows = max(1, Int((geo.size.height + spacing) / (cell + spacing)))
            let gridRows = store.editing
                ? max(packed.rows + 2, viewportRows)
                : packed.rows
            ScrollView {
                ZStack(alignment: .topLeading) {
                    if store.editing {
                        gridGuides(cols: cols, rows: gridRows, cell: cell, spacing: spacing)
                    }
                    ForEach(packed.slots) { slot in
                        tile(for: slot, cell: cell, step: cell + spacing, cols: cols)
                            .frame(width: cell * CGFloat(slot.w) + spacing * CGFloat(slot.w - 1),
                                   height: cell * CGFloat(slot.h) + spacing * CGFloat(slot.h - 1))
                            .offset(x: CGFloat(slot.col) * (cell + spacing),
                                    y: CGFloat(slot.row) * (cell + spacing))
                            // Animate position + size so resizing/reflow glides
                            // instead of teleporting (the packer moves tiles).
                            .animation(.spring(response: 0.3, dampingFraction: 0.82),
                                       value: "\(slot.col),\(slot.row),\(slot.w),\(slot.h)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: CGFloat(gridRows) * cell
                       + spacing * CGFloat(max(0, gridRows - 1)))
            }
        }
    }

    /// Faint dashed cell outlines shown in edit mode so snapping is visible.
    private func gridGuides(cols: Int, rows: Int, cell: CGFloat, spacing: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<(cols * max(1, rows)), id: \.self) { idx in
                let r = idx / cols, c = idx % cols
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.18),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: cell, height: cell)
                    .offset(x: CGFloat(c) * (cell + spacing),
                            y: CGFloat(r) * (cell + spacing))
            }
        }
    }

    @ViewBuilder
    private func tile(for slot: GridSlot, cell: CGFloat, step: CGFloat, cols: Int) -> some View {
        switch slot.kind {
        case .widget(let w):
            let mn = widgetMinSpan(w)
            WidgetTile(widget: widgetBinding(w.id), editing: store.editing,
                       cell: cell, step: step, maxCols: cols,
                       minW: min(mn.w, cols), minH: mn.h, onDelete: { removeWidget(w) })
                .modifier(DraggableItem(id: w.id, editing: store.editing,
                                        draggingID: $draggingID, reorder: reorder))
        case .button(let btn):
            DeckButtonView(button: binding(for: btn), editing: store.editing,
                           onDelete: { delete(btn) })
                .modifier(DraggableItem(id: btn.id, editing: store.editing,
                                        draggingID: $draggingID, reorder: reorder))
        case .addButton:
            Button { store.layout.pages[pageIndex].buttons.append(DeckButton()) } label: {
                addTile(symbol: "plus", label: nil)
            }
            .buttonStyle(.plain)
        case .addWidget:
            Menu { addWidgetMenu } label: {
                addTile(symbol: "puzzlepiece.extension", label: "Widget")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }
    }

    private func addTile(symbol: String, label: String?) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 2, dash: [6]))
            .overlay(VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                if let label { Text(label).font(.system(size: 10)) }
            }.foregroundColor(.secondary))
    }

    @ViewBuilder private var addWidgetMenu: some View {
        Button("Clock") { addWidget(kind: "clock") }
        Button("Volume") { addWidget(kind: "volume") }
        Button("Media controls") { addWidget(kind: "media") }
        Button("Claude usage") { addWidget(kind: "claude") }
        Button("Battery") { addWidget(kind: "battery") }
        Button("CPU load") { addWidget(kind: "cpu") }
        let exts = WidgetRegistry.shared.manifests
        if !exts.isEmpty {
            Divider()
            ForEach(exts) { m in
                Button(m.name) { addWidget(kind: "ext:\(m.id)") }
            }
        }
        Divider()
        Button("Open Extensions Folder…") { NSWorkspace.shared.open(WidgetRegistry.folder) }
        Button("Reload Extensions") { WidgetRegistry.shared.reload() }
    }

    private func addWidget(kind: String) {
        let span = widgetDefaultSpan(kind)
        let cols = max(2, store.layout.columns)
        store.layout.pages[pageIndex].widgets.append(
            DeckWidget(kind: kind, spanW: min(span.w, cols), spanH: span.h))
    }
    private func removeWidget(_ w: DeckWidget) {
        store.layout.pages[pageIndex].widgets.removeAll { $0.id == w.id }
    }

    private func widgetBinding(_ id: UUID) -> Binding<DeckWidget> {
        Binding(
            get: {
                store.layout.pages[pageIndex].widgets.first { $0.id == id } ?? DeckWidget()
            },
            set: { nv in
                if let i = store.layout.pages[pageIndex].widgets.firstIndex(where: { $0.id == id }) {
                    store.layout.pages[pageIndex].widgets[i] = nv
                }
            })
    }

    // MARK: first-fit packing

    struct GridSlot: Identifiable {
        let id: String
        let col: Int, row: Int, w: Int, h: Int
        let kind: Kind
        enum Kind {
            case widget(DeckWidget), button(DeckButton), addButton, addWidget
        }
    }

    /// Place items in the page's unified order into a `columns`-wide grid, each
    /// at the first free spot (top-to-bottom, left-to-right). Returns slots + rows.
    private func packLayout(columns: Int) -> (slots: [GridSlot], rows: Int) {
        var occupied = Set<Int>()                       // key = row*columns + col
        func isFree(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            if c + w > columns { return false }
            for dr in 0..<h { for dc in 0..<w {
                if occupied.contains((r + dr) * columns + c + dc) { return false }
            } }
            return true
        }
        func place(_ w: Int, _ h: Int) -> (Int, Int) {
            var r = 0
            while true {
                for c in 0...max(0, columns - w) where isFree(r, c, w, h) {
                    for dr in 0..<h { for dc in 0..<w {
                        occupied.insert((r + dr) * columns + c + dc)
                    } }
                    return (r, c)
                }
                r += 1
            }
        }
        var slots: [GridSlot] = []
        let page = store.layout.pages[pageIndex]
        let wById = Dictionary(page.widgets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bById = Dictionary(page.buttons.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in page.resolvedOrder {
            if let wdg = wById[id] {
                let w = min(max(1, wdg.spanW), columns), h = max(1, wdg.spanH)
                let (r, c) = place(w, h)
                slots.append(GridSlot(id: id.uuidString, col: c, row: r, w: w, h: h,
                                      kind: .widget(wdg)))
            } else if let btn = bById[id] {
                let (r, c) = place(1, 1)
                slots.append(GridSlot(id: id.uuidString, col: c, row: r, w: 1, h: 1,
                                      kind: .button(btn)))
            }
        }
        if store.editing {
            let (r1, c1) = place(1, 1)
            slots.append(GridSlot(id: "add-button", col: c1, row: r1, w: 1, h: 1, kind: .addButton))
            let (r2, c2) = place(min(2, columns), 1)
            slots.append(GridSlot(id: "add-widget", col: c2, row: r2, w: min(2, columns), h: 1,
                                  kind: .addWidget))
        }
        let rows = (occupied.map { $0 / columns }.max() ?? -1) + 1
        return (slots, max(1, rows))
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
        .background(TitleBarDrag())   // mouse: drag panel by title bar only
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

    /// Move one item before/after another in the page's unified order (buttons
    /// and widgets together). The packer re-flows from the new order.
    private func reorder(_ dragId: UUID, _ targetId: UUID) {
        guard dragId != targetId else { return }
        var ids = store.layout.pages[pageIndex].resolvedOrder
        guard let from = ids.firstIndex(of: dragId),
              let to = ids.firstIndex(of: targetId) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        store.layout.pages[pageIndex].order = ids
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

// MARK: - drag-to-reorder (unified: buttons + widgets share one order)

/// Makes any tile draggable in edit mode. On drop-enter it asks the parent to
/// reorder the dragged id relative to this tile's id.
private struct DraggableItem: ViewModifier {
    let id: UUID
    let editing: Bool
    @Binding var draggingID: UUID?
    let reorder: (UUID, UUID) -> Void

    func body(content: Content) -> some View {
        if editing {
            content
                .onDrag {
                    draggingID = id
                    return NSItemProvider(object: id.uuidString as NSString)
                }
                .onDrop(of: [UTType.text],
                        delegate: ItemDrop(target: id, draggingID: $draggingID,
                                           reorder: reorder))
        } else {
            content
        }
    }
}

private struct ItemDrop: DropDelegate {
    let target: UUID
    @Binding var draggingID: UUID?
    let reorder: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = draggingID, d != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { reorder(d, target) }
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

    // Empty colorHex = neutral keycap (matches the on-screen keyboard); a chosen
    // color tints the tile and switches the label to white for contrast.
    private var isNeutral: Bool { button.colorHex.isEmpty }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(isNeutral
                      ? Color(nsColor: .controlColor).opacity(pressed ? 0.6 : 1.0)
                      : Color(hex: button.colorHex).opacity(pressed ? 0.55 : 0.85))
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
            VStack(spacing: 4) {
                Image(systemName: button.symbol)
                    .font(.system(size: 22, weight: .semibold))
                Text(button.title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundColor(isNeutral ? .primary : .white)
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
                // Neutral (default) — matches the on-screen keyboard keycaps.
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(
                        button.colorHex.isEmpty ? 0.8 : 0.25), lineWidth: 2))
                    .overlay(Image(systemName: "circle.slash")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .opacity(button.colorHex.isEmpty ? 0 : 0.6))
                    .onTapGesture { button.colorHex = "" }
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
