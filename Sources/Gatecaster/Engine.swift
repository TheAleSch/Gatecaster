import AppKit
import CoreGraphics
import Foundation

/// Turns Report ID 1 packets into macOS input: pointer / click / drag,
/// press-and-hold right-click, two-finger momentum scroll, and continuous
/// pinch-zoom + rotate via the GestureKit gesture synth.
final class Engine {
    private let s = AppSettings.shared      // all tunables / modes / calibration live here
    var bounds: CGRect = CGDisplayBounds(CGMainDisplayID())

    // Calibration capture: when on, taps are reported raw instead of moving the
    // cursor, so the calibration overlay can learn the panel↔screen mapping.
    var calibrating = false
    var onCalibrationTap: ((Int, Int) -> Void)?
    private var calLastRaw: (Int, Int)?

    // Edge gestures: 3-finger dwell + pull up from the bottom → on-screen keyboard;
    // 2-finger dwell + pull in from the right edge → Notification Center.
    var onShowKeyboard: (() -> Void)?
    var onNotificationCenter: (() -> Void)?

    // Live edge-zone feedback: 0 = idle, 1 = right finger count resting in the
    // zone, 2 = dwell complete (armed — ready to pull). First arg: bottom zone?
    var onEdgeZoneState: ((Bool, Int) -> Void)?
    private var zoneStBottom = 0, zoneStRight = 0
    private func setZone(bottom: Bool, _ st: Int) {
        if bottom {
            if zoneStBottom != st { zoneStBottom = st; onEdgeZoneState?(true, st) }
        } else {
            if zoneStRight != st { zoneStRight = st; onEdgeZoneState?(false, st) }
        }
    }

    // Returns true if a screen point is over a floating panel (keyboard / launcher),
    // so a one-finger touch there drags it instead of scrolling, even in iPad mode.
    var isOverPanel: ((CGPoint) -> Bool)?
    private var overPanel = false

    // Dragging OUR panels never goes through synthetic mouse events (window-server
    // drag sessions + SwiftUI button tracking can wedge and eat all input). The
    // engine drives the window frame directly via these callbacks instead.
    var onPanelDragBegan: ((CGPoint) -> Bool)?   // true if a panel is at the point
    var onPanelDragMoved: ((CGPoint) -> Void)?
    var onPanelDragEnded: (() -> Void)?

    // True when a one-finger drag starting at this point should SCROLL a deck
    // widget (native ScrollView) rather than move the cursor. We then emit real
    // scroll-wheel events (the `.fscroll` path) under the cursor — SwiftUI
    // gestures don't receive our synthetic drags on a non-key panel, so the
    // engine drives scrolling itself.
    var deckScrollAt: ((CGPoint) -> Bool)?

    // Virtual trackpad: CG rect of the pad's active surface (nil when hidden).
    // Touches that START inside it act like a physical trackpad: relative cursor
    // movement, tap = click, two-finger = scroll (with inertia), 2-finger tap =
    // right click. The absolute touch position is never used for clicks.
    var trackpadRect: (() -> CGRect?)?
    private var padActive = false
    private var padLast = CGPoint.zero
    private var padScrollLast = CGPoint.zero
    private var padStartT = 0.0
    private var padLastT = 0.0
    private var padMoved = 0.0
    private var padTwo = false
    private var padClicked = false          // a click already fired this session
    private var padDragArm = false          // tap-and-a-half: a tap just preceded this touch
    private var padDragging = false         // button held; one finger moves = drag

    // Click sequencing (single / double / triple) shared by pad + touchscreen taps.
    private var lastClickT = 0.0
    private var lastClickPos = CGPoint.zero
    private var clickSeq: Int64 = 1

    private func nextClickCount(_ t: Double, _ p: CGPoint) -> Int64 {
        let near = hypot(p.x - lastClickPos.x, p.y - lastClickPos.y) < 24
        if (t - lastClickT) < NSEvent.doubleClickInterval && near {
            clickSeq = min(clickSeq + 1, 3)
        } else {
            clickSeq = 1
        }
        lastClickT = t; lastClickPos = p
        return clickSeq
    }
    private enum PadSub { case none, scroll, pinch, rotate }
    private var padSub: PadSub = .none      // latched two-finger intent on the pad
    private var padTwoStartT = 0.0
    private var padTwoMoved = 0.0
    private var padTwoStartC = CGPoint.zero
    private var padStartDist = 0.0, padStartAngle = 0.0
    private var padLastDist = 0.0, padLastAngle = 0.0

    private var scrollSign = -1.0   // sign captured for the active scroll/coast
    private var momGain = 2.0       // gain captured for the active coast (1- vs 2-finger)

    private enum Mode { case idle, maybeTap, dragging, consumed, scrolling, fscroll, momentum, swiping, lifting, panelDrag }
    private let swipeMin = 250.0          // raw-units travel to trigger a 3+ finger swipe
    private var swipeStart = (x: 0.0, y: 0.0)
    private var swipeStartT = 0.0         // when the 3-finger group first landed (for dwell)
    private var swipeFromBottom = false   // did it start at the bottom edge?
    private var swipeFired = false
    private var swipeArm = 0              // 3-finger frames seen before swipe commits
    private let swipeArmFrames = 3        // ~debounce against phantom 3rd contacts
    private var lastThreeT = 0.0          // last time the panel reported 3+ contacts
    private var mode: Mode = .idle

    private var tStart = 0.0
    private var pStart = CGPoint.zero
    private var pLast = CGPoint.zero
    private var scrollLast = CGPoint.zero
    private var twoMoved = 0.0
    private var twoStartT = 0.0
    private var lastDist = 0.0
    private var lastAngle = 0.0
    private var phaseOpen = false
    private var momOpen = false
    private var magOpen = false             // = "began emitted" for each gesture type
    private var rotOpen = false
    private enum TwoSub { case none, scroll, pinch, rotate, pan }
    private var twoSub: TwoSub = .none      // latched two-finger gesture
    private var twoStartCx = 0.0, twoStartCy = 0.0   // centroid at touchdown
    private var twoStartDist = 0.0, twoStartAngle = 0.0  // spread/angle at touchdown
    private var pinchAccum = 0.0           // Shortcuts mode: accumulated zoom/rotate/pan
    private var rotAccum = 0.0
    private var panFired = false
    private var twoFromRightEdge = false   // 2-finger gesture started at the right edge
    private var twoFromBottomEdge = false  // 2-finger gesture started at the bottom edge
    private var notifFired = false
    private var kbFired = false
    private var rcFired = false            // right-click already fired this 2-finger phase

    private var preTouchPos: CGPoint?       // cursor location before this touch
    private var lastActionTime = 0.0        // last time we emitted any input
    private var liftT = 0.0                  // time we entered the .lifting grace
    private var momHoldFrames = 0            // touch frames seen during a coast (debounce)

    private var vel = (x: 0.0, y: 0.0)
    private var acc = (x: 0.0, y: 0.0)
    private var sacc = (x: 0.0, y: 0.0)
    private var samples: [(t: Double, x: Double, y: Double)] = []
    private var lastReport = 0.0
    private var lastMom = 0.0

    private var timer: Timer?

    func start() {
        // Added to .common run-loop modes (not just default): the tick must
        // keep running while menus are open and windows are dragged, or
        // momentum/lift detection freezes whenever the UI tracks the mouse.
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func now() -> Double { CFAbsoluteTimeGetCurrent() }

    // MARK: report parsing
    struct Contact { let id: Int; let x: Int; let y: Int }

    func onReport(_ data: [UInt8]) {
        guard data.first == 0x01 else { return }
        var contacts: [Contact] = []
        for k in 0..<10 {
            let b = 1 + k * 11
            if b + 9 > data.count { break }
            if data[b] & 0x01 == 0 { continue }
            let id = Int((data[b] >> 2) & 0x3f)
            let x = Int(data[b + 3]) | (Int(data[b + 4]) << 8)
            let y = Int(data[b + 7]) | (Int(data[b + 8]) << 8)
            contacts.append(Contact(id: id, x: x, y: y))
        }
        lastReport = now()
        handle(contacts)
    }

    private func toScreen(_ x: Int, _ y: Int) -> CGPoint {
        let spanX = max(1.0, s.calXMax - s.calXMin)
        let spanY = max(1.0, s.calYMax - s.calYMin)
        let fx = min(1.0, max(0.0, (Double(x) - s.calXMin) / spanX))
        let fy = min(1.0, max(0.0, (Double(y) - s.calYMin) / spanY))
        return CGPoint(x: bounds.origin.x + fx * bounds.width,
                       y: bounds.origin.y + fy * bounds.height)
    }

    // MARK: periodic tick (momentum + lift debounce)
    private func tick() {
        let t = now()
        // Calibration: the panel may go silent instead of sending a finger-up report,
        // so flush a pending tap after the lift timeout.
        if calibrating {
            if let r = calLastRaw, (t - lastReport) > s.liftTimeout {
                calLastRaw = nil; onCalibrationTap?(r.0, r.1)
            }
            return
        }
        if mode == .momentum { stepMomentum(t); return }
        if mode != .idle && (t - lastReport) > s.liftTimeout {
            handle([])                      // device went silent -> finger lifted
        }
        // Restore the pointer to its pre-touch spot once everything is quiet.
        if s.restoreCursor, mode == .idle, let pos = preTouchPos,
           (t - lastActionTime) * 1000 > s.restoreDelayMS {
            Pointer.warp(pos)
            preTouchPos = nil
        }
        // WATCHDOG: if we're idle but a left-button-down was never matched by an
        // up (any lost path), release it — a held button makes all input feel
        // stuck (clicks dead, every touch selects/drags).
        if mode == .idle, Pointer.leftIsDown, (t - lastReport) > 0.5 {
            Pointer.leftUp(Pointer.location())
        }
    }

    // Tap-only capture used by the calibration overlay (no cursor movement).
    private func handleCalibration(_ contacts: [Contact]) {
        if let c = contacts.first { calLastRaw = (c.x, c.y) }
        else if let r = calLastRaw { calLastRaw = nil; onCalibrationTap?(r.0, r.1) }
    }

    // MARK: palm rejection
    // The ELAN panel reports no contact size, so palms are classified
    // behaviorally and stay rejected (sticky by id) until they lift:
    //  1. CLUSTER  — 3+ contacts bunched tighter than any finger spread is a
    //     palm heel, not a gesture.
    //  2. PANEL GUARD — while an accepted touch is typing/padding on one of
    //     our own panels, NEW touches landing OFF-panel are a resting hand.
    private var palmIds = Set<Int>()      // rejected until lift
    private var acceptedIds = Set<Int>()  // contacts the state machine has seen

    private func filterPalms(_ contacts: [Contact]) -> [Contact] {
        guard s.palmRejection, !contacts.isEmpty else {
            palmIds.removeAll()
            acceptedIds = Set(contacts.map { $0.id })
            return contacts
        }
        let live = Set(contacts.map { $0.id })
        palmIds.formIntersection(live)          // lifted palms are forgiven
        acceptedIds.formIntersection(live)

        var kept = contacts.filter { !palmIds.contains($0.id) }

        // 1) cluster: any contact with 2+ neighbors inside palmClusterPts
        if kept.count >= 3 {
            let pts = kept.map { toScreen($0.x, $0.y) }
            let r2 = s.palmClusterPts * s.palmClusterPts
            for i in kept.indices {
                var bunch = 0
                for j in kept.indices where j != i {
                    let dx = pts[i].x - pts[j].x, dy = pts[i].y - pts[j].y
                    if dx * dx + dy * dy < r2 { bunch += 1 }
                }
                if bunch >= 2 { palmIds.insert(kept[i].id) }
            }
            if !palmIds.isEmpty {
                kept = kept.filter { !palmIds.contains($0.id) }
                acceptedIds.subtract(palmIds)
            }
        }

        // 2) panel guard: typing or using the virtual trackpad
        if s.palmPanelGuard {
            let busyOnPanel = kept.contains { c in
                acceptedIds.contains(c.id)
                    && (isOverPanel?(toScreen(c.x, c.y)) ?? false)
            }
            if busyOnPanel {
                for c in kept where !acceptedIds.contains(c.id) {
                    if !(isOverPanel?(toScreen(c.x, c.y)) ?? false) {
                        palmIds.insert(c.id)
                    }
                }
                kept = kept.filter { !palmIds.contains($0.id) }
            }
        }

        for c in kept { acceptedIds.insert(c.id) }
        if s.verbose, !palmIds.isEmpty {
            FileHandle.standardError.write(Data("[palm] rejecting ids \(palmIds.sorted())\n".utf8))
        }
        return kept
    }

    // MARK: state machine
    private var lastN = -1
    private func handle(_ rawContacts: [Contact]) {
        if calibrating { handleCalibration(rawContacts); return }
        let contacts = filterPalms(rawContacts)
        let t = now()
        let n = contacts.count
        lastActionTime = t                          // any touch frame counts as activity
        if n >= 1 && lastN <= 0 && preTouchPos == nil && s.restoreCursor {
            preTouchPos = Pointer.location()        // remember the pointer before we move it
        }
        if n != lastN {     // diagnostic: how many fingers the panel actually reports
            if s.verbose { FileHandle.standardError.write(Data("[fingers] \(n)\n".utf8)) }
            lastN = n
        }

        // Virtual trackpad: a touch that STARTS on the pad surface is handled in
        // relative-trackpad mode for its whole lifetime.
        if padActive { handlePad(contacts, t); return }
        if mode == .idle, n >= 1, let r = trackpadRect?(),
           r.contains(toScreen(contacts[0].x, contacts[0].y)) {
            padActive = true; padTwo = false; padClicked = false; padSub = .none
            padDragging = false
            // tap-and-a-half: touching again right after a tap arms click-and-drag
            padDragArm = (t - lastClickT) < NSEvent.doubleClickInterval
            padStartT = t; padLastT = t; padMoved = 0
            padLast = toScreen(contacts[0].x, contacts[0].y)
            preTouchPos = nil          // the pad moves the cursor on purpose — never restore
            samples = [(t, Double(padLast.x), Double(padLast.y))]
            return
        }

        if n == 0 {
            swipeArm = 0
            setZone(bottom: true, 0); setZone(bottom: false, 0)
            switch mode {
            case .maybeTap:
                let rv = releaseVelocity()
                let movedTotal = hypot(pLast.x - pStart.x, pLast.y - pStart.y)
                // A flick must have real TRAVEL, not just velocity — a quick tap
                // moves a few px in a few ms, which computes a huge instantaneous
                // velocity and used to steal the click as a micro-coast.
                if s.ipadMode && s.inertia && movedTotal > s.tapMaxMove
                    && hypot(rv.0, rv.1) > s.flickFromTap {
                    vel = (rv.0, rv.1); beginMomentum(t, oneFinger: true)   // short flick coast
                } else if overPanel {
                    // Tap on one of OUR panels (keyboard/deck): hold the button
                    // down briefly so SwiftUI press feedback (key highlight, pop)
                    // actually renders — an instant down+up shows for ~0 frames.
                    Pointer.leftDown(pLast)
                    let up = pLast
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        Pointer.leftUp(up)
                    }
                    mode = .idle
                } else {
                    Pointer.leftDown(pLast); Pointer.leftUp(pLast)     // quick tap = click
                    mode = .idle
                }
                return
            case .dragging: Pointer.leftUp(pLast)
            case .panelDrag: onPanelDragEnded?()
            case .lifting:
                // A pinch/rotate/tap that ended via the grace state. A still,
                // quick two-finger tap = right click (when that mode is enabled).
                if s.rightClickMode.usesTwoFingerTap, !rcFired, isTwoFingerTap(t) {
                    Pointer.rightClick(pLast)
                }
            case .swiping:
                break   // 3-finger swipe is a one-shot keystroke; nothing to close
            case .momentum:
                momHoldFrames = 0; return   // stray empty report during coast — keep going
            case .scrolling, .fscroll:
                let wasFscroll = mode == .fscroll
                closeSmoothGestures()
                if !wasFscroll, s.rightClickMode.usesTwoFingerTap, !rcFired, isTwoFingerTap(t) {
                    Pointer.rightClick(pLast); mode = .idle
                } else {
                    // Smooth mode: a committed horizontal two-finger swipe → fire the
                    // real ⌘[ / ⌘] on release, since injected edge-scroll shows Safari's
                    // rubber-band indicator but doesn't reliably cross its commit point.
                    let netH = Double(scrollLast.x) - twoStartCx
                    let netV = Double(scrollLast.y) - twoStartCy
                    if !wasFscroll, s.gestureMode == .smooth,
                       abs(netH) > abs(netV), abs(netH) > s.pageSwipePts {
                        endScrollPhase()
                        Pointer.keyFlagged(netH < 0 ? Pointer.kLeftBracket : Pointer.kRightBracket,
                                           .maskCommand)
                        mode = .idle
                    } else {
                        let rv = releaseVelocity(); vel = (rv.0, rv.1)
                        let fast = hypot(rv.0, rv.1) > s.flickMin
                        let horizFlick = abs(rv.0) > abs(rv.1)
                        if fast && (s.inertia || horizFlick) { beginMomentum(t, oneFinger: wasFscroll) }
                        else { endScrollPhase(); mode = .idle }
                    }
                }
                return
            default: break
            }
            mode = .idle
            return
        }

        // A real touch stops the coast — but the panel emits the occasional
        // phantom contact, and killing momentum on a single stray frame is what
        // made inertia "start then get stuck." Require two consecutive frames.
        if mode == .momentum {
            momHoldFrames += 1
            if momHoldFrames < 2 { return }
            endMomentum(); mode = .idle; vel = (0, 0); momHoldFrames = 0
        }

        // dragging one of our panels: keep following the first contact, whatever
        // the panel reports (phantom extra fingers must not hijack the drag)
        if mode == .panelDrag {
            onPanelDragMoved?(toScreen(contacts[0].x, contacts[0].y))
            return
        }

        // already swiping: keep swiping until all fingers lift
        if mode == .swiping {
            if n >= 2 { handleSwipe(contacts, t) }
            return
        }
        // start a 3-finger swipe after 3+ fingers persist (debounce phantom 3rd
        // contacts). CRUCIAL #1: fingers land staggered (1→2→3) — escalate from
        // maybeTap/scrolling too. CRUCIAL #2: the panel FLICKERS contact counts
        // (3→2→3), so a momentary 2-finger frame must not reset the arming —
        // keep counting if we saw 3 fingers within the last 80 ms.
        if n >= 3 { lastThreeT = t }
        let threeIsh = n >= 3 || (swipeArm > 0 && n >= 2 && (t - lastThreeT) < 0.08)
        if s.threeFingerEnabled && s.gestureMode != .off && threeIsh,
           mode == .idle || mode == .maybeTap || mode == .scrolling || mode == .fscroll {
            swipeArm += 1
            if swipeArm >= swipeArmFrames {
                if mode == .scrolling || mode == .fscroll {
                    closeSmoothGestures(); endScrollPhase()
                }
                handleSwipe(contacts, t)
            }
            return
        }
        swipeArm = 0

        if n >= 2 {
            // A staggered first finger may have begun a one-finger drag; release
            // it so a click isn't held down through the gesture.
            if mode == .dragging { Pointer.leftUp(pLast) }
            // CONSTRAINT: "always send the ended phase for every gesture you begin."
            // A one-finger scroll (.fscroll) leaves an OPEN scroll phase; handleTwoFinger
            // resets phaseOpen by hand without emitting phEnded, abandoning the gesture
            // with a dangling phase — which wedges the macOS recognizer system-wide
            // (touchscreen AND built-in trackpad) until the process exits. Close it
            // first (mirrors the 3-finger swipe path above). endScrollPhase() is a
            // no-op when no phase is open, so it's safe for .idle/.maybeTap/.dragging.
            if mode == .fscroll { closeSmoothGestures(); endScrollPhase() }
            handleTwoFinger(contacts, t)
            return
        }

        // one finger
        let c = contacts[0]
        let p = toScreen(c.x, c.y)

        // A two-finger gesture dropped to ONE finger.
        if mode == .scrolling {
            closeSmoothGestures()
            // MacBook-style right click: hold one finger, TAP a second — fire the
            // moment the tapping finger lifts, at the HELD finger's position.
            if s.rightClickMode.usesSecondFingerTap, !rcFired, isTwoFingerTap(t) {
                endScrollPhase()
                Pointer.rightClick(p)
                rcFired = true
                mode = .consumed        // held finger is swallowed; menu is open
                return
            }
            if twoSub == .scroll {
                // Keep scrolling with the remaining finger — same scroll phase,
                // so two-finger → one-finger scroll is seamless (and still coasts
                // on the final lift, since .fscroll handles momentum too).
                mode = .fscroll; pLast = p; addSample(p, t)
            } else {
                // Pinch / rotate can't continue on one finger, and an undecided
                // two-finger tap should right-click: end cleanly and let the grace
                // decide tap vs. swallow. A flicker back to two fingers resumes.
                endScrollPhase(); liftT = t; mode = .lifting
            }
            return
        }
        if mode == .lifting {
            if (t - liftT) * 1000 > s.liftGraceMS { mode = .consumed }  // lingering finger
            return
        }

        if mode == .idle {
            mode = .maybeTap; tStart = t; pStart = p; pLast = p
            overPanel = isOverPanel?(p) ?? false      // over the keyboard/launcher?
            vel = (0, 0); sacc = (0, 0); samples = [(t, Double(p.x), Double(p.y))]
            Pointer.move(p)
            return
        }
        addSample(p, t)
        let moved = hypot(p.x - pStart.x, p.y - pStart.y)
        switch mode {
        case .maybeTap:
            // Wait `touchSettleMS` before committing to a drag, so a second finger
            // landing a hair later starts a gesture instead of a stray click-drag.
            if moved > s.slop && (t - tStart) * 1000 > s.touchSettleMS {
                // A drag on one of OUR panels moves the panel directly — no
                // synthetic mouse events (see onPanelDragBegan).
                if overPanel, onPanelDragBegan?(pStart) == true {
                    mode = .panelDrag; preTouchPos = nil
                    onPanelDragMoved?(p)
                } else if overPanel, deckScrollAt?(pStart) == true {
                    // Scrollable deck widget: drive a native ScrollView with real
                    // scroll-wheel events. Taps still go through the click path,
                    // so buttons keep working.
                    mode = .fscroll; scrollSign = s.scrollSign
                    sacc = (0, 0); phaseOpen = false
                    emitScroll(rawDy: p.y - pLast.y, rawDx: p.x - pLast.x)
                } else if overPanel {
                    // Interior of one of OUR panels (deck slider, etc.): a real
                    // mouse drag so SwiftUI controls track the finger.
                    mode = .dragging; preTouchPos = nil
                    Pointer.leftDown(pStart); Pointer.leftDrag(p)
                } else if s.ipadMode {
                    mode = .fscroll; scrollSign = s.scrollSign
                    sacc = (0, 0); phaseOpen = false
                } else {
                    mode = .dragging; preTouchPos = nil   // drag targets the cursor too
                    Pointer.leftDown(pStart); Pointer.leftDrag(p)
                }
            } else if s.rightClickMode.usesHold && moved <= s.slop
                        && (t - tStart) * 1000 > s.holdMS {
                Pointer.rightClick(pStart); mode = .consumed   // press-and-hold = right click
            } else {
                Pointer.move(p)
            }
        case .fscroll:
            emitScroll(rawDy: p.y - pLast.y, rawDx: p.x - pLast.x)
        case .dragging:
            Pointer.leftDrag(p)
        case .panelDrag:
            onPanelDragMoved?(p)
        default: break
        }
        pLast = p
    }

    // MARK: virtual trackpad (relative pointer semantics + Magic-Trackpad gestures)
    private func handlePad(_ contacts: [Contact], _ t: Double) {
        let n = contacts.count
        if n == 0 {
            closeSmoothGestures()
            if padDragging {
                Pointer.leftUp(Pointer.location())              // end click-and-drag
                padDragging = false
            } else if padTwo {
                endScrollPhase()
                if !padClicked && isPadTap(t) {
                    Pointer.rightClick(Pointer.location())      // 2-finger tap = right click
                } else if padSub == .scroll {
                    let rv = releaseVelocity(); vel = (rv.0, rv.1)
                    if s.inertia && hypot(rv.0, rv.1) > s.flickMin { beginMomentum(t, oneFinger: false) }
                }
            } else if !padClicked && isPadTap(t) {
                let cur = Pointer.location()
                Pointer.click(cur, clickState: nextClickCount(t, cur))  // tap = click at CURSOR
            }
            padActive = false
            return
        }

        // Click-and-drag in progress: one (or more) fingers just keep dragging.
        if padDragging {
            let p = toScreen(contacts[0].x, contacts[0].y)
            let dx = p.x - padLast.x, dy = p.y - padLast.y
            padMoved += hypot(dx, dy)
            padLast = p
            if dx != 0 || dy != 0 {
                let accel = padAccel(dx, dy, t - padLastT)
                var cur = Pointer.location()
                cur.x += dx * s.trackpadGain * accel
                cur.y += dy * s.trackpadGain * accel
                Pointer.leftDrag(cur)
            }
            padLastT = t
            return
        }
        if n >= 2 {
            let cs = contacts.sorted { $0.id < $1.id }
            let a = toScreen(cs[0].x, cs[0].y), b = toScreen(cs[1].x, cs[1].y)
            let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dist = hypot(b.x - a.x, b.y - a.y)
            let angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            if !padTwo {
                padTwo = true; padSub = .none
                padTwoStartT = t; padTwoMoved = 0
                padScrollLast = c; padTwoStartC = c
                padStartDist = dist; padStartAngle = angle
                padLastDist = dist; padLastAngle = angle
                pinchAccum = 0; rotAccum = 0
                sacc = (0, 0); phaseOpen = false; scrollSign = s.scrollSign
                samples = [(t, Double(c.x), Double(c.y))]
                return
            }
            let ddx = c.x - padScrollLast.x, ddy = c.y - padScrollLast.y
            padTwoMoved += hypot(ddx, ddy)
            padMoved += hypot(ddx, ddy)

            // Same intent latch as the touchscreen: scroll vs pinch vs rotate.
            if padSub == .none {
                if s.gestureMode == .off { padSub = .scroll }
                else {
                    let dAng = angleDelta(angle, padStartAngle)
                    let spread = abs(dist - padStartDist)
                    let travel = hypot(c.x - padTwoStartC.x, c.y - padTwoStartC.y)
                    let arc = abs(dAng) * .pi / 180 * (padStartDist / 2)
                    let best = max(spread, max(travel, arc))
                    if best > s.twoCommit {
                        if spread > travel * s.pinchBias && spread >= arc { padSub = .pinch }
                        else if arc > travel && arc >= spread { padSub = .rotate }
                        else { padSub = .scroll }
                    }
                }
            }
            switch padSub {
            case .pinch:
                emitPinch(ratio: padLastDist > 0 ? (dist - padLastDist) / padLastDist : 0)
            case .rotate:
                emitRotate(deltaDegrees: angleDelta(angle, padLastAngle))
            case .scroll:
                emitScroll(rawDy: ddy, rawDx: ddx); addSample(c, t)
            case .none:
                break
            }
            padScrollLast = c
            padLastDist = dist; padLastAngle = angle
            return
        }
        // one finger
        let p = toScreen(contacts[0].x, contacts[0].y)
        if padTwo {
            // 2→1: MacBook behavior — a quick, still tap of the SECOND finger is a
            // right click, and the first finger keeps tracking afterwards.
            closeSmoothGestures()
            endScrollPhase()
            if (t - padTwoStartT) * 1000 < s.tapMaxMS && padTwoMoved < s.tapMaxMove {
                Pointer.rightClick(Pointer.location())
                padClicked = true
            }
            padTwo = false; padSub = .none
            padLast = p; padLastT = t
            return
        }
        let dx = p.x - padLast.x, dy = p.y - padLast.y
        padMoved += hypot(dx, dy)
        padLast = p
        // Tap-and-a-half: this touch followed a tap, and it's MOVING → hold the
        // button down and drag from the cursor's current position.
        if padDragArm && !padDragging && padMoved > s.slop {
            padDragging = true
            Pointer.leftDown(Pointer.location())
        }
        if dx != 0 || dy != 0 {
            let accel = padAccel(dx, dy, t - padLastT)
            var cur = Pointer.location()
            cur.x += dx * s.trackpadGain * accel
            cur.y += dy * s.trackpadGain * accel
            if padDragging { Pointer.leftDrag(cur) } else { Pointer.move(cur) }
        }
        padLastT = t
    }

    private func isPadTap(_ t: Double) -> Bool {
        padMoved < s.tapMaxMove && (t - padStartT) * 1000 < s.tapMaxMS
    }

    // 3+ finger swipe -> Mission Control / App Exposé / switch Spaces, via Ctrl+arrow
    // keystrokes (this gesture can't be animated by either engine — see INTERNALS.md §5).
    private func handleSwipe(_ contacts: [Contact], _ t: Double) {
        let n = Double(contacts.count)
        let cx = contacts.reduce(0.0) { $0 + Double($1.x) } / n
        let cy = contacts.reduce(0.0) { $0 + Double($1.y) } / n
        if mode != .swiping {
            mode = .swiping; swipeStart = (cx, cy); swipeFired = false
            swipeStartT = t
            // Band at the bottom of the SCREEN (matches the visible edge strip).
            let scr = toScreen(Int(cx), Int(cy))
            swipeFromBottom = scr.y > bounds.maxY - s.edgeZonePts
            return
        }
        // live zone feedback: fingers resting (1) → armed after dwell (2)
        if s.edgeGestures && swipeFromBottom && !swipeFired {
            setZone(bottom: true, (t - swipeStartT) * 1000 >= s.edgeDwellMS ? 2 : 1)
        }
        if swipeFired { return }
        let dx = cx - swipeStart.x, dy = cy - swipeStart.y
        if abs(dx) < swipeMin && abs(dy) < swipeMin { return }
        if abs(dy) >= abs(dx) {
            // Pull UP from the bottom edge, after a dwell, opens the on-screen keyboard.
            // A quick 3-finger up elsewhere is Mission Control; down is App Exposé.
            if dy < 0 && s.edgeGestures && swipeFromBottom
                && (t - swipeStartT) * 1000 >= s.edgeDwellMS {
                onShowKeyboard?()
            } else {
                Pointer.keyFlagged(dy < 0 ? Pointer.kUp : Pointer.kDown, .maskControl)
            }
        } else {
            // left / right = switch Spaces (desktops)
            Pointer.keyFlagged(dx < 0 ? Pointer.kLeft : Pointer.kRight, .maskControl)
        }
        swipeFired = true
    }

    // Always send the matching `ended` for any open magnify/rotate gesture.
    // Failing to do this leaves macOS's recognizer stuck mid-gesture, which
    // freezes ALL gestures (display + trackpad) until our process exits.
    private func closeSmoothGestures() {
        if magOpen { GestureSynth.shared.magnify(0, phase: 4); magOpen = false }  // 4 = ended
        if rotOpen { GestureSynth.shared.rotate(0, phase: 4); rotOpen = false }
    }

    private func isTwoFingerTap(_ t: Double) -> Bool {
        twoMoved < s.tapMaxMove && (t - twoStartT) * 1000 < s.tapMaxMS
    }

    // MARK: shared gesture emission (touchscreen two-finger path + virtual pad)
    private enum Step {
        static let legacyZoom = 0.12         // accumulated pinch ratio per ⌘+ / ⌘– press
        static let legacyRotateDeg = 25.0    // accumulated degrees per ⌘L / ⌘R press
        static let padAccelMin = 0.5         // trackpad acceleration curve bounds
        static let padAccelMax = 3.0
        static let padAccelRef = 500.0       // px/s at which gain has grown by 1×
    }

    /// Smallest signed angle difference, wrapping at ±180°.
    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        return d
    }

    private func emitPinch(ratio: Double) {
        if s.gestureMode == .shortcuts {
            pinchAccum += ratio
            while pinchAccum > Step.legacyZoom {
                Pointer.keyFlagged(Pointer.kEqual, .maskCommand); pinchAccum -= Step.legacyZoom
            }
            while pinchAccum < -Step.legacyZoom {
                Pointer.keyFlagged(Pointer.kMinus, .maskCommand); pinchAccum += Step.legacyZoom
            }
        } else {
            GestureSynth.shared.magnify(ratio * s.magnifyGain, phase: magOpen ? 2 : 1)
            magOpen = true
        }
    }

    private func emitRotate(deltaDegrees dAng: Double) {
        if s.gestureMode == .shortcuts {
            rotAccum += dAng
            while rotAccum > Step.legacyRotateDeg {
                Pointer.keyFlagged(Pointer.kR, .maskCommand); rotAccum -= Step.legacyRotateDeg
            }
            while rotAccum < -Step.legacyRotateDeg {
                Pointer.keyFlagged(Pointer.kL, .maskCommand); rotAccum += Step.legacyRotateDeg
            }
        } else {
            GestureSynth.shared.rotate(-dAng, phase: rotOpen ? 2 : 1)
            rotOpen = true
        }
    }

    /// MacBook-like pointer acceleration for the virtual pad.
    private func padAccel(_ dx: Double, _ dy: Double, _ dt: Double) -> Double {
        let speed = hypot(dx, dy) / max(dt, 0.004)
        return min(Step.padAccelMax, max(Step.padAccelMin, Step.padAccelMin + speed / Step.padAccelRef))
    }

    private func handleTwoFinger(_ contacts: [Contact], _ t: Double) {
        // Sort by contact id so the two fingers keep a stable order frame-to-frame;
        // otherwise a swap flips the angle 180° and jitters pinch/rotate.
        let cs = contacts.sorted { $0.id < $1.id }
        let a = toScreen(cs[0].x, cs[0].y)
        let b = toScreen(cs[1].x, cs[1].y)
        let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2
        let centroid = CGPoint(x: cx, y: cy)
        let dist = hypot(b.x - a.x, b.y - a.y)
        let angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        pLast = centroid

        if mode != .scrolling {
            mode = .scrolling; scrollLast = centroid
            twoStartT = t; twoMoved = 0
            vel = (0, 0); sacc = (0, 0); phaseOpen = false
            scrollSign = s.scrollSign
            lastDist = dist; lastAngle = angle
            magOpen = false; rotOpen = false; twoSub = .none
            pinchAccum = 0; rotAccum = 0; panFired = false; notifFired = false
            rcFired = false; kbFired = false
            // Edge bands (match the visible strips; the side band is 1.5× deeper).
            twoFromRightEdge = cx > bounds.maxX - s.edgeZonePts * 1.5
            twoFromBottomEdge = cy > bounds.maxY - s.edgeZonePts
            twoStartCx = cx; twoStartCy = cy
            twoStartDist = dist; twoStartAngle = angle
            samples = [(t, cx, cy)]
            return
        }

        let dx = cx - scrollLast.x, dy = cy - scrollLast.y
        twoMoved += hypot(dx, dy)

        // Plain two-finger scroll when gestures are off.
        if s.gestureMode == .off {
            emitScroll(rawDy: dy, rawDx: dx)
            addSample(centroid, t)
            scrollLast = centroid
            lastDist = dist; lastAngle = angle
            return
        }

        // Decide intent in ONE comparable unit (accumulated screen points since
        // touchdown), so a 0.4% jitter in finger spread can't out-vote a real
        // scroll the way a raw ratio did. Whichever signal first exceeds
        // `twoCommit` points locks the gesture for the rest of the sequence.
        let hTravel = cx - twoStartCx, vTravel = cy - twoStartCy

        // Notification Center: dwell two fingers at the right edge, then pull left.
        if s.edgeGestures, twoFromRightEdge, !notifFired, twoSub == .none {
            let armed = (t - twoStartT) * 1000 >= s.edgeDwellMS
            setZone(bottom: false, armed ? 2 : 1)   // live zone feedback
            if armed, (twoStartCx - cx) > s.edgePull {
                onNotificationCenter?(); notifFired = true; mode = .consumed
                setZone(bottom: false, 0)
                return
            }
        } else if zoneStRight != 0 {
            setZone(bottom: false, 0)
        }

        // On-screen keyboard: dwell TWO fingers at the bottom edge, then pull up
        // (easier than the 3-finger pull, which still works too).
        if s.edgeGestures, twoFromBottomEdge, !kbFired, twoSub == .none {
            let armed = (t - twoStartT) * 1000 >= s.edgeDwellMS
            setZone(bottom: true, armed ? 2 : 1)
            if armed, (twoStartCy - cy) > s.edgePull {
                onShowKeyboard?(); kbFired = true; mode = .consumed
                setZone(bottom: true, 0)
                return
            }
        } else if zoneStBottom != 0, twoSub != .none {
            setZone(bottom: true, 0)
        }

        if twoSub == .none {
            let dAng = angleDelta(angle, twoStartAngle)
            let spread = abs(dist - twoStartDist)                       // pinch signal
            let travel = hypot(hTravel, vTravel)                        // scroll/swipe signal
            let arc = abs(dAng) * .pi / 180 * (twoStartDist / 2)        // rotate signal (arc len)
            let best = max(spread, max(travel, arc))
            if best > s.twoCommit {
                // Bias toward scroll (by far the most common 2-finger action):
                // a pinch must beat centroid travel by `pinchBias`× to win, else the
                // small spread drift that happens during every scroll would keep
                // mis-latching as zoom. Same idea for rotate.
                if spread > travel * s.pinchBias && spread >= arc { twoSub = .pinch }
                else if arc > travel && arc >= spread { twoSub = .rotate }
                // Shortcuts mode: a horizontal swipe is back/forward, not scroll.
                else if s.gestureMode == .shortcuts && abs(hTravel) > abs(vTravel) { twoSub = .pan }
                // When one-finger scroll (iPad mode) is on, two fingers are RESERVED
                // for gestures — don't latch scroll, so pinch/rotate stay stable.
                // (A horizontal swipe still navigates via the release-commit below.)
                else if !s.ipadMode { twoSub = .scroll }
                if twoSub != .none { Pointer.move(centroid) }
            }
        }
        switch twoSub {
        case .pinch:
            emitPinch(ratio: lastDist > 0 ? (dist - lastDist) / lastDist : 0)
        case .rotate:
            emitRotate(deltaDegrees: angleDelta(angle, lastAngle))
        case .pan:
            // Shortcuts mode: fire ⌘[ / ⌘] once, but only after the swipe has
            // traveled `pageSwipePts` — same knob as Smooth mode, so it's tunable
            // and not twitchy. ⌘[ = back, ⌘] = forward (Safari / Chrome / Finder).
            if !panFired && abs(hTravel) > s.pageSwipePts {
                Pointer.keyFlagged(hTravel < 0 ? Pointer.kLeftBracket : Pointer.kRightBracket,
                                   .maskCommand)
                panFired = true
            }
        case .scroll:
            emitScroll(rawDy: dy, rawDx: dx); addSample(centroid, t)
        case .none:
            break
        }
        scrollLast = centroid
        lastDist = dist; lastAngle = angle
    }

    // MARK: scroll phase helpers
    private func emitScroll(rawDy: Double, rawDx: Double) {
        // Scroll is delivered to the window under the cursor, so cancel any
        // pending cursor-restore: the pointer must stay over what you're
        // scrolling, or the next stroke (and momentum) hits the wrong window.
        preTouchPos = nil
        sacc.y += scrollSign * rawDy; sacc.x += scrollSign * rawDx
        let iy = Int32(sacc.y), ix = Int32(sacc.x)
        if iy != 0 || ix != 0 {
            Pointer.scroll(dy: iy, dx: ix, phase: phaseOpen ? Pointer.phChanged : Pointer.phBegan)
            phaseOpen = true
            sacc.y -= Double(iy); sacc.x -= Double(ix)
        }
    }
    private func endScrollPhase() {
        if phaseOpen { Pointer.scroll(dy: 0, dx: 0, phase: Pointer.phEnded); phaseOpen = false }
    }

    // MARK: momentum
    private func beginMomentum(_ t: Double, oneFinger: Bool) {
        endScrollPhase(); mode = .momentum; lastMom = t; acc = (0, 0); momOpen = false
        momHoldFrames = 0
        scrollSign = s.scrollSign
        momGain = oneFinger ? s.oneFingerInertiaGain : s.momentumGain
    }
    private func stepMomentum(_ t: Double) {
        let dt = min(t - lastMom, 0.05); lastMom = t
        lastActionTime = t                  // coasting counts as activity (delay restore)
        acc.y += scrollSign * vel.y * dt * momGain
        acc.x += scrollSign * vel.x * dt * momGain
        let iy = Int32(acc.y), ix = Int32(acc.x)
        if iy != 0 || ix != 0 {
            Pointer.scroll(dy: iy, dx: ix, momentum: momOpen ? Pointer.momContinue : Pointer.momBegin)
            momOpen = true
            acc.y -= Double(iy); acc.x -= Double(ix)
        }
        let decay = pow(s.friction, dt / 0.016)
        vel.x *= decay; vel.y *= decay
        if hypot(vel.x, vel.y) < s.stopMin { endMomentum(); mode = .idle }
    }
    private func endMomentum() { if momOpen { Pointer.scroll(dy: 0, dx: 0, momentum: Pointer.momEnd); momOpen = false } }

    // MARK: velocity sampling (peak over window)
    private func addSample(_ p: CGPoint, _ t: Double) {
        samples.append((t, Double(p.x), Double(p.y)))
        while samples.count > 2 && samples[0].t < t - s.velWindow { samples.removeFirst() }
    }
    private func releaseVelocity() -> (Double, Double) {
        guard samples.count >= 2, let lastSample = samples.last else { return (0, 0) }
        let tEnd = lastSample.t
        if now() - tEnd > s.velMaxAge { return (0, 0) }
        let win = samples.filter { tEnd - $0.t <= s.velWindow }
        var best = (0.0, 0.0), bestSp = 0.0
        for i in 1..<max(win.count, 1) {
            let p0 = win[i - 1], p1 = win[i]
            let dt = p1.t - p0.t
            if dt <= 0 { continue }
            let vx = (p1.x - p0.x) / dt, vy = (p1.y - p0.y) / dt
            let sp = hypot(vx, vy)
            if sp > bestSp { bestSp = sp; best = (vx, vy) }
        }
        return best
    }
}
