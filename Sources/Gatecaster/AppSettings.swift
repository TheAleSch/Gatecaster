import Foundation
import Combine

/// How multi-touch gestures (pinch / rotate / swipe) are produced.
enum GestureMode: String, Codable, CaseIterable, Identifiable {
    case off            // scroll only — no pinch/rotate/swipe
    case smooth         // synthesized trackpad events (animated zoom/rotate)
    case shortcuts      // keyboard shortcuts (reliable; enables desktop switching)
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .smooth: return "Smooth"
        case .shortcuts: return "Legacy"
        }
    }
    var caption: String {
        switch self {
        case .off: return "Two-finger scrolling only. No zoom, rotate, or swipe."
        case .smooth: return "Animated pinch-zoom and rotate via synthesized trackpad events. Most native feel."
        case .shortcuts: return "Legacy: gestures fire keyboard shortcuts instead of trackpad events — works in every app, including switching desktops, but without the live animation."
        }
    }
}

/// How a right-click is produced from touch.
enum RightClickMode: String, Codable, CaseIterable, Identifiable {
    case hold            // press one finger and hold still
    case twoFingerTap    // tap with two fingers together (also enables hold+2nd tap)
    case secondFinger    // hold one finger, TAP a second (MacBook style) — only that
    case both            // everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hold: return "Touch & hold"
        case .twoFingerTap: return "2-finger tap"
        case .secondFinger: return "Hold + 2nd tap"
        case .both: return "All"
        }
    }
    var usesHold: Bool { self == .hold || self == .both }
    var usesTwoFingerTap: Bool { self == .twoFingerTap || self == .both }
    /// Hold one finger, tap a second → immediate right click at the held finger.
    var usesSecondFingerTap: Bool {
        self == .secondFinger || self == .twoFingerTap || self == .both
    }
}

/// Single source of truth for every user-tunable behavior, mode, and the panel
/// calibration. Shared live by the Engine (reads it every frame) and the SwiftUI
/// settings window (binds to it). Persists to ~/v17ut-settings.json with a small
/// debounce so edits survive relaunch.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: modes / toggles
    @Published var gestureMode: GestureMode = .smooth   // pinch/rotate/swipe engine
    @Published var threeFingerEnabled = true  // 3-finger Mission Control / Spaces / Exposé
    @Published var ipadMode = true            // one-finger drag scrolls instead of dragging
    @Published var naturalScroll = true       // content tracks the fingers
    @Published var inertia = true             // flick-to-coast momentum
    @Published var restoreCursor = true       // snap pointer back after a tap
    @Published var verbose = false            // log to stderr
    @Published var rightClickMode: RightClickMode = .twoFingerTap

    // MARK: palm rejection
    @Published var palmRejection = true       // ignore palm-like contacts entirely
    @Published var palmPanelGuard = true      // while typing/padding on a panel, ignore new off-panel touches
    @Published var palmClusterPts = 56.0      // 3+ contacts bunched tighter than this = palm

    // MARK: timing / feel (all in ms unless noted)
    @Published var slop = 8.0                  // px before a touch counts as movement
    @Published var holdMS = 550.0             // press-and-hold time for right-click
    @Published var tapMaxMS = 220.0           // max duration still counted as a tap
    @Published var tapMaxMove = 14.0          // max px movement still counted as a tap
    @Published var touchSettleMS = 25.0       // delay before one finger commits to a drag
    @Published var liftGraceMS = 70.0         // grace after a finger drops out of a gesture

    // MARK: scrolling / inertia
    @Published var friction = 0.92            // momentum decay per 16 ms (higher = longer)
    @Published var momentumGain = 4.5         // two-finger flick coast speed
    @Published var oneFingerInertiaGain = 4.9 // one-finger flick coast speed (faster)
    @Published var flickMin = 75.0            // min release speed (px/s) to start a coast
    @Published var flickFromTap = 110.0       // min speed for a one-finger tap-flick to coast
    @Published var stopMin = 30.0             // coast stops below this speed
    @Published var velWindow = 0.08           // s: window for peak release-velocity
    @Published var velMaxAge = 0.20           // s: ignore release velocity older than this
    @Published var liftTimeout = 0.13         // s: silence before assuming a lift

    // MARK: gestures
    @Published var magnifyGain = 3.0          // pinch sensitivity
    @Published var twoCommit = 12.0           // px of travel before a 2-finger intent locks
    @Published var pinchBias = 1.6            // pinch must beat scroll travel by this factor
    @Published var pageSwipePts = 110.0       // horizontal travel to commit Safari back/forward (Smooth mode)

    // MARK: cursor restore
    @Published var restoreDelayMS = 20.0      // quiet time before snapping the pointer back

    // MARK: edge gestures & on-screen keyboard
    @Published var edgeGestures = true        // 3-finger bottom pull = keyboard; 2-finger right pull = Notif Center
    @Published var edgeDwellMS = 0.0          // rest fingers this long before an edge pull counts
    @Published var edgePull = 30.0            // screen points of inward pull to fire an edge gesture
    @Published var edgeZonePts = 72.0         // depth of the edge detection bands (screen points)
    @Published var showEdgeZones = false      // DEBUG: draw the detection bands on screen
    @Published var keyboardOpacity = 0.85     // on-screen keyboard window opacity (0.3–1.0)
    @Published var keyboardExtendedKeys = true // esc/F1–F12 row + ⌘⌥⌃fn modifier keys
    @Published var keyboardLayout = "us"       // us / fr / es / pt / zh / ja (keycap labels)
    @Published var keyboardNumpad = false      // numeric keypad column
    @Published var keyPressFeedback = true     // iOS-style highlight + dip on key press
    @Published var keyPopup = true             // magnified key-pop callout above letter keys
    @Published var showFloatingControl = false // draggable touch launcher panel
    @Published var showTrackpad = false        // virtual trackpad panel
    @Published var showDeck = false            // Stream Deck-style control surface (v3 PoC)
    @Published var deckCellSize = 104.0        // deck grid block size (pt); bigger = chunkier tiles
    @Published var panelBlur = true            // live glass blur behind panels; off = flat translucent (cheaper)
    @Published var trackpadGain = 1.5          // virtual trackpad cursor sensitivity

    // MARK: calibration — raw panel coords that map to the screen edges
    @Published var calXMin = 0.0
    @Published var calXMax = 2624.0
    @Published var calYMin = 0.0
    @Published var calYMax = 1856.0

    // Live info (not persisted): the touch controller currently attached.
    @Published var connectedHardware = "Not connected"

    // MARK: chosen display (which screen the touch panel maps to)
    @Published var hasPickedDisplay = false
    @Published var displayID = 0.0      // CGDirectDisplayID for the live session (not stable)
    @Published var displayUUID = ""     // STABLE id, persisted + resolved across relaunch/reconnect

    // Derived sign (natural applies identically to one- and two-finger scroll).
    var scrollSign: Double { naturalScroll ? 1 : -1 }

    // MARK: persistence
    private struct Snapshot: Codable {
        var gestureMode: GestureMode?        // optional: tolerate older settings files
        var threeFingerEnabled: Bool?
        var ipadMode, naturalScroll, inertia, restoreCursor, verbose: Bool
        var rightClickMode: RightClickMode
        var slop, holdMS, tapMaxMS, tapMaxMove, touchSettleMS, liftGraceMS: Double
        var friction, momentumGain, oneFingerInertiaGain, flickMin, flickFromTap, stopMin: Double
        var velWindow, velMaxAge, liftTimeout: Double
        var magnifyGain, twoCommit, pinchBias, restoreDelayMS: Double
        var pageSwipePts: Double?
        var calXMin, calXMax, calYMin, calYMax: Double
        var hasPickedDisplay: Bool
        var displayID: Double
        var displayUUID: String?
        var edgeGestures: Bool?
        var edgeDwellMS: Double?
        var edgePull: Double?
        var edgeZonePts: Double?
        var showEdgeZones: Bool?
        var keyboardOpacity: Double?
        var keyboardExtendedKeys: Bool?
        var keyboardLayout: String?
        var keyboardNumpad: Bool?
        var showFloatingControl: Bool?
        var showTrackpad: Bool?
        var trackpadGain: Double?
        var palmRejection: Bool?
        var palmPanelGuard: Bool?
        var palmClusterPts: Double?
        var showDeck: Bool?
        var panelBlur: Bool?
        var keyPressFeedback: Bool?
        var keyPopup: Bool?
        var deckCellSize: Double?
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("v17ut-settings.json")

    private var bag: AnyCancellable?

    private init() {
        load()
        // Debounced autosave whenever any @Published value changes.
        bag = objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    private var snapshot: Snapshot {
        Snapshot(gestureMode: gestureMode, threeFingerEnabled: threeFingerEnabled,
                 ipadMode: ipadMode,
                 naturalScroll: naturalScroll, inertia: inertia,
                 restoreCursor: restoreCursor, verbose: verbose,
                 rightClickMode: rightClickMode,
                 slop: slop, holdMS: holdMS, tapMaxMS: tapMaxMS, tapMaxMove: tapMaxMove,
                 touchSettleMS: touchSettleMS, liftGraceMS: liftGraceMS,
                 friction: friction, momentumGain: momentumGain,
                 oneFingerInertiaGain: oneFingerInertiaGain, flickMin: flickMin,
                 flickFromTap: flickFromTap, stopMin: stopMin,
                 velWindow: velWindow, velMaxAge: velMaxAge, liftTimeout: liftTimeout,
                 magnifyGain: magnifyGain, twoCommit: twoCommit, pinchBias: pinchBias,
                 restoreDelayMS: restoreDelayMS, pageSwipePts: pageSwipePts,
                 calXMin: calXMin, calXMax: calXMax, calYMin: calYMin, calYMax: calYMax,
                 hasPickedDisplay: hasPickedDisplay, displayID: displayID, displayUUID: displayUUID,
                 edgeGestures: edgeGestures, edgeDwellMS: edgeDwellMS, edgePull: edgePull,
                 edgeZonePts: edgeZonePts, showEdgeZones: showEdgeZones,
                 keyboardOpacity: keyboardOpacity, keyboardExtendedKeys: keyboardExtendedKeys,
                 keyboardLayout: keyboardLayout, keyboardNumpad: keyboardNumpad,
                 showFloatingControl: showFloatingControl,
                 showTrackpad: showTrackpad, trackpadGain: trackpadGain,
                 palmRejection: palmRejection, palmPanelGuard: palmPanelGuard,
                 palmClusterPts: palmClusterPts, showDeck: showDeck,
                 panelBlur: panelBlur, keyPressFeedback: keyPressFeedback,
                 keyPopup: keyPopup, deckCellSize: deckCellSize)
    }

    private func apply(_ s: Snapshot) {
        gestureMode = s.gestureMode ?? .smooth
        threeFingerEnabled = s.threeFingerEnabled ?? true
        ipadMode = s.ipadMode
        naturalScroll = s.naturalScroll; inertia = s.inertia
        restoreCursor = s.restoreCursor; verbose = s.verbose
        rightClickMode = s.rightClickMode
        slop = s.slop; holdMS = s.holdMS; tapMaxMS = s.tapMaxMS; tapMaxMove = s.tapMaxMove
        touchSettleMS = s.touchSettleMS; liftGraceMS = s.liftGraceMS
        friction = s.friction; momentumGain = s.momentumGain
        oneFingerInertiaGain = s.oneFingerInertiaGain; flickMin = s.flickMin
        flickFromTap = s.flickFromTap; stopMin = s.stopMin
        velWindow = s.velWindow; velMaxAge = s.velMaxAge; liftTimeout = s.liftTimeout
        magnifyGain = s.magnifyGain; twoCommit = s.twoCommit; pinchBias = s.pinchBias
        restoreDelayMS = s.restoreDelayMS
        pageSwipePts = s.pageSwipePts ?? 110
        calXMin = s.calXMin; calXMax = s.calXMax; calYMin = s.calYMin; calYMax = s.calYMax
        hasPickedDisplay = s.hasPickedDisplay; displayID = s.displayID
        displayUUID = s.displayUUID ?? ""
        edgeGestures = s.edgeGestures ?? true
        edgeDwellMS = s.edgeDwellMS ?? 0
        edgePull = s.edgePull ?? 30
        edgeZonePts = s.edgeZonePts ?? 72
        showEdgeZones = s.showEdgeZones ?? false
        keyboardOpacity = s.keyboardOpacity ?? 0.85
        keyboardExtendedKeys = s.keyboardExtendedKeys ?? true
        keyboardLayout = s.keyboardLayout ?? "us"
        keyboardNumpad = s.keyboardNumpad ?? false
        showFloatingControl = s.showFloatingControl ?? false
        showTrackpad = s.showTrackpad ?? false
        trackpadGain = s.trackpadGain ?? 1.5
        palmRejection = s.palmRejection ?? true
        palmPanelGuard = s.palmPanelGuard ?? true
        palmClusterPts = s.palmClusterPts ?? 56
        showDeck = s.showDeck ?? false
        panelBlur = s.panelBlur ?? true
        keyPressFeedback = s.keyPressFeedback ?? true
        keyPopup = s.keyPopup ?? true
        deckCellSize = s.deckCellSize ?? 104
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .atomic: a crash mid-write can't corrupt the settings file.
        if let data = try? enc.encode(snapshot) {
            try? data.write(to: Self.url, options: [.atomic])
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        apply(s)
    }

    /// Restore every value to its built-in default.
    func resetToDefaults() { apply(AppSettings.defaults) }

    private static let defaults = Snapshot(
        gestureMode: .smooth, threeFingerEnabled: true,
        ipadMode: true, naturalScroll: true, inertia: true,
        restoreCursor: true, verbose: false, rightClickMode: .twoFingerTap,
        slop: 8, holdMS: 550, tapMaxMS: 220, tapMaxMove: 14, touchSettleMS: 25, liftGraceMS: 70,
        friction: 0.92, momentumGain: 4.5, oneFingerInertiaGain: 4.9, flickMin: 75,
        flickFromTap: 110, stopMin: 30, velWindow: 0.08, velMaxAge: 0.20, liftTimeout: 0.13,
        magnifyGain: 3.0, twoCommit: 12, pinchBias: 1.6, restoreDelayMS: 20, pageSwipePts: 110,
        calXMin: 0, calXMax: 2624, calYMin: 0, calYMax: 1856,
        hasPickedDisplay: false, displayID: 0, displayUUID: "",
        edgeGestures: true, edgeDwellMS: 0, edgePull: 30, edgeZonePts: 72,
        showEdgeZones: false, keyboardOpacity: 0.85,
        keyboardExtendedKeys: true, keyboardLayout: "us", keyboardNumpad: false,
        showFloatingControl: false, showTrackpad: false, trackpadGain: 1.5,
        palmRejection: true, palmPanelGuard: true, palmClusterPts: 56,
        showDeck: false, panelBlur: true,
        keyPressFeedback: true, keyPopup: true, deckCellSize: 104)
}
