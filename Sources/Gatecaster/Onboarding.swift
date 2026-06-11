import Cocoa
import SwiftUI
import IOKit.hid
import MetalKit

/// Stages persist in AppSettings.onboardingStage so the TCC-mandated relaunch
/// resumes where the user left off.
enum OnboardingStage: Int {
    case welcome = 0, permissions = 1, monitor = 2, calibration = 3
}

/// Observable state shared by the controller (AppKit) and the step views (SwiftUI).
final class OnboardingModel: ObservableObject {
    @Published var stage: OnboardingStage = .welcome
    @Published var introDone = false           // true once the vortex reveal finished (t >= 6)
    @Published var displays: [(number: Int, name: String, size: String)] = []
    @Published var calibrationRunning = false
    @Published var finished = false            // close-out "You're all set" card
}

/// Owns the full-screen onboarding window. AppController wires the callbacks —
/// the controller itself never touches Engine/HID/display state directly.
final class OnboardingController {
    let model = OnboardingModel()
    private let settings: AppSettings
    private var window: KeyableWindow?
    private var renderer: VortexRenderer?
    private weak var mtkView: MTKView?   // weak: owned by the window's container; kept only to pause on teardown
    private var cardSize: CGSize = .zero  // centered rect the starfield mask collapses into
    private var badgeWindows: [NSWindow] = []
    private var keyMonitor: Any?

    /// AppController hooks (set before show()):
    var onPickDisplay: ((Int) -> Void)?        // monitor-step pick (1-based screen index)
    var onStartCalibration: (() -> Void)?      // opens the existing corner-tap flow
    var onFinished: (() -> Void)?              // flow complete; tear down

    init(settings: AppSettings) { self.settings = settings }

    // MARK: lifecycle
    /// `resumeAt` non-nil = jump straight to a step with no intro (relaunch
    /// resume, or "existing user missing a permission").
    func show(resumeAt: OnboardingStage?) {
        guard window == nil, let screen = NSScreen.main else { return }
        let frame = screen.frame
        // Modal size: spec's Raycast-like ~780×620, clamped on small screens.
        let winSize = CGSize(width: min(780, frame.width * 0.6),
                             height: min(620, frame.height * 0.75))
        cardSize = winSize   // the mask collapses the starfield to exactly this centered rect

        let win = KeyableWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.level = .normal       // System Settings / TCC prompts must be able to cover us
        // Non-opaque so the dimmed desktop shows around the card on the step screens.
        // During the intro and the welcome step the full-screen Metal view renders
        // opaque black+stars (hiding the desktop); collapsing the starfield into the
        // card later uncovers the dim scrim over the live desktop.
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))

        // Dim scrim over the live desktop, revealed around the card once the starfield
        // collapses. On the intro/welcome it's hidden behind the full-screen Metal view.
        let scrim = NSView(frame: container.bounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        scrim.autoresizingMask = [.width, .height]
        container.addSubview(scrim)

        // Reduce Motion (or Metal unavailable / MSL compile failure) → static
        // path: no vortex, content fades in over black. Never block onboarding.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let (mtk, r) = makeVortexView(frame: container.bounds, windowSize: winSize) {
            renderer = r
            mtkView = mtk
            if reduceMotion || resumeAt != nil { r.skipToEnd() }
            r.onTick = { [weak self] t in
                guard let self = self, !self.model.introDone, t >= 6.0 else { return }
                self.finishIntro(animated: true)
            }
            mtk.autoresizingMask = [.width, .height]
            container.addSubview(mtk)
        } else {
            model.introDone = true   // static fallback: show content immediately
        }
        if reduceMotion || resumeAt != nil { model.introDone = true }

        if let stage = resumeAt { model.stage = stage }
        else { model.stage = OnboardingStage(rawValue: settings.onboardingStage) ?? .welcome }
        settings.onboardingStage = model.stage.rawValue

        let host = NSHostingView(rootView: OnboardingView(
            model: model, settings: settings, modalSize: winSize,
            advance: { [weak self] in self?.advance() },
            back: { [weak self] in self?.back() },
            pick: { [weak self] n in self?.pickDisplay(n) },
            startCalibration: { [weak self] in self?.beginCalibration() },
            finish: { [weak self] in self?.finish() }))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        win.contentView = container
        win.setFrame(frame, display: true)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Reduce-Motion / resume / no-Metal paths already set introDone. The welcome
        // step keeps the full-screen starfield; a later resume step starts collapsed.
        if model.introDone && model.stage != .welcome { collapseStarsToCard(animated: false) }

        // Any key during the intro skips it; number keys pick a display on the
        // monitor step. Local monitor only — no nextEvent loops (HID deadlock).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if !self.model.introDone { self.skipIntro(); return nil }
            if self.model.stage == .monitor,
               let s = ev.charactersIgnoringModifiers, let n = Int(s),
               n >= 1, n <= NSScreen.screens.count {
                self.pickDisplay(n)
                return nil
            }
            return ev
        }
    }

    func skipIntro() {
        renderer?.skipToEnd()
        finishIntro(animated: true)
    }

    /// Mark the intro complete exactly once. The welcome step keeps the full-screen
    /// starfield; only on a later (resume) stage do we collapse it into the card.
    private func finishIntro(animated: Bool) {
        guard !model.introDone else { return }
        model.introDone = true
        if model.stage != .welcome { collapseStarsToCard(animated: animated) }
    }

    /// Collapse the full-screen starfield into the centered card rect by animating a
    /// rounded-rect mask on the Metal layer. The view keeps drawing (stars twinkle in
    /// the card); outside the card the dim scrim + live desktop show through.
    private func collapseStarsToCard(animated: Bool) {
        guard let mtk = mtkView, let layer = mtk.layer else { return }
        let full = mtk.bounds
        let card = CGRect(x: (full.width  - cardSize.width)  / 2,
                          y: (full.height - cardSize.height) / 2,
                          width: cardSize.width, height: cardSize.height)
        // A tiny radius on the full path keeps the same path structure as the card path,
        // so the morph interpolates smoothly instead of snapping.
        let fullPath = CGPath(roundedRect: full, cornerWidth: 0.01, cornerHeight: 0.01, transform: nil)
        let cardPath = CGPath(roundedRect: card, cornerWidth: 20, cornerHeight: 20, transform: nil)
        let mask: CAShapeLayer
        if let existing = layer.mask as? CAShapeLayer {
            mask = existing
        } else {
            mask = CAShapeLayer(); mask.path = fullPath; layer.mask = mask
        }
        guard animated else { mask.path = cardPath; return }
        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = mask.presentation()?.path ?? mask.path ?? fullPath
        anim.toValue = cardPath
        anim.duration = 0.7
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.path = cardPath
        mask.add(anim, forKey: "collapse")
    }

    private func advance() {
        switch model.stage {
        case .welcome:      setStage(.permissions)
        case .permissions:  setStage(.monitor)
        case .monitor:      setStage(.calibration)
        case .calibration:  finish()
        }
    }

    private func back() {
        guard let prev = OnboardingStage(rawValue: model.stage.rawValue - 1) else { return }
        setStage(prev)
    }

    private func setStage(_ s: OnboardingStage) {
        // Leaving the welcome step: collapse the full-screen starfield into the card,
        // uncovering the dim desktop around it (no-op once already collapsed).
        if s != .welcome { collapseStarsToCard(animated: true) }
        model.stage = s
        settings.onboardingStage = s.rawValue   // relaunch resumes here
        settings.save()
        if s == .monitor { showBadges() } else { hideBadges() }
        if s == .monitor { refreshDisplays() }
    }

    // MARK: monitor step
    private func refreshDisplays() {
        model.displays = NSScreen.screens.enumerated().map { i, s in
            (i + 1, s.localizedName,
             "\(Int(s.frame.width)) × \(Int(s.frame.height))")
        }
    }

    private func showBadges() {
        hideBadges()
        for (i, screen) in NSScreen.screens.enumerated() {
            let n = i + 1
            let size = NSSize(width: 150, height: 90)
            let rect = NSRect(x: screen.frame.maxX - size.width - 24,
                              y: screen.frame.maxY - size.height - 24,
                              width: size.width, height: size.height)
            let w = NSWindow(contentRect: rect, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView:
                IdentifyBadgeView(number: n, name: screen.localizedName) { [weak self] in
                    self?.pickDisplay(n)
                })
            w.orderFrontRegardless()
            badgeWindows.append(w)
        }
    }

    private func hideBadges() {
        badgeWindows.forEach { $0.orderOut(nil) }
        badgeWindows.removeAll()
    }

    /// Display hotplug while the monitor step is open: refresh rows + badges.
    /// AppController calls this from its existing screensChanged observer.
    func screensChanged() {
        guard model.stage == .monitor else { return }
        refreshDisplays()
        showBadges()
    }

    private func pickDisplay(_ n: Int) {
        onPickDisplay?(n)
        setStage(.calibration)
    }

    // MARK: calibration step
    private func beginCalibration() {
        model.calibrationRunning = true
        window?.orderOut(nil)            // get out of the way of the corner targets
        onStartCalibration?()
    }

    /// AppController calls this from endCalibration().
    func calibrationFinished() {
        guard model.calibrationRunning else { return }
        // NOTE: the done card is deliberately not resume-persistent — onboardingStage
        // stays at .calibration. If the app is killed before "Finish", relaunch resumes
        // on the (re-runnable) calibration step rather than a dangling success screen.
        model.calibrationRunning = false
        model.finished = true
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        settings.hasOnboarded = true
        settings.onboardingStage = 0
        settings.save()
        teardown()
        onFinished?()
    }

    func teardown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        hideBadges()
        mtkView?.isPaused = true      // stop the 60fps draw loop even if the window lingers in an autorelease pool
        mtkView?.delegate = nil       // break the (weak) delegate link so the renderer can't be re-entered
        mtkView = nil
        window?.orderOut(nil)
        window = nil
        renderer = nil
    }
}

// MARK: - SwiftUI step content

/// Full-frame transparent overlay; the visible "modal" is a centered region
/// whose size EXACTLY matches the shader's window rect (same numbers), so the
/// Metal glass panel and the SwiftUI content always align.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    let modalSize: CGSize
    var advance: () -> Void
    var back: () -> Void
    var pick: (Int) -> Void
    var startCalibration: () -> Void
    var finish: () -> Void

    @State private var permTick = false
    private let permPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if model.introDone {
                cardPanel
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeIn(duration: 0.5), value: model.introDone)
    }

    /// The card is a TRANSPARENT frame the exact size of the masked starfield behind it:
    /// the Metal stars show inside, the dim desktop shows outside. A thin rim defines the
    /// edge on the step screens; the welcome step is full-screen, so it gets no rim.
    private var cardPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return content
            .frame(width: modalSize.width, height: modalSize.height)
            .overlay {
                if model.stage != .welcome {
                    shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
            }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            Group {
                if model.finished { doneCard }
                else {
                    switch model.stage {
                    case .welcome:      welcome
                    case .permissions:  permissions
                    case .monitor:      monitor
                    case .calibration:  calibration
                    }
                }
            }
            .frame(maxHeight: .infinity)
            pageDots
                .padding(.bottom, 26)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i == model.stage.rawValue ? Color.white : Color.white.opacity(0.22))
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// Flat white primary button (no gradient). The card interior is always the dark
    /// starfield, so a fixed white-on-black button reads correctly regardless of mode.
    private func cta(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 200, height: 38)
                .background(Color.white)
                .cornerRadius(9)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: steps
    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Welcome to Gatecaster")
                .font(.system(size: 26, weight: .bold))
            Text("Your touchscreen, cast into a true Mac input surface.")
                .font(.system(size: 13)).opacity(0.62)
            Spacer().frame(height: 18)
            VStack(alignment: .leading, spacing: 14) {
                featureRow("🌀", "Open the gate", "pointer, taps, native gestures")
                featureRow("✨", "Cast across space", "pinch, rotate, momentum scroll")
                featureRow("🛰️", "Summon controls", "keyboard, trackpad & deck")
            }
            Spacer()
            cta("Get Started") { advance() }
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(icon).font(.system(size: 15))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("— " + detail).font(.system(size: 13)).opacity(0.6)
        }
    }

    private var permissions: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Open the Gate")
                .font(.system(size: 24, weight: .bold))
            Text("Gatecaster needs two permissions to read the panel and move the pointer.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 8)
            PermissionsView()                      // shared live checklist (Task 2)
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                .frame(maxWidth: 460)
            Spacer()
            cta("Continue") { advance() }
                .disabled(!permissionsGranted)
                .opacity(permissionsGranted ? 1 : 0.4)
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
        .onReceive(permPoll) { _ in permTick.toggle() }   // re-evaluate permissionsGranted
    }

    private var permissionsGranted: Bool {
        AXIsProcessTrusted() &&
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private var monitor: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Which screen is the touchscreen?")
                .font(.system(size: 24, weight: .bold))
            Text("Badges mark each display. Click its row, press its number key, or click the badge with the mouse.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 8)
            VStack(spacing: 8) {
                ForEach(model.displays, id: \.number) { d in
                    Button { pick(d.number) } label: {
                        HStack(spacing: 12) {
                            Text("\(d.number)")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.system(size: 13, weight: .medium))
                                Text(d.size).font(.system(size: 11)).opacity(0.55)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").opacity(0.4)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 440)
            Spacer()
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private var calibration: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Final step — map the corners")
                .font(.system(size: 24, weight: .bold))
            Text("Tap each corner target on the touchscreen so Gatecaster knows exactly where the panel edges land.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
            cta("Start Calibration") { startCalibration() }
            Button("Skip for now") { finish() }    // calibration re-runnable from Settings
                .buttonStyle(.plain)
                .font(.system(size: 12)).opacity(0.5)
                .padding(.top, 4)
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private var doneCard: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("You're all set")
                .font(.system(size: 26, weight: .bold))
            Text("The gate is open. Gatecaster lives in the menu bar — settings, keyboard, trackpad and deck are one tap away.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
            cta("Finish") { finish() }
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }
}
