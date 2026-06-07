import CoreGraphics
import Foundation

/// Thin wrappers over Quartz event posting: cursor, clicks, phase-tagged
/// momentum scroll, and keyboard combos.
enum Pointer {
    // scroll-phase / momentum-phase field ids + values (native trackpad feel).
    // Resolved once — no per-event force-unwraps in the hot path.
    private static let scrollPhaseField = CGEventField(rawValue: 99)!
    private static let momentumPhaseField = CGEventField(rawValue: 123)!
    static let phBegan: Int64 = 1, phChanged: Int64 = 2, phEnded: Int64 = 4
    static let momBegin: Int64 = 1, momContinue: Int64 = 2, momEnd: Int64 = 3

    private static func postMouse(_ type: CGEventType, _ p: CGPoint,
                                  _ button: CGMouseButton = .left) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                mouseButton: button)?.post(tap: .cghidEventTap)
    }

    static func move(_ p: CGPoint)      { postMouse(.mouseMoved, p) }

    /// Current pointer location (top-left origin), same space as `move`/`warp`.
    static func location() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Teleport the cursor without emitting a move/drag stream (used to snap the
    /// pointer back to where it was before a touch). Re-associate so the next
    /// real movement isn't briefly decoupled after the warp.
    static func warp(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Tracks whether WE believe the left button is down (watchdog uses this to
    /// recover from any path that loses the matching up-event).
    private(set) static var leftIsDown = false

    static func leftDown(_ p: CGPoint)  { leftIsDown = true; postMouse(.leftMouseDown, p) }
    static func leftUp(_ p: CGPoint)    { leftIsDown = false; postMouse(.leftMouseUp, p) }
    static func leftDrag(_ p: CGPoint)  { postMouse(.leftMouseDragged, p) }

    /// Click carrying a click count (1 = single, 2 = double, 3 = triple). Without
    /// `mouseEventClickState`, two separate tap pairs never register as a
    /// double-click in most apps.
    static func click(_ p: CGPoint, clickState: Int64 = 1) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                             mouseCursorPosition: p, mouseButton: .left)
            ev?.setIntegerValueField(.mouseEventClickState, value: clickState)
            ev?.post(tap: .cghidEventTap)
        }
    }

    static func rightClick(_ p: CGPoint) {
        postMouse(.rightMouseDown, p, .right)
        postMouse(.rightMouseUp, p, .right)
    }

    static func scroll(dy: Int32, dx: Int32, phase: Int64 = 0, momentum: Int64 = 0) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        if phase != 0 { ev.setIntegerValueField(Pointer.scrollPhaseField, value: phase) }
        if momentum != 0 { ev.setIntegerValueField(Pointer.momentumPhaseField, value: momentum) }
        ev.post(tap: .cghidEventTap)
    }

    static func keyFlagged(_ keycode: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
        }
    }

    // arrow virtual keycodes
    static let kLeft: CGKeyCode = 123, kRight: CGKeyCode = 124
    static let kDown: CGKeyCode = 125, kUp: CGKeyCode = 126

    // keys used by Legacy mode (shortcut emulation)
    static let kEqual: CGKeyCode = 24          // Cmd+=  zoom in
    static let kMinus: CGKeyCode = 27          // Cmd+-  zoom out
    static let kLeftBracket: CGKeyCode = 33    // Cmd+[  back
    static let kRightBracket: CGKeyCode = 30   // Cmd+]  forward
    static let kL: CGKeyCode = 37              // Cmd+L  rotate left (e.g. Preview)
    static let kR: CGKeyCode = 15              // Cmd+R  rotate right
}
