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
        .background(deckBackground)
    }

    /// Deck panel background: blur (live glass), opaque (flat fill), or clear
    /// (transparent — just a hairline). Set via the deck ⋯ menu.
    @ViewBuilder private var deckBackground: some View {
        switch settings.deckBackground {
        case "opaque":
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(settings.deckOpacity))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        case "clear":
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        default:
            Color.clear.gcActiveBlur(cornerRadius: 16)
        }
    }

    // MARK: unified spanning grid — buttons (1×1) and widgets (W×H), first-fit
    // packed so some tiles use more cells and others fewer, all square-aligned.

    // Fixed-ish cell size: the panel does NOT scroll. Making the panel bigger
    // adds more grid cells (more columns/rows) rather than enlarging the tiles.
    // The block size is user-set (Settings → deck menu → Block size).
    private let gridSpacing: CGFloat = 8

    private var packedGrid: some View {
        let spacing = gridSpacing
        let targetCell = CGFloat(settings.deckCellSize)
        return GeometryReader { geo in
            // Columns from width at the target cell size; cell snaps to fill width.
            let cols = max(2, Int((geo.size.width + spacing) / (targetCell + spacing)))
            let cell = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            // Rows that fit the panel height (no scroll); edit mode fills the
            // panel with empty guide cells so there's room to resize/drag into.
            let fitRows = max(1, Int((geo.size.height + spacing) / (cell + spacing)))
            let packed = packLayout(columns: cols)
            let gridRows = store.editing ? max(packed.rows, fitRows) : packed.rows
            ZStack(alignment: .topLeading) {
                if store.editing {
                    // A "+" in every empty cell — one unified add menu (these
                    // also serve as the visible grid affordance).
                    ForEach(emptyCells(cols: cols, rows: gridRows, occupied: packed.occupied),
                            id: \.self) { key in
                        let r = key / cols, c = key % cols
                        AddCell(extensions: WidgetRegistry.shared.manifests,
                                onPick: addElement)
                            .frame(width: cell, height: cell)
                            .offset(x: CGFloat(c) * (cell + spacing),
                                    y: CGFloat(r) * (cell + spacing))
                    }
                }
                ForEach(packed.slots) { slot in
                    tile(for: slot, cell: cell, step: cell + spacing, cols: cols)
                        .frame(width: cell * CGFloat(slot.w) + spacing * CGFloat(slot.w - 1),
                               height: cell * CGFloat(slot.h) + spacing * CGFloat(slot.h - 1))
                        .offset(x: CGFloat(slot.col) * (cell + spacing),
                                y: CGFloat(slot.row) * (cell + spacing))
                        .animation(.spring(response: 0.3, dampingFraction: 0.82),
                                   value: "\(slot.col),\(slot.row),\(slot.w),\(slot.h)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// (unused) Faint dashed cell outlines — kept for reference; empty cells now
    /// render AddCell which provides the grid affordance.
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
        }
    }

    /// Empty cell keys (row*cols + col) within the editable grid.
    private func emptyCells(cols: Int, rows: Int, occupied: Set<Int>) -> [Int] {
        var out: [Int] = []
        for r in 0..<rows { for c in 0..<cols {
            let k = r * cols + c
            if !occupied.contains(k) { out.append(k) }
        } }
        return out
    }

    /// Unified add: "button" makes a blank button; any other value is a widget
    /// kind. The packer drops it into the first free cell.
    private func addElement(_ kind: String) {
        if kind == "button" {
            store.layout.pages[pageIndex].buttons.append(DeckButton())
        } else {
            let span = widgetDefaultSpan(kind)
            let cols = max(2, store.layout.columns)
            store.layout.pages[pageIndex].widgets.append(
                DeckWidget(kind: kind, spanW: min(span.w, cols), spanH: span.h))
        }
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
            case widget(DeckWidget), button(DeckButton)
        }
    }

    /// Place items in the page's unified order into a `columns`-wide grid, each
    /// at the first free spot (top-to-bottom, left-to-right). Returns slots,
    /// row count, and the set of occupied cell keys (row*columns + col) so the
    /// view can draw a "+" in every empty cell.
    private func packLayout(columns: Int) -> (slots: [GridSlot], rows: Int, occupied: Set<Int>) {
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
        let rows = (occupied.map { $0 / columns }.max() ?? -1) + 1
        return (slots, max(1, rows), occupied)
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
            Button("Toggle Full Screen") {
                NotificationCenter.default.post(name: .gcDeckFullScreen, object: nil)
            }
            Menu("Block Size") {
                Button("Small") { settings.deckCellSize = 84 }
                Button("Medium") { settings.deckCellSize = 104 }
                Button("Large") { settings.deckCellSize = 128 }
            }
            Menu("Background") {
                Button("Blur") { settings.deckBackground = "blur" }
                Button("Opaque") { settings.deckBackground = "opaque" }
                Button("Transparent") { settings.deckBackground = "clear" }
            }
            // Columns are derived from the panel size + block size — resize the
            // panel (corner bean) to get more grid space.
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

// MARK: - add cell ("+" in every empty grid slot → unified add picker)

private struct AddCell: View {
    let extensions: [WidgetManifest]
    let onPick: (String) -> Void           // "button" or a widget kind
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay(Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                pick("Button", "square.grid.2x2", "button")
                Divider()
                pick("Clock", "clock", "clock")
                pick("Volume", "speaker.wave.2.fill", "volume")
                pick("Media controls", "playpause.fill", "media")
                pick("Claude usage", "sparkles", "claude")
                pick("Battery", "battery.100", "battery")
                pick("CPU load", "cpu", "cpu")
                pick("RAM", "memorychip", "ram")
                pick("Emoji picker", "face.smiling", "emoji")
                if !extensions.isEmpty {
                    Divider()
                    ForEach(extensions) { m in
                        pick(m.name, m.symbol ?? "puzzlepiece.extension", "ext:\(m.id)")
                    }
                }
                Divider()
                Button {
                    NSWorkspace.shared.open(WidgetRegistry.folder); show = false
                } label: { Label("Open Extensions Folder…", systemImage: "folder") }
                    .buttonStyle(.plain).font(.system(size: 12))
                Button {
                    WidgetRegistry.shared.reload(); show = false
                } label: { Label("Reload Extensions", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 12))
            }
            .padding(12).frame(width: 220)
        }
    }

    private func pick(_ title: String, _ symbol: String, _ kind: String) -> some View {
        Button { onPick(kind); show = false } label: {
            Label(title, systemImage: symbol).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

// MARK: - keystroke capture ("record shortcut")

/// System-wide key capture via a CGEvent tap (the deck is a non-activating
/// panel, so NSEvent local/global monitors are unreliable here). The tap also
/// SWALLOWS the captured combo so recording `cmd+shift+4` doesn't fire a
/// screenshot. Requires Accessibility (Gatecaster already has it).
final class KeyRecorder {
    private var tap: CFMachPort?
    private var src: CFRunLoopSource?
    private var onCapture: ((String?) -> Void)?

    func start(_ onCapture: @escaping (String?) -> Void) {
        stop()
        self.onCapture = onCapture
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let cb: CGEventTapCallBack = { _, _, event, userInfo in
            let me = Unmanaged<KeyRecorder>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onCapture(nil); return
        }
        self.tap = tap
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        src = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let f = event.flags
        let hasMod = f.contains(.maskCommand) || f.contains(.maskShift)
            || f.contains(.maskAlternate) || f.contains(.maskControl)
        if code == 53, !hasMod { finish(nil); return nil }      // esc cancels
        guard let key = DeckRunner.keyName(for: code) else { return nil }
        var parts: [String] = []
        if f.contains(.maskCommand) { parts.append("cmd") }
        if f.contains(.maskShift) { parts.append("shift") }
        if f.contains(.maskAlternate) { parts.append("alt") }
        if f.contains(.maskControl) { parts.append("ctrl") }
        if f.contains(.maskSecondaryFn) { parts.append("fn") }
        parts.append(key)
        finish(parts.joined(separator: "+"))
        return nil                                              // swallow the combo
    }

    private func finish(_ s: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(s); self?.stop()
        }
    }
    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let s = src { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; src = nil; onCapture = nil
    }
}

/// Press Record, then press the real keys — captured into our keystroke syntax.
struct KeyCaptureField: View {
    @Binding var value: String
    @State private var recording = false
    @State private var recorder = KeyRecorder()

    var body: some View {
        HStack(spacing: 8) {
            Text(value.isEmpty ? "no shortcut" : value)
                .font(.system(size: 13, weight: .medium).monospaced())
                .foregroundColor(value.isEmpty ? .secondary : .primary)
            Spacer()
            Button(recording ? "Press keys… (esc cancels)" : "Record") {
                if recording { recorder.stop(); recording = false }
                else {
                    recording = true
                    recorder.start { captured in
                        if let c = captured { value = c }
                        recording = false
                    }
                }
            }
            .font(.system(size: 12))
            .tint(recording ? .red : .accentColor)
        }
        .padding(.vertical, 2)
        .onDisappear { recorder.stop() }
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
            if button.action.kind == .keystroke {
                KeyCaptureField(value: $button.action.value)
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
