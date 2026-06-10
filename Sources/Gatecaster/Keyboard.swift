import SwiftUI

// MARK: - key model

enum KeyKind {
    case key(CGKeyCode)     // posts a keystroke
    case shift              // one-shot shift
    case caps               // shift lock (UI-level; letters only)
    case mod(String)        // sticky "cmd" / "alt" / "ctrl" / "fn"
}

struct KeyDef {
    let label: String
    let shifted: String?
    let kind: KeyKind
    let w: CGFloat          // width weight (1 = standard key)

    init(_ label: String, _ shifted: String? = nil, code: CGKeyCode, w: CGFloat = 1) {
        self.label = label; self.shifted = shifted; self.kind = .key(code); self.w = w
    }
    init(_ label: String, kind: KeyKind, w: CGFloat = 1) {
        self.label = label; self.shifted = nil; self.kind = kind; self.w = w
    }
}

// MARK: - layouts
// Keycodes are POSITIONAL; macOS maps them through the active system input
// source. So these layouts mirror the keycaps of that source — pick the layout
// that matches your macOS input source. Chinese (Pinyin) and Japanese (Romaji)
// type through their IMEs over QWERTY, so they share the US keycaps.

enum KeyboardLayouts {
    static let options: [(id: String, name: String)] = [
        ("us", "English (US)"), ("fr", "Français (AZERTY)"), ("es", "Español"),
        ("pt", "Português"), ("uk", "Українська"), ("ko", "한국어 — 두벌식"),
        ("zh", "中文 — Pinyin"), ("ja", "日本語 — Romaji"),
    ]

    static func rows(for id: String) -> [[KeyDef]] {
        switch id {
        case "fr": return french
        case "es": return spanish
        case "pt": return portuguese
        case "uk": return ukrainian
        case "ko": return korean
        default:   return us        // us / zh / ja share QWERTY keycaps (IME input)
        }
    }

    private static let bottomRow: [KeyDef] = [
        KeyDef("fn", kind: .mod("fn")),
        KeyDef("⌃", kind: .mod("ctrl")),
        KeyDef("⌥", kind: .mod("alt")),
        KeyDef("⌘", kind: .mod("cmd"), w: 1.3),
        KeyDef("space", code: 49, w: 5),
        KeyDef("⌘", kind: .mod("cmd"), w: 1.3),
        KeyDef("◀", code: 123), KeyDef("▲", code: 126),
        KeyDef("▼", code: 125), KeyDef("▶", code: 124),
    ]

    // Numeric keypad column (real keypad keycodes, distinct from the number row).
    static let numpad: [[KeyDef]] = [
        [KeyDef("⌧", code: 71), KeyDef("=", code: 81), KeyDef("/", code: 75), KeyDef("*", code: 67)],
        [KeyDef("7", code: 89), KeyDef("8", code: 91), KeyDef("9", code: 92), KeyDef("-", code: 78)],
        [KeyDef("4", code: 86), KeyDef("5", code: 87), KeyDef("6", code: 88), KeyDef("+", code: 69)],
        [KeyDef("1", code: 83), KeyDef("2", code: 84), KeyDef("3", code: 85), KeyDef("⌅", code: 76)],
        [KeyDef("0", code: 82, w: 2), KeyDef(".", code: 65), KeyDef("⌅", code: 76)],
    ]

    static let us: [[KeyDef]] = [
        [KeyDef("`", "~", code: 50), KeyDef("1", "!", code: 18), KeyDef("2", "@", code: 19),
         KeyDef("3", "#", code: 20), KeyDef("4", "$", code: 21), KeyDef("5", "%", code: 23),
         KeyDef("6", "^", code: 22), KeyDef("7", "&", code: 26), KeyDef("8", "*", code: 28),
         KeyDef("9", "(", code: 25), KeyDef("0", ")", code: 29), KeyDef("-", "_", code: 27),
         KeyDef("=", "+", code: 24), KeyDef("⌫", code: 51, w: 1.6)],
        [KeyDef("⇥", code: 48, w: 1.6), KeyDef("q", code: 12), KeyDef("w", code: 13),
         KeyDef("e", code: 14), KeyDef("r", code: 15), KeyDef("t", code: 17),
         KeyDef("y", code: 16), KeyDef("u", code: 32), KeyDef("i", code: 34),
         KeyDef("o", code: 31), KeyDef("p", code: 35), KeyDef("[", "{", code: 33),
         KeyDef("]", "}", code: 30), KeyDef("\\", "|", code: 42)],
        [KeyDef("⇪", kind: .caps, w: 1.9), KeyDef("a", code: 0), KeyDef("s", code: 1),
         KeyDef("d", code: 2), KeyDef("f", code: 3), KeyDef("g", code: 5),
         KeyDef("h", code: 4), KeyDef("j", code: 38), KeyDef("k", code: 40),
         KeyDef("l", code: 37), KeyDef(";", ":", code: 41), KeyDef("'", "\"", code: 39),
         KeyDef("↩", code: 36, w: 1.9)],
        [KeyDef("⇧", kind: .shift, w: 2.4), KeyDef("z", code: 6), KeyDef("x", code: 7),
         KeyDef("c", code: 8), KeyDef("v", code: 9), KeyDef("b", code: 11),
         KeyDef("n", code: 45), KeyDef("m", code: 46), KeyDef(",", "<", code: 43),
         KeyDef(".", ">", code: 47), KeyDef("/", "?", code: 44),
         KeyDef("⇧", kind: .shift, w: 2.4)],
        bottomRow,
    ]

    static let french: [[KeyDef]] = [
        [KeyDef("@", "#", code: 50), KeyDef("&", "1", code: 18), KeyDef("é", "2", code: 19),
         KeyDef("\"", "3", code: 20), KeyDef("'", "4", code: 21), KeyDef("(", "5", code: 23),
         KeyDef("§", "6", code: 22), KeyDef("è", "7", code: 26), KeyDef("!", "8", code: 28),
         KeyDef("ç", "9", code: 25), KeyDef("à", "0", code: 29), KeyDef(")", "°", code: 27),
         KeyDef("-", "_", code: 24), KeyDef("⌫", code: 51, w: 1.6)],
        [KeyDef("⇥", code: 48, w: 1.6), KeyDef("a", code: 12), KeyDef("z", code: 13),
         KeyDef("e", code: 14), KeyDef("r", code: 15), KeyDef("t", code: 17),
         KeyDef("y", code: 16), KeyDef("u", code: 32), KeyDef("i", code: 34),
         KeyDef("o", code: 31), KeyDef("p", code: 35), KeyDef("^", "¨", code: 33),
         KeyDef("$", "*", code: 30), KeyDef("`", "£", code: 42)],
        [KeyDef("⇪", kind: .caps, w: 1.9), KeyDef("q", code: 0), KeyDef("s", code: 1),
         KeyDef("d", code: 2), KeyDef("f", code: 3), KeyDef("g", code: 5),
         KeyDef("h", code: 4), KeyDef("j", code: 38), KeyDef("k", code: 40),
         KeyDef("l", code: 37), KeyDef("m", code: 41), KeyDef("ù", "%", code: 39),
         KeyDef("↩", code: 36, w: 1.9)],
        [KeyDef("⇧", kind: .shift, w: 2.4), KeyDef("w", code: 6), KeyDef("x", code: 7),
         KeyDef("c", code: 8), KeyDef("v", code: 9), KeyDef("b", code: 11),
         KeyDef("n", code: 45), KeyDef(",", "?", code: 46), KeyDef(";", ".", code: 43),
         KeyDef(":", "/", code: 47), KeyDef("=", "+", code: 44),
         KeyDef("⇧", kind: .shift, w: 2.4)],
        bottomRow,
    ]

    static let spanish: [[KeyDef]] = [
        [KeyDef("º", "ª", code: 50), KeyDef("1", "!", code: 18), KeyDef("2", "\"", code: 19),
         KeyDef("3", "·", code: 20), KeyDef("4", "$", code: 21), KeyDef("5", "%", code: 23),
         KeyDef("6", "&", code: 22), KeyDef("7", "/", code: 26), KeyDef("8", "(", code: 28),
         KeyDef("9", ")", code: 25), KeyDef("0", "=", code: 29), KeyDef("'", "?", code: 27),
         KeyDef("¡", "¿", code: 24), KeyDef("⌫", code: 51, w: 1.6)],
        [KeyDef("⇥", code: 48, w: 1.6), KeyDef("q", code: 12), KeyDef("w", code: 13),
         KeyDef("e", code: 14), KeyDef("r", code: 15), KeyDef("t", code: 17),
         KeyDef("y", code: 16), KeyDef("u", code: 32), KeyDef("i", code: 34),
         KeyDef("o", code: 31), KeyDef("p", code: 35), KeyDef("`", "^", code: 33),
         KeyDef("+", "*", code: 30), KeyDef("ç", nil, code: 42)],
        [KeyDef("⇪", kind: .caps, w: 1.9), KeyDef("a", code: 0), KeyDef("s", code: 1),
         KeyDef("d", code: 2), KeyDef("f", code: 3), KeyDef("g", code: 5),
         KeyDef("h", code: 4), KeyDef("j", code: 38), KeyDef("k", code: 40),
         KeyDef("l", code: 37), KeyDef("ñ", nil, code: 41), KeyDef("´", "¨", code: 39),
         KeyDef("↩", code: 36, w: 1.9)],
        [KeyDef("⇧", kind: .shift, w: 2.4), KeyDef("z", code: 6), KeyDef("x", code: 7),
         KeyDef("c", code: 8), KeyDef("v", code: 9), KeyDef("b", code: 11),
         KeyDef("n", code: 45), KeyDef("m", code: 46), KeyDef(",", ";", code: 43),
         KeyDef(".", ":", code: 47), KeyDef("-", "_", code: 44),
         KeyDef("⇧", kind: .shift, w: 2.4)],
        bottomRow,
    ]

    static let portuguese: [[KeyDef]] = [
        [KeyDef("'", "\"", code: 50), KeyDef("1", "!", code: 18), KeyDef("2", "@", code: 19),
         KeyDef("3", "#", code: 20), KeyDef("4", "$", code: 21), KeyDef("5", "%", code: 23),
         KeyDef("6", "¨", code: 22), KeyDef("7", "&", code: 26), KeyDef("8", "*", code: 28),
         KeyDef("9", "(", code: 25), KeyDef("0", ")", code: 29), KeyDef("-", "_", code: 27),
         KeyDef("=", "+", code: 24), KeyDef("⌫", code: 51, w: 1.6)],
        [KeyDef("⇥", code: 48, w: 1.6), KeyDef("q", code: 12), KeyDef("w", code: 13),
         KeyDef("e", code: 14), KeyDef("r", code: 15), KeyDef("t", code: 17),
         KeyDef("y", code: 16), KeyDef("u", code: 32), KeyDef("i", code: 34),
         KeyDef("o", code: 31), KeyDef("p", code: 35), KeyDef("´", "`", code: 33),
         KeyDef("[", "{", code: 30), KeyDef("]", "}", code: 42)],
        [KeyDef("⇪", kind: .caps, w: 1.9), KeyDef("a", code: 0), KeyDef("s", code: 1),
         KeyDef("d", code: 2), KeyDef("f", code: 3), KeyDef("g", code: 5),
         KeyDef("h", code: 4), KeyDef("j", code: 38), KeyDef("k", code: 40),
         KeyDef("l", code: 37), KeyDef("ç", nil, code: 41), KeyDef("~", "^", code: 39),
         KeyDef("↩", code: 36, w: 1.9)],
        [KeyDef("⇧", kind: .shift, w: 2.4), KeyDef("z", code: 6), KeyDef("x", code: 7),
         KeyDef("c", code: 8), KeyDef("v", code: 9), KeyDef("b", code: 11),
         KeyDef("n", code: 45), KeyDef("m", code: 46), KeyDef(",", "<", code: 43),
         KeyDef(".", ">", code: 47), KeyDef(";", ":", code: 44),
         KeyDef("⇧", kind: .shift, w: 2.4)],
        bottomRow,
    ]
}

/// Collapsed state: a small pull tab pinned bottom-center of the touch display.
/// Tap it to pull the keyboard back up (snapped to the bottom edge).
struct KeyboardTabView: View {
    var onExpand: () -> Void
    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                Image(systemName: "chevron.up")
            }
            .font(.system(size: 21, weight: .bold))
            .frame(width: 220, height: 52)
            .gcActiveBlur(cornerRadius: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(GCPressStyle())
        .foregroundColor(.primary)
    }
}

extension KeyboardLayouts {
    // Korean Dubeolsik (두벌식): one jamo per key; the macOS IME composes the
    // syllable blocks. Shifted caps are the doubled consonants / ㅒㅖ.
    static let korean: [[KeyDef]] = [
        [KeyDef("`", "~", code: 50), KeyDef("1", "!", code: 18), KeyDef("2", "@", code: 19),
         KeyDef("3", "#", code: 20), KeyDef("4", "$", code: 21), KeyDef("5", "%", code: 23),
         KeyDef("6", "^", code: 22), KeyDef("7", "&", code: 26), KeyDef("8", "*", code: 28),
         KeyDef("9", "(", code: 25), KeyDef("0", ")", code: 29), KeyDef("-", "_", code: 27),
         KeyDef("=", "+", code: 24), KeyDef("⌫", code: 51, w: 1.6)],
        [KeyDef("⇥", code: 48, w: 1.6), KeyDef("ㅂ", "ㅃ", code: 12), KeyDef("ㅈ", "ㅉ", code: 13),
         KeyDef("ㄷ", "ㄸ", code: 14), KeyDef("ㄱ", "ㄲ", code: 15), KeyDef("ㅅ", "ㅆ", code: 17),
         KeyDef("ㅛ", nil, code: 16), KeyDef("ㅕ", nil, code: 32), KeyDef("ㅑ", nil, code: 34),
         KeyDef("ㅐ", "ㅒ", code: 31), KeyDef("ㅔ", "ㅖ", code: 35), KeyDef("[", "{", code: 33),
         KeyDef("]", "}", code: 30), KeyDef("\\", "|", code: 42)],
        [KeyDef("⇪", kind: .caps, w: 1.9), KeyDef("ㅁ", nil, code: 0), KeyDef("ㄴ", nil, code: 1),
         KeyDef("ㅇ", nil, code: 2), KeyDef("ㄹ", nil, code: 3), KeyDef("ㅎ", nil, code: 5),
         KeyDef("ㅗ", nil, code: 4), KeyDef("ㅓ", nil, code: 38), KeyDef("ㅏ", nil, code: 40),
         KeyDef("ㅣ", nil, code: 37), KeyDef(";", ":", code: 41), KeyDef("'", "\"", code: 39),
         KeyDef("↩", code: 36, w: 1.9)],
        [KeyDef("⇧", kind: .shift, w: 2.4), KeyDef("ㅋ", nil, code: 6), KeyDef("ㅌ", nil, code: 7),
         KeyDef("ㅊ", nil, code: 8), KeyDef("ㅍ", nil, code: 9), KeyDef("ㅠ", nil, code: 11),
         KeyDef("ㅜ", nil, code: 45), KeyDef("ㅡ", nil, code: 46), KeyDef(",", "<", code: 43),
         KeyDef(".", ">", code: 47), KeyDef("/", "?", code: 44),
         KeyDef("⇧", kind: .shift, w: 2.4)],
        [KeyDef("fn", kind: .mod("fn")),
         KeyDef("⌃", kind: .mod("ctrl")),
         KeyDef("⌥", kind: .mod("alt")),
         KeyDef("⌘", kind: .mod("cmd"), w: 1.3),
         KeyDef("space", code: 49, w: 5),
         KeyDef("⌘", kind: .mod("cmd"), w: 1.3),
         KeyDef("◀", code: 123), KeyDef("▲", code: 126),
         KeyDef("▼", code: 125), KeyDef("▶", code: 124)],
    ]

    static let ukrainian: [[KeyDef]] = [
        [KeyDef("ґ", nil, code: 50), KeyDef("1", "!", code: 18), KeyDef("2", "\"", code: 19),
         KeyDef("3", "№", code: 20), KeyDef("4", ";", code: 21), KeyDef("5", "%", code: 23),
         KeyDef("6", ":", code: 22), KeyDef("7", "?", code: 26), KeyDef("8", "*", code: 28),
         KeyDef("9", "(", code: 25), KeyDef("0", ")", code: 29), KeyDef("-", "_", code: 27),
         KeyDef("=", "+", code: 24), KeyDef("⌫", code: 51, w: 1.6)],
        [KeyDef("⇥", code: 48, w: 1.6), KeyDef("й", code: 12), KeyDef("ц", code: 13),
         KeyDef("у", code: 14), KeyDef("к", code: 15), KeyDef("е", code: 17),
         KeyDef("н", code: 16), KeyDef("г", code: 32), KeyDef("ш", code: 34),
         KeyDef("щ", code: 31), KeyDef("з", code: 35), KeyDef("х", code: 33),
         KeyDef("ї", code: 30), KeyDef("\\", "/", code: 42)],
        [KeyDef("⇪", kind: .caps, w: 1.9), KeyDef("ф", code: 0), KeyDef("і", code: 1),
         KeyDef("в", code: 2), KeyDef("а", code: 3), KeyDef("п", code: 5),
         KeyDef("р", code: 4), KeyDef("о", code: 38), KeyDef("л", code: 40),
         KeyDef("д", code: 37), KeyDef("ж", code: 41), KeyDef("є", code: 39),
         KeyDef("↩", code: 36, w: 1.9)],
        [KeyDef("⇧", kind: .shift, w: 2.4), KeyDef("я", code: 6), KeyDef("ч", code: 7),
         KeyDef("с", code: 8), KeyDef("м", code: 9), KeyDef("и", code: 11),
         KeyDef("т", code: 45), KeyDef("ь", code: 46), KeyDef("б", "<", code: 43),
         KeyDef("ю", ">", code: 47), KeyDef(".", ",", code: 44),
         KeyDef("⇧", kind: .shift, w: 2.4)],
        [KeyDef("fn", kind: .mod("fn")),
         KeyDef("⌃", kind: .mod("ctrl")),
         KeyDef("⌥", kind: .mod("alt")),
         KeyDef("⌘", kind: .mod("cmd"), w: 1.3),
         KeyDef("space", code: 49, w: 5),
         KeyDef("⌘", kind: .mod("cmd"), w: 1.3),
         KeyDef("◀", code: 123), KeyDef("▲", code: 126),
         KeyDef("▼", code: 125), KeyDef("▶", code: 124)],
    ]
}

// MARK: - keyboard view

/// A full Mac-style on-screen keyboard (number row, tab/caps/shift, punctuation,
/// arrows) with selectable keycap layouts, an optional esc/F1–F12 row, and sticky
/// ⌘ ⌥ ⌃ fn modifiers. Light/dark adaptive, draggable by its top bar, resizable
/// by the corner bean (keys stretch to fill). Keys post real CGEvent keystrokes,
/// so it types into whatever app is focused; the hosting panel never takes focus.
struct KeyboardView: View {
    @ObservedObject var settings: AppSettings
    var onHide: () -> Void
    @State private var shift = false
    @State private var caps = false
    @State private var mods: Set<String> = []

    private let fnRow: [(String, CGKeyCode)] = [
        ("esc",53),("F1",122),("F2",120),("F3",99),("F4",118),("F5",96),("F6",97),
        ("F7",98),("F8",100),("F9",101),("F10",109),("F11",103),("F12",111),
    ]

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5)
                Spacer()
                ResizeBean()
                Button(action: onHide) {
                    Image(systemName: "chevron.down.circle.fill").font(.system(size: 26))
                        .frame(width: 40, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(GCPressStyle()).foregroundColor(.secondary)
            }
            .padding(.horizontal, 6).padding(.top, 4)
            .background(TitleBarDrag())   // mouse: drag panel by title bar only

            if settings.keyboardExtendedKeys {
                HStack(spacing: 4) {
                    ForEach(fnRow.indices, id: \.self) { i in
                        fnKey(fnRow[i].0, fnRow[i].1)
                    }
                }
            }
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 12) {   // wider gap before the numpad
                    VStack(spacing: 5) {
                        ForEach(layoutRows.indices, id: \.self) { ri in
                            rowView(layoutRows[ri], width: mainW(geo.size.width))
                        }
                    }
                    if settings.keyboardNumpad {
                        VStack(spacing: 5) {
                            ForEach(KeyboardLayouts.numpad.indices, id: \.self) { ri in
                                rowView(KeyboardLayouts.numpad[ri], width: padW(geo.size.width))
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .gcActiveBlur(cornerRadius: GC.Radius.panel, blur: settings.panelBlur, opacity: settings.keyboardOpacity)
    }

    private var layoutRows: [[KeyDef]] { KeyboardLayouts.rows(for: settings.keyboardLayout) }

    private func mainW(_ total: CGFloat) -> CGFloat {
        settings.keyboardNumpad ? total * 0.78 - 12 : total
    }
    private func padW(_ total: CGFloat) -> CGFloat { total * 0.22 }

    private func rowView(_ keys: [KeyDef], width: CGFloat) -> some View {
        let spacing: CGFloat = 5
        let weights = keys.reduce(CGFloat(0)) { $0 + $1.w }
        let unit = max(10, (width - spacing * CGFloat(keys.count - 1)) / weights)
        return HStack(spacing: spacing) {
            ForEach(keys.indices, id: \.self) { i in
                keyView(keys[i], width: unit * keys[i].w)
            }
        }
    }

    private func keyView(_ k: KeyDef, width: CGFloat) -> some View {
        // iOS-style press feedback: highlight + dip on touch-down, and a
        // magnified key-pop callout above letter keys (so the finger doesn't
        // hide what was typed). Toggle via Settings → Keyboard.
        Button { press(k) } label: {
            Text(display(k))
                .font(.system(size: 16))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: width)
                .frame(minHeight: 30, maxHeight: .infinity)
                .background(keyShape(special: isSpecial(k), active: isActive(k)))
                .foregroundColor(isActive(k) ? Color.white : .primary)
        }
        .buttonStyle(KeyCapStyle(feedback: settings.keyPressFeedback,
                                 popLabel: settings.keyPopup && isLetter(k.label)
                                     ? display(k) : nil))
    }

    private func fnKey(_ label: String, _ code: CGKeyCode) -> some View {
        Button { fire(code, letter: false) } label: {
            Text(label)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 30)
                .background(keyShape(special: true, active: false))
                .foregroundColor(.primary)
        }
        .buttonStyle(KeyCapStyle(feedback: settings.keyPressFeedback, popLabel: nil))
    }

    // MARK: behavior

    private func press(_ k: KeyDef) {
        switch k.kind {
        case .key(let code): fire(code, letter: isLetter(k.label))
        case .shift: shift.toggle()
        case .caps: caps.toggle()
        case .mod(let id): if mods.contains(id) { mods.remove(id) } else { mods.insert(id) }
        }
    }

    /// Post the keystroke with sticky modifiers; shift is one-shot, caps persists.
    private func fire(_ code: CGKeyCode, letter: Bool) {
        var f: CGEventFlags = []
        if mods.contains("cmd") { f.insert(.maskCommand) }
        if mods.contains("alt") { f.insert(.maskAlternate) }
        if mods.contains("ctrl") { f.insert(.maskControl) }
        if mods.contains("fn") { f.insert(.maskSecondaryFn) }
        if shift || (letter && caps) { f.insert(.maskShift) }
        Pointer.keyFlagged(code, f)
        if !mods.isEmpty { mods.removeAll() }
        if shift { shift = false }
    }

    private func isLetter(_ s: String) -> Bool {
        s.count == 1 && s.rangeOfCharacter(from: .letters) != nil
    }

    private func display(_ k: KeyDef) -> String {
        if let sh = k.shifted, shift { return sh }
        if isLetter(k.label) && (shift || caps) { return k.label.uppercased() }
        return k.label
    }

    private func isSpecial(_ k: KeyDef) -> Bool {
        switch k.kind {
        case .key(let c): return c == 51 || c == 48 || c == 36 || c == 49
            || c == 123 || c == 124 || c == 125 || c == 126
        default: return true
        }
    }

    private func isActive(_ k: KeyDef) -> Bool {
        switch k.kind {
        case .shift: return shift
        case .caps: return caps
        case .mod(let id): return mods.contains(id)
        case .key: return false
        }
    }

    private func keyShape(special: Bool, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: GC.Radius.key)
            .fill(active ? Color.accentColor
                         : Color(nsColor: .controlColor).opacity(special ? 0.55 : 1.0))
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
    }
}

/// iOS-style key press feedback. On touch-down: a brightness highlight + a
/// slight dip (scale 0.94), springing back on release. For letter keys, an
/// optional magnified key-pop callout floats just above the key while held,
/// so the keycap stays visible under the fingertip.
struct KeyCapStyle: ButtonStyle {
    var feedback: Bool
    var popLabel: String?

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(feedback && pressed ? 0.94 : 1.0)
            .brightness(feedback && pressed ? 0.12 : 0.0)
            .overlay(alignment: .top) {
                if let popLabel, pressed {
                    KeyPopCallout(text: popLabel)
                        .offset(y: -46)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
            .zIndex(pressed ? 1 : 0)   // pop draws above neighbours
    }
}

/// The magnified keycap bubble shown above a held letter key.
private struct KeyPopCallout: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .regular))
            .foregroundColor(.primary)
            .frame(width: 44, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
