import Cocoa
import CoreGraphics
import SwiftUI
import Combine
import IOKit.hid

final class AppController: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let engine = Engine()
    let hid = HidTouch()
    let capture = Capture()
    let api = TouchAPIServer()
    var statusItem: NSStatusItem!

    private var settingsWindow: NSWindow?
    private var calibrationWindow: NSWindow?
    private var calController: CalibrationController?
    private var onboarding: OnboardingController?
    private var selectedDisplay = CGMainDisplayID()
    private var pickerWindows: [NSWindow] = []
    private var keyMonitor: Any?
    private var displayBag: AnyCancellable?
    private var floatBag: AnyCancellable?
    private var numpadBag: AnyCancellable?
    private var edgeBag: AnyCancellable?
    private var zoneBag: AnyCancellable?
    private var edgeHintPanels: [NSPanel] = []
    private let edgeStates = EdgeZoneStates()
    private var keyboardPanel: NSPanel?
    private var floatingPanel: NSPanel?
    private var trackpadPanel: NSPanel?
    private var padBag: AnyCancellable?
    private var deckPanel: NSPanel?
    private var deckBag: AnyCancellable?
    // Pre-full-screen deck frame, kept in a dedicated ivar (NOT the persisted
    // panelFrames["deck"] slot) because the didResize→settleFrame observer would
    // otherwise overwrite that slot with the full-screen frame, so toggling
    // full-screen OFF would "restore" to full size. Non-nil ⇔ deck is full-screen.
    private var deckFullScreenRestore: NSRect?

    func applicationDidFinishLaunching(_ note: Notification) {
        // SINGLE INSTANCE: two engines fighting over the same HID device put the
        // cursor on the wrong display and double-post events. The fresh launch
        // wins — older instances are told to quit (covers `open -n` relaunches
        // and leftover dev builds).
        if let bid = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            where app.processIdentifier != me {
                app.terminate()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "👆"
        rebuildMenu()
        observeSettingsRequests()

        // Permission prompting now lives in onboarding's Permissions step;
        // just log so a headless launch isn't silently dead.
        if !AXIsProcessTrusted() {
            FileHandle.standardError.write(
                Data("[gatecaster] waiting for Accessibility permission…\n".utf8))
        }

        hid.onReport = { [weak self] bytes in self?.engine.onReport(bytes) }
        hid.onDeviceInfo = { [weak self] info in
            DispatchQueue.main.async { self?.settings.connectedHardware = info ?? "Not connected" }
        }
        engine.isOverPanel = { [weak self] cgPoint in self?.pointIsOverPanel(cgPoint) ?? false }
        engine.onPanelDragBegan = { [weak self] cg in self?.beginPanelDrag(at: cg) ?? false }
        engine.onPanelDragMoved = { [weak self] cg in self?.movePanelDrag(to: cg) }
        engine.onPanelDragEnded = { [weak self] in
            guard let self = self else { return }
            if let p = self.draggedPanel { self.settleFrame(p) }  // clamp/collapse once, now
            self.draggedPanel = nil
        }
        engine.trackpadRect = { [weak self] in self?.trackpadActiveRect() }
        engine.deckScrollAt = { [weak self] cg in self?.deckScrollRegion(cg) ?? false }
        engine.onShowKeyboard = { [weak self] in DispatchQueue.main.async { self?.toggleKeyboard() } }
        engine.onNotificationCenter = { [weak self] in
            DispatchQueue.main.async { self?.openNotificationCenter() }
        }

        // Touch API: stream this frame's contacts / gestures to any connected
        // third-party client, and let a client suppress our own input injection.
        engine.onTouchFrame = { [weak self] raw, accepted in
            self?.api.publishFingers(raw: raw, accepted: accepted)
        }
        engine.onGesture = { [weak self] g in self?.api.publishGesture(g) }
        api.onSuppress = { [weak self] input, gestures, edges in
            Pointer.suppressInput = input
            GestureSynth.suppressGestures = gestures
            self?.engine.apiSuppressEdges = edges
        }

        engine.start()
        hid.start()
        api.start()

        // First-run (or resumed) onboarding replaces the bare display picker.
        // Existing users with everything granted never see it (hasOnboarded is
        // migrated from hasPickedDisplay). Existing users MISSING a permission
        // get dropped directly on the Permissions step — no intro, no welcome.
        let permissionsOK = AXIsProcessTrusted() &&
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !settings.hasOnboarded {
            // Mid-flow relaunch (TCC grant) resumes at the persisted stage.
            let resume = settings.onboardingStage > 0
                ? OnboardingStage(rawValue: settings.onboardingStage) : nil
            startOnboarding(resumeAt: resume)
        } else if !permissionsOK {
            startOnboarding(resumeAt: .permissions)
        } else {
            resolveSavedDisplay()
        }

        // Apply the chosen display whenever it changes from the Settings dropdown,
        // and record its stable uuid so the choice survives the next launch.
        displayBag = settings.$displayID.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] id in
                guard let self = self else { return }
                let cgid = CGDirectDisplayID(id)
                self.applyDisplay(cgid)
                if let u = self.uuid(for: cgid) { self.settings.displayUUID = u }
            }

        // Recover gracefully when displays are unplugged/replugged: re-resolve the
        // chosen display (rebinds when it returns, falls back to main when it's gone).
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Keep Gatecaster's touch UI (keyboard / trackpad / launcher) inside the
        // touch display: clamp on every move and resize.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelFrameChanged(_:)),
            name: NSWindow.didMoveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelFrameChanged(_:)),
            name: NSWindow.didResizeNotification, object: nil)

        // Defer the launcher past onboarding: it's a .floating panel and would pop
        // OVER the .normal-level onboarding window (the vortex). onFinished shows it
        // once setup completes; already-onboarded launches (onboarding == nil) show now.
        if settings.showFloatingControl && onboarding == nil { showFloatingControl() }
        floatBag = settings.$showFloatingControl.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] on in
                if on { self?.showFloatingControl() } else { self?.hideFloatingControl() }
                self?.rebuildMenu()
            }
        if settings.showTrackpad { showTrackpad() }
        padBag = settings.$showTrackpad.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] on in
                if on { self?.showTrackpad() } else { self?.hideTrackpad() }
                self?.rebuildMenu()
            }
        if settings.showDeck { showDeck() }
        deckBag = settings.$showDeck.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] on in
                if on { self?.showDeck() } else { self?.hideDeck() }
                self?.rebuildMenu()
            }
        // Visual strips marking the edge-gesture zones (pure affordance; pass-through),
        // with live state: fingers detected → lighter blue, armed → black.
        engine.onEdgeZoneState = { [weak self] bottomZone, st in
            DispatchQueue.main.async {
                if bottomZone { self?.edgeStates.bottom = st } else { self?.edgeStates.right = st }
            }
        }
        refreshEdgeHints()
        edgeBag = settings.$edgeGestures.dropFirst().receive(on: RunLoop.main)
            .merge(with: settings.$showEdgeZones.dropFirst())
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshEdgeHints() } }
        // Resize the strips live when the zone-size slider moves.
        zoneBag = settings.$edgeZonePts.dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshEdgeHints() }

        // Toggling the numpad while the keyboard is open: re-expand so the panel
        // WIDENS for the extra column instead of squishing the main keys.
        numpadBag = settings.$keyboardNumpad.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, let p = self.keyboardPanel,
                      p.frame.width > 300 else { return }   // expanded, not the tab
                self.expandKeyboard()
            }

        // global hotkey: ⌃⌥⌘C toggles the gesture-capture learning tool
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            let mods: NSEvent.ModifierFlags = [.control, .option, .command]
            guard ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == mods,
                  ev.keyCode == 8 else { return }
            self?.toggleCapture()
        }
    }

    // MARK: status menu (kept minimal — everything lives in the Settings window)
    private func rebuildMenu() {
        let menu = NSMenu()    // default system font — the menu is mouse-driven;
                               // touch-friendly controls live in the floating UI
        menu.addItem(NSMenuItem(title: "Gatecaster — active", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        item(menu, "Settings…", #selector(openSettings))
        // Pro status / unlock entry point.
        if settings.proUnlocked {
            let pro = NSMenuItem(
                title: settings.licensedTo.isEmpty ? "Gatecaster Pro ✓"
                                                   : "Gatecaster Pro ✓ — \(settings.licensedTo)",
                action: nil, keyEquivalent: "")
            pro.isEnabled = false
            menu.addItem(pro)
        } else {
            item(menu, "Unlock Pro…", #selector(promptForLicense))
        }
        item(menu, "Show / Hide Touch Keyboard", #selector(toggleKeyboard))
        item(menu, "Show / Hide Virtual Trackpad", #selector(toggleTrackpad))
        item(menu, "Show / Hide Deck", #selector(toggleDeck))
        item(menu, "Show / Hide Floating Control", #selector(toggleFloatingControl))
        item(menu, "Choose Touchscreen Display…", #selector(startDisplayPicker))
        item(menu, "Calibrate Touchscreen…", #selector(startCalibration))
        item(menu, "Setup Assistant…", #selector(startSetupAssistant))
        item(menu, "Reconnect Touchscreen", #selector(reconnectTouch))

        menu.addItem(.separator())
        // Debug tools live in a submenu, off by default.
        let debugMenu = NSMenu()
        let dbg = { (title: String, sel: Selector, on: Bool) in
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            debugMenu.addItem(it)
        }
        dbg("Show edge-gesture zones", #selector(toggleEdgeZones), settings.showEdgeZones)
        // Hidden for now (developer-only): verbose logging + gesture capture.
        // dbg("Verbose logging", #selector(toggleVerboseLog), settings.verbose)
        // dbg("Capture trackpad gestures (learn format)", #selector(toggleCapture), capture.isRunning)
        let dbgItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        menu.addItem(dbgItem)
        menu.setSubmenu(debugMenu, for: dbgItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    // MARK: licensing (Pro unlock)
    // Where the $24 Pro license is purchased. Replace with the real checkout URL.
    private static let purchaseURL = URL(string: "https://gatecaster.app/buy")!

    /// Gate for a Pro-only feature. Returns true if Pro is unlocked; otherwise shows
    /// the paywall and returns false. Called at each feature's activation point (the
    /// Deck, on-screen keyboard, virtual trackpad) — never on the Engine's hot path.
    @discardableResult
    private func requirePro(_ feature: String) -> Bool {
        if settings.proUnlocked { return true }
        presentPaywall(feature: feature)
        return false
    }

    private func presentPaywall(feature: String) {
        let a = NSAlert()
        a.messageText = "\(feature) is a Gatecaster Pro feature"
        a.informativeText = """
            The driver, gestures, and Touch API are free. The Deck, on-screen \
            keyboard, and virtual trackpad are part of Gatecaster Pro — a one-time \
            $24 unlock.

            Already bought it? Enter your license key to unlock.
            """
        a.addButton(withTitle: "Buy Pro…")
        a.addButton(withTitle: "Enter License…")
        a.addButton(withTitle: "Not Now")
        switch a.runModal() {
        case .alertFirstButtonReturn:  NSWorkspace.shared.open(Self.purchaseURL)
        case .alertSecondButtonReturn: promptForLicense()
        default: break
        }
    }

    /// Prompt for a license key, verify it, and persist on success. Invalid keys
    /// report back so a typo is visible rather than silently ignored.
    @objc private func promptForLicense() {
        let a = NSAlert()
        a.messageText = "Enter your Gatecaster Pro license key"
        a.informativeText = "Paste the key from your purchase email."
        a.addButton(withTitle: "Unlock")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "license key"
        field.stringValue = settings.licenseKey
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if License.verify(key)?.tier == .pro {
            settings.licenseKey = key      // didSet flips proUnlocked; autosave persists it
            rebuildMenu()
            let ok = NSAlert()
            ok.messageText = "Gatecaster Pro unlocked"
            if !settings.licensedTo.isEmpty { ok.informativeText = "Licensed to \(settings.licensedTo)." }
            ok.runModal()
        } else {
            let bad = NSAlert()
            bad.alertStyle = .warning
            bad.messageText = "That license key isn't valid"
            bad.informativeText = "Check for a copy/paste error, or contact support."
            bad.runModal()
        }
    }

    // MARK: display binding & hotplug recovery
    /// Point the engine at a display id, falling back to the main display if that
    /// id isn't currently connected (the saved preference is kept either way).
    private func applyDisplay(_ id: CGDirectDisplayID) {
        if id != 0, nsScreen(for: id) != nil {
            selectedDisplay = id
            engine.bounds = CGDisplayBounds(id)
        } else {
            selectedDisplay = CGMainDisplayID()
            engine.bounds = CGDisplayBounds(selectedDisplay)
        }
        clampAllPanels()    // touch UI follows the touch display
        refreshEdgeHints()  // reposition strips too
        // Keep the Touch API's advertised geometry in sync with the active display
        // + calibration, so a client's hello carries the right screen/panel bounds.
        api.updateGeometry(screen: engine.bounds,
                           cal: (settings.calXMin, settings.calXMax,
                                 settings.calYMin, settings.calYMax))
    }

    // MARK: edge-zone hint strips (DEBUG visual only; mouse events pass through)
    private func refreshEdgeHints() {
        if settings.edgeGestures && settings.showEdgeZones { showEdgeHints() }
        else { hideEdgeHints() }
    }

    private func showEdgeHints() {
        hideEdgeHints()
        guard let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame else { return }
        // DEBUG: cover the FULL detection bands the Engine uses, so they're
        // visually verifiable. Depth = "Edge zone size" setting; the side band
        // is 1.5× deeper. Shrink to thin strips once tuned.
        let d = CGFloat(settings.edgeZonePts)
        let bottom = NSRect(x: sf.minX, y: sf.minY, width: sf.width, height: d)
        let right  = NSRect(x: sf.maxX - d * 1.5, y: sf.minY, width: d * 1.5, height: sf.height)
        for (rect, horizontal) in [(bottom, true), (right, false)] {
            let panel = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true       // affordance only — never intercepts
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = GlassHostingView(rootView: EdgeHintView(horizontal: horizontal,
                                                            states: edgeStates))
            host.frame = NSRect(origin: .zero, size: rect.size)
            panel.contentView = host
            panel.orderFrontRegardless()
            edgeHintPanels.append(panel)
        }
    }

    private func hideEdgeHints() {
        edgeHintPanels.forEach { $0.orderOut(nil) }
        edgeHintPanels.removeAll()
    }

    @objc private func screensChanged() {
        // Re-resolve by stable uuid: rebinds the touchscreen when it reconnects,
        // falls back to main while it's gone.
        if let id = displayID(forUUID: settings.displayUUID) { applyDisplay(id) }
        else { applyDisplay(CGMainDisplayID()) }
        onboarding?.screensChanged()        // monitor step refreshes rows + badges
    }

    // MARK: keep touch UI on the touch display
    private var settleScheduled = false

    /// Panel frame changes — animation DISABLED for now (user preference).
    /// If re-enabling: use `animator()` in an NSAnimationContext, NEVER
    /// `setFrame(animate: true)` — that spins a nested run loop on the main
    /// thread (the thread processing our HID input) and can wedge all input.
    private func setFrameAnimated(_ w: NSWindow, _ rect: NSRect) {
        w.setFrame(rect, display: true)
    }

    @objc private func panelFrameChanged(_ note: Notification) {
        guard let w = note.object as? NSWindow, isTouchPanel(w) else { return }
        guard draggedPanel == nil else { return }   // engine drag settles on its own end
        // NEVER adjust frames synchronously from didMove/didResize — fighting the
        // window server's live drag session frame-by-frame can wedge it (and it
        // then eats all pointer input). Coalesce and settle after the drag ends.
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak w] in
            self?.settleScheduled = false
            if let w = w { self?.settleFrame(w) }
        }
    }

    /// After a drag has settled: collapse if hanging off a side edge, else clamp.
    private func settleFrame(_ w: NSWindow) {
        guard isTouchPanel(w),
              let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame else { return }
        let overOut = max(sf.minX - w.frame.minX, w.frame.maxX - sf.maxX)
        if overOut > 40, w.frame.width > 240 {         // tabs (≤220 wide) never re-collapse
            if w === floatingPanel { collapseFloating() }
            else if w === keyboardPanel { collapseKeyboardToTab() }
            else if w === trackpadPanel { collapseTrackpadToTab() }
        } else {
            clampToTouchDisplay(w)
        }
        saveFrame(w)
    }

    private func isTouchPanel(_ w: NSWindow) -> Bool {
        w === keyboardPanel || w === floatingPanel || w === trackpadPanel || w === deckPanel
    }

    // MARK: panel frame persistence (size + position survive relaunch)
    private func panelKey(for w: NSWindow) -> String? {
        if w === keyboardPanel { return "keyboard" }
        if w === trackpadPanel { return "trackpad" }
        if w === deckPanel { return "deck" }
        if w === floatingPanel { return "floating" }
        return nil
    }
    private func saveFrame(_ w: NSWindow) {
        guard let key = panelKey(for: w), w.frame.width > 240 else { return }  // skip collapsed tabs
        // Don't persist the deck while it's full-screen — that frame belongs in the
        // dedicated restore ivar, not the slot we reopen the deck at. (The toggle's
        // own restore-branch saveFrame still records the non-full frame.)
        if w === deckPanel, deckFullScreenRestore != nil { return }
        settings.panelFrames[key] = NSStringFromRect(w.frame)
    }
    /// Saved frame for a panel, clamped onto the touch display, or nil.
    private func savedFrame(_ key: String) -> NSRect? {
        guard let s = settings.panelFrames[key] else { return nil }
        let r = NSRectFromString(s)
        return (r.width > 40 && r.height > 40) ? r : nil
    }

    private func clampAllPanels() {
        for p in [keyboardPanel, floatingPanel, trackpadPanel, deckPanel].compactMap({ $0 }) {
            clampToTouchDisplay(p)
        }
    }

    private func clampToTouchDisplay(_ w: NSWindow) {
        guard let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame else { return }
        var f = w.frame
        f.size.width = min(f.width, sf.width)
        f.size.height = min(f.height, sf.height)
        f.origin.x = min(max(f.origin.x, sf.minX), sf.maxX - f.width)
        f.origin.y = min(max(f.origin.y, sf.minY), sf.maxY - f.height)
        if f != w.frame { w.setFrame(f, display: true) }
    }

    // MARK: settings window
    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings,
                                    onCalibrate: { [weak self] in self?.startCalibration() },
                                    onChooseDisplay: { [weak self] in self?.startDisplayPicker() },
                                    onToggleKeyboard: { [weak self] in self?.toggleKeyboard() })
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "Gatecaster — Settings"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 820, height: 660))
            win.center()
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: on-screen keyboard (snaps to the bottom; collapses to a pull tab)
    @objc private func toggleKeyboard() {
        if keyboardPanel != nil { hideKeyboard() } else { showKeyboard() }
    }

    private func hideKeyboard() { keyboardPanel?.orderOut(nil); keyboardPanel = nil }

    private func showKeyboard() {
        guard keyboardPanel == nil else { return }
        guard requirePro("The on-screen keyboard") else { return }
        // Non-activating panel: tapping a key never steals focus from the app you're typing into.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 360),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false    // title-bar handle only (see TitleBarDrag); bg-drag moved the panel under sliders
        // Show over the active Space and over full-screen apps, even though we're accessory.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        keyboardPanel = panel
        expandKeyboard()
        panel.orderFrontRegardless()
    }

    private func expandKeyboard() {
        guard let panel = keyboardPanel else { return }
        let view = KeyboardView(settings: settings) { [weak self] in self?.collapseKeyboardToTab() }
        let host = GlassHostingView(rootView: view)
        let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame ?? engine.bounds
        // Numpad ADDS width (main keys keep their size): 820 / 0.78 ≈ 1060.
        let w: CGFloat = settings.keyboardNumpad ? 1060 : 820
        let h: CGFloat = 360
        let rect = NSRect(x: sf.midX - w / 2, y: sf.minY + 6, width: w, height: h)  // snap bottom
        host.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = host
        setFrameAnimated(panel, rect)
    }

    private func collapseKeyboardToTab() {
        guard let panel = keyboardPanel else { return }
        let view = KeyboardTabView { [weak self] in self?.expandKeyboard() }
        let host = GlassHostingView(rootView: view)
        let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame ?? engine.bounds
        let rect = NSRect(x: sf.midX - 110, y: sf.minY + 2, width: 220, height: 52)
        host.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = host
        setFrameAnimated(panel, rect)
    }

    // MARK: floating control (draggable touch launcher; collapses to an edge tab)
    @objc private func toggleFloatingControl() { settings.showFloatingControl.toggle() }

    private func floatingScreenFrame() -> NSRect {
        (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame ?? engine.bounds
    }

    private func showFloatingControl() {
        guard floatingPanel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 160),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true        // drag the panel by its background
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel = panel
        expandFloating()
        panel.orderFrontRegardless()
    }

    private func hideFloatingControl() { floatingPanel?.orderOut(nil); floatingPanel = nil }

    // MARK: engine-driven panel move/resize (no synthetic mouse events involved)
    private enum PanelDragKind { case move, resize }
    private var draggedPanel: NSWindow?
    private var dragKind = PanelDragKind.move
    private var dragStartTouch = CGPoint.zero
    private var dragStartFrame = NSRect.zero

    private func beginPanelDrag(at cg: CGPoint) -> Bool {
        let flip = NSScreen.screens.first?.frame.maxY ?? 0
        for panel in [keyboardPanel, floatingPanel, trackpadPanel, deckPanel].compactMap({ $0 }) {
            let f = panel.frame
            let cgRect = CGRect(x: f.minX, y: flip - f.maxY, width: f.width, height: f.height)
            guard cgRect.contains(cg) else { continue }
            // Full panels (keyboard / trackpad) only drag from the TOP BAR —
            // touches below it pass through to the keys / pad surface.
            // Tabs and the floating launcher stay draggable anywhere.
            let isFullPanel = (panel === keyboardPanel || panel === trackpadPanel || panel === deckPanel)
                && f.width > 240
            let topBar = CGRect(x: cgRect.minX, y: cgRect.minY,
                                width: cgRect.width, height: 46)
            if isFullPanel, !topBar.contains(cg) { return false }
            draggedPanel = panel
            dragStartTouch = cg
            dragStartFrame = f
            // a drag starting in the bean zone (right side of the top bar)
            // resizes; the rest of the bar moves. Only full panels resize.
            let beanZone = CGRect(x: cgRect.maxX - 116, y: cgRect.minY, width: 72, height: 46)
            dragKind = (isFullPanel && beanZone.contains(cg)) ? .resize : .move
            return true
        }
        return false
    }

    private func movePanelDrag(to cg: CGPoint) {
        guard let panel = draggedPanel else { return }
        let dx = cg.x - dragStartTouch.x
        let dy = cg.y - dragStartTouch.y          // CG: +y is DOWN
        var f = dragStartFrame
        switch dragKind {
        case .move:
            f.origin.x += dx
            f.origin.y -= dy                      // AppKit: +y is UP
        case .resize:                             // top edge stays fixed; grow right/down
            let top = dragStartFrame.maxY
            f.size.width = max(300, dragStartFrame.width + dx)
            f.size.height = max(170, dragStartFrame.height + dy)
            f.origin.y = top - f.size.height
        }
        panel.setFrame(f, display: true)
    }

    /// Is a CG (top-left origin) point over the keyboard / trackpad / launcher?
    /// Converts each panel's AppKit (bottom-left) frame to CG coords to compare.
    private func pointIsOverPanel(_ p: CGPoint) -> Bool {
        let flip = NSScreen.screens.first?.frame.maxY ?? 0
        for panel in [keyboardPanel, floatingPanel, trackpadPanel, deckPanel].compactMap({ $0 }) {
            let f = panel.frame
            let cg = CGRect(x: f.minX, y: flip - f.maxY, width: f.width, height: f.height)
            if cg.contains(p) { return true }
        }
        return false
    }

    // MARK: virtual trackpad panel
    @objc private func toggleTrackpad() { settings.showTrackpad.toggle() }

    private func showTrackpad() {
        guard trackpadPanel == nil else { return }
        // Gate at activation, not in the hot path. Clear the bound toggle so it
        // reflects the locked state (and so the $showTrackpad sink doesn't re-fire).
        guard requirePro("The virtual trackpad") else { settings.showTrackpad = false; return }
        let view = TrackpadView(settings: settings) { [weak self] in
            self?.settings.showTrackpad = false
        }
        let host = GlassHostingView(rootView: view)
        let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame ?? engine.bounds
        let rect = NSRect(x: sf.maxX - 420, y: sf.minY + 80, width: 380, height: 280)
        host.frame = NSRect(origin: .zero, size: rect.size)
        let panel = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false   // title-bar handle only (see TitleBarDrag)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        trackpadPanel = panel
    }

    private func hideTrackpad() { trackpadPanel?.orderOut(nil); trackpadPanel = nil }

    // MARK: deck panel (v3 PoC — Stream Deck-style control surface)
    @objc private func toggleDeck() { settings.showDeck.toggle() }

    private func showDeck() {
        guard deckPanel == nil else { return }
        guard requirePro("The Deck") else { settings.showDeck = false; return }
        let view = DeckView(store: DeckStore.shared, settings: settings) { [weak self] in
            self?.settings.showDeck = false
        }
        let host = GlassHostingView(rootView: view)
        let sf = (nsScreen(for: selectedDisplay) ?? NSScreen.main)?.frame ?? engine.bounds
        let rect = savedFrame("deck") ?? NSRect(x: sf.minX + 60, y: sf.midY - 200,
                                                width: 460, height: 420)
        host.frame = NSRect(origin: .zero, size: rect.size)
        let panel = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false   // title-bar handle only (see TitleBarDrag)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        deckPanel = panel
    }

    /// Toggle the deck between its saved size and owning the full display.
    /// Raises panel to .screenSaver level (above menu bar) so it physically covers all
    /// system chrome — presentationOptions alone won't work because the panel is
    /// nonactivating and macOS only honours those options for the frontmost app.
    @objc private func toggleDeckFullScreen() {
        guard let panel = deckPanel,
              let screen = nsScreen(for: selectedDisplay) ?? NSScreen.main else { return }
        let sf = screen.frame
        // Source of truth for "are we full-screen" is the restore ivar, not a
        // size compare (a near-full manual resize must not read as full-screen).
        if let restore = deckFullScreenRestore {
            panel.level = .floating
            NSApp.presentationOptions = []
            deckFullScreenRestore = nil
            let r = (restore.width > 40 && restore.height > 40) ? restore
                  : (savedFrame("deck") ?? NSRect(x: sf.minX + 60, y: sf.midY - 200,
                                                  width: 460, height: 420))
            panel.setFrame(r, display: true)
            saveFrame(panel)                       // persist the restored (non-full) frame
            DeckStore.shared.fullScreen = false    // header shows the resize bean again
        } else {
            deckFullScreenRestore = panel.frame    // remember pre-full size/pos
            DeckStore.shared.fullScreen = true     // header hides the resize bean
            // .screenSaver level (1000) is above the menu bar (24) and Dock — the panel
            // covers them rather than relying on the app being frontmost for presentationOptions.
            panel.level = .screenSaver
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
            panel.setFrame(sf, display: true)
        }
    }

    private func hideDeck() {
        deckPanel?.level = .floating
        NSApp.presentationOptions = []
        deckPanel?.orderOut(nil)
        deckPanel = nil
    }

    /// True when a one-finger drag at `cg` (CG, top-left) is over the deck's
    /// content area (below the header) and the deck is NOT in edit mode — those
    /// drags should scroll a widget's native ScrollView, not move the cursor.
    /// In edit mode interior drags stay mouse-drags (resize / reorder).
    private func deckScrollRegion(_ cg: CGPoint) -> Bool {
        guard let panel = deckPanel, !DeckStore.shared.editing else { return false }
        let flip = NSScreen.screens.first?.frame.maxY ?? 0
        let f = panel.frame
        // Non-grid header strip above DeckView's scrollable `activeGrid`. Must match
        // DeckView.body's layout EXACTLY or we get a dead zone (excluding too much)
        // or scroll interference over the page bar (excluding too little):
        //   .padding(.top, 4) + header(36) + VStack spacing(6) + pageBar(30) + spacing(6)
        // = 82pt. (header's tallest content is the 36pt button row; pageBar is
        // .frame(height: 30).) Hardcoded-but-derived so a DeckView layout change is
        // a visible one-line update here.
        let header: CGFloat = 4 + 36 + 6 + 30 + 6
        let region = CGRect(x: f.minX, y: (flip - f.maxY) + header,
                            width: f.width, height: max(0, f.height - header))
        guard region.contains(cg) else { return false }
        // Volume bars opt OUT of scroll routing: a drag there must reach the bar's
        // SwiftUI gesture as a real mouse drag. DeckWidgets publishes each bar's
        // frame via `g.frame(in: .global)`, which for an NSHostingView is the ROOT
        // hosting view's space — i.e. panel-content-LOCAL (top-left origin), NOT
        // screen-global. So map it into screen Quartz coords the same way `region`
        // is built: x += panel left (f.minX), y += panel top (flip - f.maxY).
        // (A prior "simplification" to compare cg against the raw rect placed the
        // exclusion at the wrong spot and killed the slider drag — do not re-do it.)
        for local in DeckDragRegions.volumeRects.values {
            let cgRect = CGRect(x: f.minX + local.minX, y: (flip - f.maxY) + local.minY,
                                width: local.width, height: local.height)
            if cgRect.contains(cg) { return false }
        }
        return true
    }

    /// Collapsed trackpad: a thin pull tab on the right edge (its active surface
    /// becomes empty automatically, so no touches are intercepted while collapsed).
    private func collapseTrackpadToTab() {
        guard let panel = trackpadPanel else { return }
        let view = FloatingTabView { [weak self] in self?.expandTrackpad() }
        let host = GlassHostingView(rootView: view)
        let sf = floatingScreenFrame()
        let rect = NSRect(x: sf.maxX - 48, y: panel.frame.minY, width: 48, height: 170)
        host.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = host
        setFrameAnimated(panel, rect)
    }

    private func expandTrackpad() {
        guard let panel = trackpadPanel else { return }
        let view = TrackpadView(settings: settings) { [weak self] in
            self?.settings.showTrackpad = false
        }
        let host = GlassHostingView(rootView: view)
        let sf = floatingScreenFrame()
        let y = max(sf.minY + 40, min(panel.frame.minY, sf.maxY - 320))
        let rect = NSRect(x: sf.maxX - 420, y: y, width: 380, height: 280)
        host.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = host
        setFrameAnimated(panel, rect)
    }

    /// The pad's ACTIVE surface in CG coords — the panel frame minus the header
    /// strip (drag/resize/close live there, handled by the absolute path).
    private func trackpadActiveRect() -> CGRect? {
        guard let panel = trackpadPanel else { return nil }
        let flip = NSScreen.screens.first?.frame.maxY ?? 0
        let f = panel.frame
        let header: CGFloat = 46
        return CGRect(x: f.minX, y: (flip - f.maxY) + header,
                      width: f.width, height: max(0, f.height - header))
    }

    private func expandFloating() {
        guard let panel = floatingPanel else { return }
        let view = FloatingControlView(settings: settings,
                                       onKeyboard: { [weak self] in self?.toggleKeyboard() },
                                       onTrackpad: { [weak self] in self?.toggleTrackpad() },
                                       onDeck: { [weak self] in self?.settings.showDeck.toggle() },
                                       onSettings: { [weak self] in self?.openSettings() },
                                       onCollapse: { [weak self] in self?.collapseFloating() })
        let host = GlassHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 176, height: 232)
        let sf = floatingScreenFrame()
        panel.contentView = host
        // Keep the ~40px right-edge gap and vertical centring as the panel grew.
        setFrameAnimated(panel, NSRect(x: sf.maxX - 216, y: sf.midY - 116, width: 176, height: 232))
    }

    private func collapseFloating() {
        guard let panel = floatingPanel else { return }
        let view = FloatingTabView { [weak self] in self?.expandFloating() }
        let host = GlassHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 48, height: 170)
        let sf = floatingScreenFrame()
        // pin to the right edge, keeping the current vertical position
        panel.contentView = host
        setFrameAnimated(panel, NSRect(x: sf.maxX - 48, y: panel.frame.minY, width: 48, height: 170))
    }

    // MARK: Notification Center (best-effort: click the menu-bar clock on the
    // TOUCH display, so it opens there — not wherever the cursor happens to be).
    private func openNotificationCenter() {
        let b = CGDisplayBounds(selectedDisplay)
        let p = CGPoint(x: b.maxX - 48, y: b.origin.y + 11)
        Pointer.leftDown(p); Pointer.leftUp(p)
    }


    // MARK: display picker (numbered overlays; click or press the number key)
    @objc private func startDisplayPicker() {
        guard pickerWindows.isEmpty else { return }
        let screens = NSScreen.screens
        let total = screens.count
        for (i, screen) in screens.enumerated() {
            let n = i + 1
            let view = DisplayPickerView(thisNumber: n, total: total, name: screen.localizedName) {
                [weak self] picked in self?.finishDisplayPick(picked)
            }
            let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = .clear
            win.contentView = GlassHostingView(rootView: view)
            win.setFrame(screen.frame, display: true)
            win.orderFrontRegardless()
            pickerWindows.append(win)
        }
        pickerWindows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if ev.keyCode == 53 { self.teardownDisplayPicker(); return nil }   // Esc cancels
            guard let str = ev.charactersIgnoringModifiers,
                  let n = Int(str), n >= 1, n <= total else { return ev }
            self.finishDisplayPick(n)
            return nil
        }
    }

    private func finishDisplayPick(_ number: Int) {
        let screens = NSScreen.screens
        guard number >= 1, number <= screens.count else { return }
        if let id = (screens[number - 1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? NSNumber)?.uint32Value {
            applyDisplay(id)
            settings.displayID = Double(id)
            settings.displayUUID = uuid(for: id) ?? ""
            settings.hasPickedDisplay = true
            settings.save()
        }
        teardownDisplayPicker()
        rebuildMenu()
        startCalibration()      // flow straight into corner calibration
    }

    // MARK: onboarding
    /// The old launch-time display resolution, reused after onboarding finishes.
    private func resolveSavedDisplay() {
        if let id = displayID(forUUID: settings.displayUUID) {
            applyDisplay(id)
        } else if settings.hasPickedDisplay && NSScreen.screens.count > 1 {
            startDisplayPicker()
        } else if settings.hasPickedDisplay {
            applyDisplay(CGMainDisplayID())   // single screen: just use it, don't nag
        } else {
            startDisplayPicker()
        }
    }

    private func startOnboarding(resumeAt: OnboardingStage?) {
        guard onboarding == nil else { return }
        let ob = OnboardingController(settings: settings)
        ob.onPickDisplay = { [weak self] n in self?.onboardingPickDisplay(n) }
        ob.onStartCalibration = { [weak self] in self?.startCalibration() }
        ob.onFinished = { [weak self] in
            guard let self = self else { return }
            self.onboarding = nil
            self.resolveSavedDisplay()   // bind whatever was picked (or re-ask)
            // Now that onboarding is gone, honor the default-on launcher (deferred at launch).
            if self.settings.showFloatingControl { self.showFloatingControl() }
            self.rebuildMenu()
        }
        onboarding = ob
        ob.show(resumeAt: resumeAt)
    }

    /// Setup Assistant menu item: full flow from the top, intro included.
    @objc private func startSetupAssistant() {
        guard onboarding == nil else { return }   // already running — ignore re-click, don't clobber the persisted stage
        settings.onboardingStage = 0
        startOnboarding(resumeAt: nil)
    }

    /// Monitor-step pick: bind + persist, but do NOT auto-start calibration —
    /// onboarding's Calibration step owns that handoff (it has its own intro).
    private func onboardingPickDisplay(_ number: Int) {
        let screens = NSScreen.screens
        guard number >= 1, number <= screens.count else { return }
        if let id = (screens[number - 1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? NSNumber)?.uint32Value {
            applyDisplay(id)
            settings.displayID = Double(id)
            settings.displayUUID = uuid(for: id) ?? ""
            settings.hasPickedDisplay = true
            settings.save()
        }
    }

    private func teardownDisplayPicker() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        pickerWindows.forEach { $0.orderOut(nil) }
        pickerWindows.removeAll()
    }

    // MARK: calibration
    @objc private func startCalibration() {
        guard calibrationWindow == nil else { return }
        let controller = CalibrationController()
        controller.onDone = { [weak self] in self?.endCalibration() }
        calController = controller

        engine.onCalibrationTap = { [weak controller] x, y in
            DispatchQueue.main.async { controller?.record(x, y) }
        }
        engine.calibrating = true

        // NSWindow uses AppKit (bottom-left) screen coordinates, so position by the
        // matching NSScreen rather than the CG display bounds.
        let frame = nsScreen(for: selectedDisplay)?.frame ?? NSScreen.main?.frame ?? engine.bounds
        let win = KeyableWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentView = GlassHostingView(rootView: CalibrationView(controller: controller))
        win.setFrame(frame, display: true)
        calibrationWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func endCalibration() {
        engine.calibrating = false
        engine.onCalibrationTap = nil
        calibrationWindow?.orderOut(nil)
        calibrationWindow = nil
        calController = nil
        onboarding?.calibrationFinished()   // onboarding shows its close-out card
        // Refresh the Touch API hello geometry with the new calibration.
        api.updateGeometry(screen: engine.bounds,
                           cal: (settings.calXMin, settings.calXMax,
                                 settings.calYMin, settings.calYMax))
    }

    // MARK: actions
    // Stable display identity (survives reboot/reconnect, unlike the raw display id).
    private func uuid(for id: CGDirectDisplayID) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    private func displayID(forUUID uuid: String) -> CGDirectDisplayID? {
        guard !uuid.isEmpty, let want = CFUUIDCreateFromString(nil, uuid as CFString) else { return nil }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids {
            if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), CFEqual(u, want) {
                return id
            }
        }
        return nil
    }

    private func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        }
    }

    @objc private func toggleCapture() { capture.toggle(); rebuildMenu() }
    @objc private func reconnectTouch() { hid.reconnect() }
    private var reconnectObserver: NSObjectProtocol?
    private var deckFullObserver: NSObjectProtocol?
    func observeSettingsRequests() {
        // Settings → General → Touchscreen "Reconnect" button.
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .gcReconnectTouch, object: nil, queue: .main
        ) { [weak self] _ in self?.hid.reconnect() }
        // Deck → Full Screen toggle.
        deckFullObserver = NotificationCenter.default.addObserver(
            forName: .gcDeckFullScreen, object: nil, queue: .main
        ) { [weak self] _ in self?.toggleDeckFullScreen() }
    }
    @objc private func toggleEdgeZones() { settings.showEdgeZones.toggle(); rebuildMenu() }
    @objc private func toggleVerboseLog() { settings.verbose.toggle(); rebuildMenu() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)        // menu-bar only, no Dock icon
let controller = AppController()
app.delegate = controller
app.run()
