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

    @State private var showSettings = false
    // Live pixel offset of a tile being dragged to a new cell (keyed by slot id).
    // The model's gridCol/gridRow is only written on release, so the grid never
    // reflows mid-drag — the tile tracks the finger, then snaps to a cell.
    @State private var dragOffsets: [String: CGSize] = [:]

    private var pageIndex: Int { min(store.currentPage, store.layout.pages.count - 1) }
    private var theme: DeckTheme { DeckTheme.theme(settings.deckTheme) }

    var body: some View {
        VStack(spacing: 6) {
            header
            pageBar
            activeGrid
                .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .padding(.top, 4)
        .background(deckBackground)
        .environment(\.colorScheme, theme.scheme)   // flip system colors per theme
        .sheet(isPresented: $showSettings) {
            DeckSettingsView(settings: settings) { showSettings = false }
        }
    }

    /// Deck panel background, driven by the selected theme + transparency.
    @ViewBuilder private var deckBackground: some View {
        let op = theme.forcesOpaque ? 1.0 : settings.deckOpacity
        switch theme.background {
        case .blur:
            Color.clear.gcActiveBlur(cornerRadius: GC.Radius.panel)
        case .solid(let hex):
            RoundedRectangle(cornerRadius: GC.Radius.panel)
                .fill(Color(hex: hex).opacity(op))
                .overlay(RoundedRectangle(cornerRadius: GC.Radius.panel)
                    .strokeBorder(Color.primary.opacity(GC.Op.hairline), lineWidth: 1))
        case .gradient(let stops):
            ZStack {
                Color.clear.gcActiveBlur(cornerRadius: GC.Radius.panel)
                RoundedRectangle(cornerRadius: GC.Radius.panel)
                    .fill(LinearGradient(colors: stops.map { Color(hex: $0).opacity(op) },
                                         startPoint: .top, endPoint: .bottom))
            }
        }
    }

    // MARK: unified spanning grid — buttons (1×1) and widgets (W×H), first-fit
    // packed so some tiles use more cells and others fewer, all square-aligned.

    // Fixed-ish cell size: the panel does NOT scroll. Making the panel bigger
    // adds more grid cells (more columns/rows) rather than enlarging the tiles.
    // The block size is user-set (Settings → deck menu → Block size).
    private let gridSpacing: CGFloat = 8
    private static let gridSpace = "deckGrid"   // drag drop-point coordinate space

    /// The deck's single grid. Items sit at their packed cell; an item with an
    /// explicit (gridCol, gridRow) is honored, the rest first-fit around it. In
    /// edit mode a top-left move handle drags a tile to a new cell (snapped on
    /// release) — kept separate from the WidgetTile resize handle (bottom-right)
    /// so the two gestures never fight.
    private var activeGrid: some View {
        let spacing = gridSpacing
        let targetCell = CGFloat(settings.deckCellSize)
        return GeometryReader { geo in
            // Columns from width at the target cell size; cell snaps to fill width.
            let cols = max(2, Int((geo.size.width + spacing) / (targetCell + spacing)))
            let cell = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let step = cell + spacing
            // Rows that fit the panel height (no scroll); edit mode fills the
            // panel with empty "+" cells so there's room to drag/resize into.
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
                            .offset(x: CGFloat(c) * step, y: CGFloat(r) * step)
                    }
                }
                ForEach(packed.slots) { slot in
                    let tileW = cell * CGFloat(slot.w) + spacing * CGFloat(slot.w - 1)
                    let tileH = cell * CGFloat(slot.h) + spacing * CGFloat(slot.h - 1)
                    let pos = CGPoint(x: CGFloat(slot.col) * step, y: CGFloat(slot.row) * step)
                    let liveOff = dragOffsets[slot.id] ?? .zero
                    placedTile(slot: slot, cell: cell, step: step, cols: cols)
                        .frame(width: tileW, height: tileH)
                        .offset(x: pos.x + liveOff.width, y: pos.y + liveOff.height)
                        // While dragging, ride above the other tiles; otherwise
                        // animate cell-to-cell moves (re-pack on release).
                        .zIndex(dragOffsets[slot.id] != nil ? 1 : 0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.82),
                                   value: "\(slot.col),\(slot.row),\(slot.w),\(slot.h)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: Self.gridSpace)   // drop points resolve here
        }
    }

    /// One placed tile. In edit mode the whole body is draggable (gated here so a
    /// non-edit touch never has a competing parent gesture — the volume slider's
    /// own highPriorityGesture stays free). The WidgetTile resize handle uses
    /// `highPriorityGesture`, so grabbing it resizes and beats this body drag.
    @ViewBuilder
    private func placedTile(slot: GridSlot, cell: CGFloat, step: CGFloat, cols: Int) -> some View {
        if store.editing {
            tile(for: slot, cell: cell, step: step, cols: cols)
                .gesture(tileDrag(slot: slot, cell: cell, step: step, cols: cols))
        } else {
            tile(for: slot, cell: cell, step: step, cols: cols)
        }
    }

    /// Drag a tile to move it. Live offset tracks the finger; on release the drop
    /// is interpreted by mode:
    ///  - Auto-Arrange ON  → REORDER (drop onto the nearest other tile, reflow).
    ///  - Auto-Arrange OFF → absolute placement (snap to the nearest cell).
    private func tileDrag(slot: GridSlot, cell: CGFloat, step: CGFloat, cols: Int) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.gridSpace))
            .onChanged { v in dragOffsets[slot.id] = v.translation }
            .onEnded { v in
                dragOffsets.removeValue(forKey: slot.id)
                handleDrop(slot: slot, drop: v.location, cell: cell, step: step, cols: cols)
            }
    }

    /// Resolve a drop. `drop` is in the grid's coordinate space (top-left origin).
    private func handleDrop(slot: GridSlot, drop: CGPoint, cell: CGFloat, step: CGFloat, cols: Int) {
        guard cols > 0 else { return }
        if store.layout.autoArrange {
            // Reorder: find the nearest OTHER tile's center to the drop point and
            // move the dragged item to its position in the unified order.
            let packed = packLayout(columns: cols)
            var best: (id: String, d: CGFloat)?
            for s in packed.slots where s.id != slot.id {
                let cx = (CGFloat(s.col) + CGFloat(s.w) / 2) * step
                let cy = (CGFloat(s.row) + CGFloat(s.h) / 2) * step
                let d = hypot(drop.x - cx, drop.y - cy)
                if best == nil || d < best!.d { best = (s.id, d) }
            }
            if let target = best, let dragId = UUID(uuidString: slot.id),
               let targetId = UUID(uuidString: target.id) {
                reorder(dragId, targetId)
            }
        } else {
            // Absolute: snap the drop (tile top-left ≈ drop minus half a cell) to
            // the nearest cell, clamped so a wide/tall tile stays on-grid.
            let nx = drop.x - cell / 2, ny = drop.y - cell / 2
            let col = min(max(0, cols - slot.w), max(0, Int((nx / step).rounded())))
            let row = max(0, Int((ny / step).rounded()))
            setGridPos(slot: slot, col: col, row: row)
        }
    }

    /// Move one item to another's position in the page's unified order; the packer
    /// re-flows from the new order (used in Auto-Arrange mode).
    private func reorder(_ dragId: UUID, _ targetId: UUID) {
        guard dragId != targetId else { return }
        var ids = store.layout.pages[pageIndex].resolvedOrder
        guard let from = ids.firstIndex(of: dragId),
              let to = ids.firstIndex(of: targetId) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        store.layout.pages[pageIndex].order = ids
    }

    /// Clear all explicit positions on the current page so everything reflows
    /// top-left ("Tidy Up Now").
    private func tidyUp() {
        for i in store.layout.pages[pageIndex].buttons.indices {
            store.layout.pages[pageIndex].buttons[i].gridCol = nil
            store.layout.pages[pageIndex].buttons[i].gridRow = nil
        }
        for i in store.layout.pages[pageIndex].widgets.indices {
            store.layout.pages[pageIndex].widgets[i].gridCol = nil
            store.layout.pages[pageIndex].widgets[i].gridRow = nil
        }
    }

    /// Persist an explicit cell position for the dragged item (the packer honors
    /// it next layout pass; any displaced item first-fits around it).
    private func setGridPos(slot: GridSlot, col: Int, row: Int) {
        switch slot.kind {
        case .button(let b):
            if let i = store.layout.pages[pageIndex].buttons.firstIndex(where: { $0.id == b.id }) {
                store.layout.pages[pageIndex].buttons[i].gridCol = col
                store.layout.pages[pageIndex].buttons[i].gridRow = row
            }
        case .widget(let w):
            if let i = store.layout.pages[pageIndex].widgets.firstIndex(where: { $0.id == w.id }) {
                store.layout.pages[pageIndex].widgets[i].gridCol = col
                store.layout.pages[pageIndex].widgets[i].gridRow = row
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
        case .button(let btn):
            DeckButtonView(button: binding(for: btn), editing: store.editing,
                           onDelete: { delete(btn) })
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

    /// Place items in the page's unified order into a `columns`-wide grid. An item
    /// with an explicit (gridCol, gridRow) is honored when that cell range is free
    /// and in-bounds; everything else (and any item whose explicit cell collides)
    /// first-fits at the next free spot. Returns slots, row count, and the set of
    /// occupied cell keys (row*columns + col) so the view can draw a "+" in empties.
    private func packLayout(columns: Int) -> (slots: [GridSlot], rows: Int, occupied: Set<Int>) {
        var occupied = Set<Int>()                       // key = row*columns + col
        func isFree(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            if r < 0 || c < 0 || c + w > columns { return false }
            for dr in 0..<h { for dc in 0..<w {
                if occupied.contains((r + dr) * columns + c + dc) { return false }
            } }
            return true
        }
        func mark(_ r: Int, _ c: Int, _ w: Int, _ h: Int) {
            for dr in 0..<h { for dc in 0..<w { occupied.insert((r + dr) * columns + c + dc) } }
        }
        func firstFit(_ w: Int, _ h: Int) -> (Int, Int) {
            var r = 0
            // Cap the scan so a fully-packed grid can't spin forever and hang the
            // UI thread; only reachable with ~16k tiles, so it's a safety net.
            while r < 4096 {                       // hard safety cap (no infinite spin)
                for c in 0...max(0, columns - w) where isFree(r, c, w, h) {
                    mark(r, c, w, h); return (r, c)
                }
                r += 1
            }
            // Cap exhausted: append below everything rather than collide. Cell
            // (0,0) was already scanned (likely occupied), so returning it would
            // overlap an existing tile. Row 4096 was never marked by isFree/mark
            // (they only touch rows 0..<4096), so this cell is guaranteed free.
            mark(4096, 0, w, h)
            return (4096, 0)
        }
        // Honor the stored cell if it fits and is free; else fall back to first-fit.
        func place(col: Int?, row: Int?, _ wIn: Int, _ hIn: Int) -> (Int, Int) {
            // Clamp span to the grid so an oversized item can't make isFree
            // always-false and spin (or overflow a row of cells).
            let w = max(1, min(wIn, columns))
            let h = max(1, hIn)
            if let c = col, let r = row, isFree(r, c, w, h) { mark(r, c, w, h); return (r, c) }
            return firstFit(w, h)
        }
        // Auto-Arrange ignores stored cells entirely → pure first-fit ("tidy"),
        // with drag mapped to REORDER. Manual mode honors each item's cell.
        let honor = !store.layout.autoArrange
        var slots: [GridSlot] = []
        let page = store.layout.pages[pageIndex]
        let wById = Dictionary(page.widgets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bById = Dictionary(page.buttons.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in page.resolvedOrder {
            if let wdg = wById[id] {
                let w = min(max(1, wdg.spanW), columns), h = max(1, wdg.spanH)
                let (r, c) = place(col: honor ? wdg.gridCol : nil,
                                   row: honor ? wdg.gridRow : nil, w, h)
                slots.append(GridSlot(id: id.uuidString, col: c, row: r, w: w, h: h,
                                      kind: .widget(wdg)))
            } else if let btn = bById[id] {
                let (r, c) = place(col: honor ? btn.gridCol : nil,
                                   row: honor ? btn.gridRow : nil, 1, 1)
                slots.append(GridSlot(id: id.uuidString, col: c, row: r, w: 1, h: 1,
                                      kind: .button(btn)))
            }
        }
        let rows = (occupied.map { $0 / columns }.max() ?? -1) + 1
        return (slots, max(1, rows), occupied)
    }

    // MARK: chrome (matches keyboard/trackpad panels; top bar = engine drag zone)

    /// Shared deck-header icon: a filled circular chip matching ResizeBean's capsule
    /// (same secondary 0.35 fill), with a BARE glyph inside. We draw the circle
    /// ourselves because SF Symbols' pre-circled variants (`*.circle`) each pad
    /// their ring differently — no font size or resizable box ever made them equal.
    /// Owning the shape guarantees identical chips; only the small inner glyph
    /// varies. 36×36 frame + contentShape is the hit area.
    private func headerIcon(_ name: String) -> some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.35))
            Image(systemName: name)
                .font(.system(size: 14, weight: .bold))
        }
        .frame(width: 30, height: 30)
        .frame(width: 36, height: 36).contentShape(Rectangle())
    }

    private var header: some View {
        VStack(spacing: 4) {
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5)
        HStack(spacing: 10) {
            Text("Deck").font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                store.editing.toggle()
            } label: {
                headerIcon(store.editing ? "checkmark" : "pencil")
            }
            .buttonStyle(GCPressStyle())
            .foregroundColor(store.editing ? .accentColor : .secondary)
            settingsMenu
            Button { showSettings = true } label: {
                headerIcon("gearshape")
            }
            .buttonStyle(GCPressStyle()).foregroundColor(.secondary)
            if !store.fullScreen { ResizeBean() }   // nothing to resize at full screen
            Button(action: onHide) {
                headerIcon("chevron.down")
            }
            .buttonStyle(GCPressStyle()).foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        }
        .padding(.top, 6)
        .background(TitleBarDrag())   // mouse: drag panel by title bar only
    }

    private var settingsMenu: some View {
        Menu {
            Button("Import Page / Layout…") { importLayout() }
            Button("Export Page / Layout…") { exportLayout() }
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
            Divider()
            Button(store.layout.autoArrange ? "Auto-Arrange  ✓" : "Auto-Arrange") {
                store.layout.autoArrange.toggle()
            }
            Button("Tidy Up Now") { tidyUp() }
            Menu("Block Size") {
                Button("Small") { settings.deckCellSize = 84 }
                Button("Medium") { settings.deckCellSize = 104 }
                Button("Large") { settings.deckCellSize = 128 }
            }
        } label: {
            headerIcon("ellipsis")   // same chip as the gear → identical by construction
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        // .borderlessButton renders its label a control-size SMALLER than the plain
        // gear/pencil Buttons, which is why the glyph looked shrunk despite the shared
        // helper. Force the large control size so it matches the rest of the row.
        .controlSize(.large)
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
            RoundedRectangle(cornerRadius: GC.Radius.tile)
                .strokeBorder(Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay(Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7)))
                .contentShape(RoundedRectangle(cornerRadius: GC.Radius.tile))
        }
        .buttonStyle(GCPressStyle())
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
                pick("Timer", "timer", "timer")
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
        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<KeyRecorder>.fromOpaque(userInfo!).takeUnretainedValue()
            // The OS disables a tap after a timeout / on user input — re-enable
            // it, otherwise recording silently dies after the first hiccup.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
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
            RoundedRectangle(cornerRadius: GC.Radius.tile)
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
                .buttonStyle(GCPressStyle())
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: GC.Radius.tile))
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
