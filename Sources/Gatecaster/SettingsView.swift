import SwiftUI
import AppKit
import ServiceManagement
import IOKit.hid

// MARK: - reusable touch-friendly components

/// A tappable ⓘ that reveals an explanation popover (works on touch, unlike hover).
private struct InfoButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .popover(isPresented: $show) {
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let info: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13))
            InfoButton(text: info)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 3)
    }
}

private struct SliderRow: View {
    let title: String
    let info: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var decimals: Int = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium))
                InfoButton(text: info)
                Spacer()
                Text(String(format: "%.\(decimals)f%@", value, unit))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 3)
    }
}

/// Start-at-login toggle backed by SMAppService (macOS 13+). The system owns
/// this state (not our settings file), so we read/refresh status directly.
/// Registration only works when running as Gatecaster.app — the bare
/// swift-build binary has no bundle identity, so we surface that inline.
private struct LaunchAtLoginRow: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Start at login").font(.system(size: 13))
                InfoButton(text: "Launch Gatecaster automatically when you log in, so the touchscreen works right away. Requires running the app bundle (Gatecaster.app) — build it with scripts/make-app.sh.")
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { apply($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
    private func apply(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else   { try SMAppService.mainApp.unregister() }
            errorText = nil
        } catch {
            errorText = Bundle.main.bundleIdentifier == nil
                ? "Needs the app bundle — build with scripts/make-app.sh and run Gatecaster.app."
                : "Couldn't update: \(error.localizedDescription)"
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

extension Notification.Name {
    static let gcReconnectTouch = Notification.Name("gc.reconnectTouch")
    static let gcDeckFullScreen = Notification.Name("gc.deckFullScreen")
}

/// Live permission checklist — the pattern popularized by Rectangle / AltTab:
/// per-permission status (polled; TCC has no change notification), a Grant
/// button that triggers the system prompt, a deep link into the exact
/// System Settings pane, and Relaunch (TCC grants apply on next launch).
private struct PermissionsView: View {
    @State private var axGranted = AXIsProcessTrusted()
    @State private var inputGranted =
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(name: "Accessibility",
                detail: "Lets Gatecaster move the pointer, click, and post gestures.",
                granted: axGranted,
                grant: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                                as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                },
                pane: "Privacy_Accessibility")
            Divider()
            row(name: "Input Monitoring",
                detail: "Lets Gatecaster read raw touch reports from the USB controller.",
                granted: inputGranted,
                grant: { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) },
                pane: "Privacy_ListenEvent")

            if !(axGranted && inputGranted) {
                Divider()
                HStack(spacing: 8) {
                    Text("Grants take effect after a relaunch.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button("Relaunch Gatecaster") { relaunch() }
                        .font(.system(size: 12))
                }
            }
        }
        .onReceive(poll) { _ in
            axGranted = AXIsProcessTrusted()
            inputGranted =
                IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    private func row(name: String, detail: String, granted: Bool,
                     grant: @escaping () -> Void, pane: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(granted ? "Granted" : detail)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Grant…") { grant() }.font(.system(size: 12))
                Button("Open Settings") { openPane(pane) }.font(.system(size: 12))
            }
        }
        .padding(.vertical, 3)
    }

    private func openPane(_ pane: String) {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Spawn a fresh instance, then quit. Works bundled (`open -n App.app`)
    /// and unbundled (exec the bare binary).
    private func relaunch() {
        let bundle = Bundle.main.bundlePath
        let p = Process()
        if bundle.hasSuffix(".app") {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", bundle]
        } else if let exe = Bundle.main.executablePath {
            p.executableURL = URL(fileURLWithPath: exe)
        } else { return }
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.10)))
    }
}

// MARK: - main settings view (System Settings-style: sidebar + detail)

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onCalibrate: () -> Void
    var onChooseDisplay: () -> Void
    var onToggleKeyboard: () -> Void
    @State private var section: String? = "pointer"
    @State private var screenToken = 0      // bumped on hotplug to refresh the list

    private let sections: [(id: String, icon: String, color: Color, title: String)] = [
        ("general",   "gearshape",                        .gray,   "General"),
        ("pointer",   "cursorarrow",                      .blue,   "Pointer & Scroll"),
        ("gestures",  "hand.tap",                         .purple, "Gestures"),
        ("rightclick","cursorarrow.click.2",              .orange, "Right-click"),
        ("keyboard",  "keyboard",                         .gray,   "Keyboard"),
        ("trackpad",  "rectangle.and.hand.point.up.left", .teal,   "Trackpad"),
        ("edges",     "hand.draw",                        .indigo, "Edges & Launcher"),
        ("display",   "display",                          .green,  "Display"),
        ("advanced",  "slider.horizontal.3",              .gray,   "Advanced"),
        ("about",     "info.circle",                      .blue,   "About"),
    ]

    // System Settings-style: NavigationSplitView + sidebar List (HIG "Sidebars").
    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(sections.indices, id: \.self) { i in
                    Label {
                        Text(sections[i].title).font(.system(size: 12))
                    } icon: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(sections[i].color)
                            Image(systemName: sections[i].icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 24, height: 24)
                    }
                    .tag(sections[i].id)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 195, ideal: 215)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sectionTitle)
                        .font(.system(size: 20, weight: .bold))
                    detail
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(sectionTitle)
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 560, idealHeight: 660)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenToken += 1
        }
    }

    private var sectionTitle: String {
        sections.first(where: { $0.id == section })?.title ?? "Pointer & Scroll"
    }

    @ViewBuilder private var detail: some View {
        switch section ?? "pointer" {
        case "general":    generalSection
        case "gestures":   gesturesSection
        case "rightclick": rightClickSection
        case "keyboard":   keyboardSection
        case "trackpad":   trackpadSection
        case "edges":      edgesSection
        case "display":    displaySection
        case "advanced":   advancedSection
        case "about":      aboutSection
        default:           pointerSection
        }
    }

    // MARK: sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(title: "Startup") {
                LaunchAtLoginRow()
            }
            Card(title: "Permissions") {
                PermissionsView()
            }
            Card(title: "Appearance") {
                ToggleRow(title: "Blur panel backgrounds", isOn: $settings.panelBlur,
                          info: "On: the keyboard, trackpad, and deck blur whatever is behind them (live glass). Off: a flat translucent background instead — lighter on the GPU and battery, and avoids occasional macOS glass glitches.")
                if !settings.panelBlur {
                    SliderRow(title: "Panel opacity",
                              info: "How solid the flat panel background is when blur is off.",
                              value: $settings.keyboardOpacity,
                              range: 0.3...1.0, step: 0.05, decimals: 2)
                }
            }
            Card(title: "Touchscreen") {
                let connected = !settings.connectedHardware.isEmpty
                    && settings.connectedHardware != "Not connected"
                HStack(spacing: 8) {
                    Image(systemName: connected
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(connected ? .green : .orange)
                        .font(.system(size: 14))
                    Text(connected
                         ? settings.connectedHardware : "No touch controller detected")
                        .font(.system(size: 13))
                    Spacer()
                    Button("Reconnect") {
                        NotificationCenter.default.post(name: .gcReconnectTouch, object: nil)
                    }
                    .font(.system(size: 12))
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var pointerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            pointerCard
            Card(title: "Palm rejection") {
                ToggleRow(title: "Palm rejection", isOn: $settings.palmRejection,
                          info: "Ignore palm-like contacts: several touches bunched tighter than any finger spread (the heel of your hand) are rejected until they lift. Makes typing and trackpad use feel much more responsive.")
                if settings.palmRejection {
                    ToggleRow(title: "Guard while typing", isOn: $settings.palmPanelGuard,
                              info: "While a finger is on the on-screen keyboard or virtual trackpad, new touches landing elsewhere (your resting hand) are ignored until they lift.")
                    SliderRow(title: "Palm size",
                              info: "How tightly bunched touches must be to count as a palm. Three or more contacts within this radius are rejected. Lower if 3-finger gestures get eaten; raise if palms still click.",
                              value: $settings.palmClusterPts,
                              range: 30...120, step: 2, unit: " pt")
                }
            }
        }
    }

    private var pointerCard: some View {
        Card(title: "Pointer & scroll") {
            ToggleRow(title: "One-finger scroll (iPad mode)", isOn: $settings.ipadMode,
                      info: "When on, dragging one finger scrolls the content (like iPadOS). When off, one finger moves the pointer and drags.")
            ToggleRow(title: "Natural scroll direction", isOn: $settings.naturalScroll,
                      info: "Content tracks your fingers (push up → content moves up). Applies to both one- and two-finger scrolling.")
            ToggleRow(title: "Inertial scrolling", isOn: $settings.inertia,
                      info: "A quick flick keeps coasting after you lift, with momentum, like a trackpad.")
            ToggleRow(title: "Return cursor after touch", isOn: $settings.restoreCursor,
                      info: "After a tap, snap the pointer back to where it was, so the touchscreen doesn't strand your mouse cursor. Scrolling and dragging keep the cursor where you left it.")
            ToggleRow(title: "Verbose logging", isOn: $settings.verbose,
                      info: "Print finger-count and diagnostic info to the console. Useful when debugging panel dropouts.")
        }
    }

    private var gesturesSection: some View {
        Card(title: "Gestures") {
            HStack(spacing: 8) {
                Text("Engine").font(.system(size: 13, weight: .medium))
                InfoButton(text: "Smooth synthesizes real trackpad events (animated zoom & rotate). Legacy fires keyboard shortcuts instead — less pretty, but works in every app and can switch desktops. Off = scrolling only.")
                Spacer()
            }
            Picker("", selection: $settings.gestureMode) {
                ForEach(GestureMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(settings.gestureMode.caption)
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.gestureMode != .off {
                Divider().padding(.vertical, 2)
                ToggleRow(title: "Three-finger gestures", isOn: $settings.threeFingerEnabled,
                          info: "Three fingers: up = Mission Control, down = App Exposé, left/right = switch desktops (Spaces). Driven by keyboard shortcuts in both engines.")
                gestureMap
            }
        }
    }

    private var rightClickSection: some View {
        Card(title: "Right-click") {
            HStack(spacing: 8) {
                Text("Trigger").font(.system(size: 13, weight: .medium))
                InfoButton(text: "How to produce a right-click. \"Touch & hold\": press one still finger. \"2-finger tap\": tap two fingers together — this also includes hold + 2nd tap. \"Hold + 2nd tap\": keep one finger down and tap a second finger, MacBook-style — and ONLY that. \"All\" enables everything. The virtual trackpad always supports the second-finger tap.")
                Spacer()
            }
            Picker("", selection: $settings.rightClickMode) {
                ForEach(RightClickMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            
            .labelsHidden()
        }
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // banner: the OS, not the keycaps, decides what typing produces
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 18)).foregroundColor(.accentColor)
                    Text("Typing language comes from macOS, not from the keycaps")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Gatecaster presses key positions; macOS converts them using your active input source — including the Chinese and Japanese IMEs. Choose a keycap layout below, then add the matching language to macOS so what you type matches what you see.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.keyboard?Input%20Sources") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Add a language in macOS Input Sources…", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))

            keyboardCard
        }
    }

    private var keyboardCard: some View {
        Card(title: "On-screen keyboard") {
            HStack(spacing: 8) {
                Text("Keyboard layout").font(.system(size: 13, weight: .medium))
                InfoButton(text: "Keycap labels only — macOS translates keys through your ACTIVE input source, so pick the layout matching it (System Settings → Keyboard → Input Sources). Chinese (Pinyin) and Japanese (Romaji) type through their IMEs over QWERTY keycaps.")
                Spacer()
                Picker("", selection: $settings.keyboardLayout) {
                    ForEach(KeyboardLayouts.options.indices, id: \.self) { i in
                        Text(KeyboardLayouts.options[i].name)
                            .tag(KeyboardLayouts.options[i].id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            ToggleRow(title: "Function & modifier keys", isOn: $settings.keyboardExtendedKeys,
                      info: "Adds esc + F1–F12 and sticky ⌘ ⌥ ⌃ fn keys. Tap a modifier, then a key, to send the combo (e.g. ⌘ then C = copy).")
            ToggleRow(title: "Numeric keypad", isOn: $settings.keyboardNumpad,
                      info: "Adds a numpad column on the right of the keyboard, with real keypad keycodes.")
            ToggleRow(title: "Key press feedback", isOn: $settings.keyPressFeedback,
                      info: "iOS-style press feedback: keys highlight and dip slightly when tapped, so it's clear the press registered.")
            ToggleRow(title: "Key-pop callout", isOn: $settings.keyPopup,
                      info: "Shows a magnified bubble of the letter just above the key while you hold it — like iOS — so your finger doesn't hide what you typed.")
            SliderRow(title: "Keyboard transparency",
                      info: "How see-through the on-screen keyboard is. Lower = more transparent.",
                      value: $settings.keyboardOpacity, range: 0.3...1.0, step: 0.05, decimals: 2)
            Button(action: onToggleKeyboard) {
                Label("Show / hide keyboard", systemImage: "keyboard")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            Text("The keyboard snaps to the bottom of the touchscreen. Its ⌄ button collapses it to a pull tab — tap the tab to bring it back.")
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private var trackpadSection: some View {
        Card(title: "Virtual trackpad") {
            ToggleRow(title: "Virtual trackpad", isOn: $settings.showTrackpad,
                      info: "A floating trackpad panel: move the cursor with one finger (relative, like a real trackpad), tap to click, two-finger scroll with inertia, second-finger tap for right click, pinch & rotate gestures. Drag by the top bar, resize with the corner bean.")
            SliderRow(title: "Trackpad sensitivity",
                      info: "How far the cursor moves per finger movement on the virtual trackpad.",
                      value: $settings.trackpadGain, range: 0.5...3.0, step: 0.1, decimals: 1)
        }
    }

    private var edgesSection: some View {
        Card(title: "Edge gestures & launcher") {
            ToggleRow(title: "Edge gestures", isOn: $settings.edgeGestures,
                      info: "Rest TWO fingers on the bottom strip, then pull up to open the on-screen keyboard (three fingers works too). Two fingers on the right strip, pull in (left) for Notification Center.")
            SliderRow(title: "Edge dwell",
                      info: "How long to rest your fingers at the edge before a pull counts. Higher = fewer accidental triggers, more deliberate.",
                      value: $settings.edgeDwellMS, range: 0...600, step: 25, unit: " ms")
            SliderRow(title: "Edge pull distance",
                      info: "How far to pull inward before the edge gesture fires.",
                      value: $settings.edgePull, range: 20...200, step: 10, unit: " px")
            SliderRow(title: "Edge zone size",
                      info: "Depth of the detection bands (the visible strips). The side band is 1.5× this. Bigger = easier to hit, but steals more screen edge.",
                      value: $settings.edgeZonePts, range: 20...120, step: 4, unit: " px")
            ToggleRow(title: "Floating control", isOn: $settings.showFloatingControl,
                      info: "A small draggable launcher you can tap to open the keyboard or trackpad, cycle the gesture engine, or open Settings. Collapse it to a thin tab on the screen edge with its chevron.")
        }
    }

    private var displaySection: some View {
        Card(title: "Display") {
            HStack(spacing: 8) {
                Text("Touchscreen display").font(.system(size: 13, weight: .medium))
                InfoButton(text: "Which screen the touch panel controls. Reconnect-safe: if it's unplugged the app falls back to the main display and rebinds automatically when it's plugged back in.")
                Spacer()
                Picker("", selection: displayBinding) {
                    ForEach(connectedDisplays(), id: \.id) { d in
                        Text(d.label).tag(d.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .id(screenToken)
            }
            HStack(spacing: 12) {
                Button(action: onChooseDisplay) {
                    Label("Identify by number…", systemImage: "number.square")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                Button(action: onCalibrate) {
                    Label("Calibrate…", systemImage: "scope")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            advancedTiming
            Button(role: .destructive) { settings.resetToDefaults() } label: {
                Label("Reset all to defaults", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.bordered)
            
            .padding(.top, 4)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "About") {
                HStack(spacing: 14) {
                    Text("👆").font(.system(size: 36))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gatecaster").font(.system(size: 18, weight: .bold))
                        Text("Version \(appVersion)")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                Text("A user-space macOS driver that turns an HID touchscreen into a full Mac input surface — pointer, momentum scrolling, native pinch-zoom and rotate, an on-screen keyboard and virtual trackpad.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                aboutRow("Touch controller", settings.connectedHardware)
                aboutRow("Gesture engine", settings.gestureMode.label)
            }
        }
    }

    private let appVersion = "0.9.0 (dev)"

    private func aboutRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(v).font(.system(size: 12)).foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: helpers

    private func connectedDisplays() -> [(id: UInt32, label: String)] {
        NSScreen.screens.compactMap { sc in
            guard let id = (sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? NSNumber)?.uint32Value else { return nil }
            return (id, "\(sc.localizedName) — \(Int(sc.frame.width))×\(Int(sc.frame.height))")
        }
    }

    private var displayBinding: Binding<UInt32> {
        Binding(get: { UInt32(max(0, settings.displayID)) },
                set: { settings.displayID = Double($0); settings.hasPickedDisplay = true })
    }

    private var sc: Bool { settings.gestureMode == .shortcuts }

    private var gestureMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What each gesture does")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                .textCase(.uppercase)
            mapRow("Pinch", sc ? "Zoom  (⌘+ / ⌘–)" : "Zoom  (animated)")
            mapRow("Rotate", sc ? "Rotate  (⌘L / ⌘R)" : "Rotate  (animated)")
            mapRow("Two-finger swipe ←→", sc ? "Back / Forward  (⌘[ / ⌘])" : "Back / Forward  (edge scroll)")
            if settings.threeFingerEnabled {
                mapRow("Three-finger ↑", "Mission Control")
                mapRow("Three-finger ↓", "App Exposé")
                mapRow("Three-finger ←→", "Switch desktops")
            }
        }
        .padding(.top, 4)
    }

    private func mapRow(_ gesture: String, _ action: String) -> some View {
        HStack {
            Text(gesture).font(.system(size: 12))
            Spacer()
            Text(action).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private var advancedTiming: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Tap & hold") {
                SliderRow(title: "Tap movement limit", info: "How far a finger may move and still count as a tap (not a drag).",
                          value: $settings.tapMaxMove, range: 4...40, step: 1, unit: " px")
                SliderRow(title: "Tap time limit", info: "Longest touch still treated as a tap.",
                          value: $settings.tapMaxMS, range: 100...400, step: 10, unit: " ms")
                SliderRow(title: "Movement threshold", info: "Pixels a finger must move before it counts as movement rather than a still touch.",
                          value: $settings.slop, range: 2...30, step: 1, unit: " px")
                SliderRow(title: "Hold for right-click", info: "How long to hold one still finger to trigger a right-click (when that mode is on).",
                          value: $settings.holdMS, range: 200...1200, step: 10, unit: " ms")
                SliderRow(title: "Drag settle delay", info: "A finger must persist this long before it commits to a drag, so a second finger landing a hair later starts a gesture instead of a stray click.",
                          value: $settings.touchSettleMS, range: 0...80, step: 5, unit: " ms")
            }
            Card(title: "Scrolling & inertia") {
                SliderRow(title: "One-finger inertia", info: "Coast speed after a one-finger flick. Higher = faster, longer glide.",
                          value: $settings.oneFingerInertiaGain, range: 0.5...6, step: 0.1, decimals: 1)
                SliderRow(title: "Two-finger inertia", info: "Coast speed after a two-finger flick.",
                          value: $settings.momentumGain, range: 0.5...5, step: 0.1, decimals: 1)
                SliderRow(title: "Glide length (friction)", info: "How slowly momentum decays. Higher = the coast lasts longer.",
                          value: $settings.friction, range: 0.85...0.99, step: 0.005, decimals: 3)
                SliderRow(title: "Flick threshold", info: "Minimum release speed that starts a coast. Lower = easier to fling.",
                          value: $settings.flickMin, range: 5...150, step: 5, unit: " px/s")
                SliderRow(title: "Stop speed", info: "Momentum stops once it slows below this.",
                          value: $settings.stopMin, range: 5...60, step: 1, unit: " px/s")
            }
            Card(title: "Gestures") {
                SliderRow(title: "Pinch sensitivity", info: "How strongly finger spread maps to zoom.",
                          value: $settings.magnifyGain, range: 1...6, step: 0.1, decimals: 1)
                SliderRow(title: "Gesture commit", info: "How far two fingers travel before the engine locks in scroll vs. pinch vs. rotate.",
                          value: $settings.twoCommit, range: 4...30, step: 1, unit: " px")
                SliderRow(title: "Scroll-vs-pinch bias", info: "How much a pinch must out-move a scroll to win. Higher favors scrolling (fewer accidental zooms).",
                          value: $settings.pinchBias, range: 1...3, step: 0.1, decimals: 1)
                SliderRow(title: "Page-swipe distance", info: "Smooth mode: how far a horizontal two-finger swipe must travel to commit Safari back/forward (⌘[ / ⌘]) on release. Lower = easier to trigger.",
                          value: $settings.pageSwipePts, range: 40...300, step: 10, unit: " px")
            }
            Card(title: "Robustness & cursor") {
                SliderRow(title: "Lift timeout", info: "Silence from the panel before assuming you lifted. Higher tolerates more dropouts but adds latency.",
                          value: $settings.liftTimeout, range: 0.03...0.15, step: 0.005, unit: " s", decimals: 3)
                SliderRow(title: "Velocity window", info: "Time window used to measure flick speed at release.",
                          value: $settings.velWindow, range: 0.03...0.15, step: 0.01, unit: " s", decimals: 2)
                SliderRow(title: "Velocity max age", info: "Ignore a release velocity older than this (guards against stale samples after a dropout).",
                          value: $settings.velMaxAge, range: 0.08...0.4, step: 0.01, unit: " s", decimals: 2)
                SliderRow(title: "Cursor return delay", info: "Quiet time after the last action before the pointer snaps back (only for taps).",
                          value: $settings.restoreDelayMS, range: 0...500, step: 10, unit: " ms")
            }
        }
    }
}
