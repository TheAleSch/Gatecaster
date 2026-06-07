import Cocoa
import GestureKit

/// Read-only learning tool: a listen-only CGEventTap on the gesture event
/// types, logging how macOS encodes real trackpad magnify/rotate/swipe events
/// (NSEvent global monitors don't deliver gesture events; an event tap does).
/// Nothing is posted or modified — completely safe.
final class Capture {
    private var tap: CFMachPort?
    private var src: CFRunLoopSource?

    var isRunning: Bool { tap != nil }
    func toggle() { isRunning ? stop() : start() }

    func start() {
        // gesture-family CGEventTypes: rotate(18) begin(19) end(20)
        // gesture(29) magnify(30) swipe(31) smartMagnify(32)
        let types: [UInt64] = [18, 19, 20, 29, 30, 31, 32]
        var mask: UInt64 = 0
        for t in types { mask |= (1 << t) }

        let cb: CGEventTapCallBack = { _, _, event, _ in
            Capture.logNS(event)      // let AppKit name the gesture
            gk_dump_event(event)      // then the raw fields
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask),
            callback: cb, userInfo: nil)
        else {
            err("[capture] tap creation failed — grant Accessibility + Input Monitoring\n")
            return
        }
        self.tap = tap
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        src = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        err("[capture] ON — pinch / rotate / 3-finger swipe on your trackpad now\n")
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let s = src { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; src = nil
        err("[capture] OFF\n")
    }

    private func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    // Let AppKit classify the event — ground truth, not my guess.
    private static var lastNS = ""
    static func logNS(_ cg: CGEvent) {
        guard let e = NSEvent(cgEvent: cg) else { return }
        let phase = e.phase.rawValue
        var s: String
        switch e.type {
        case .magnify: s = String(format: ">> MAGNIFY  magnification=%.4f", e.magnification)
        case .rotate:  s = String(format: ">> ROTATE   rotation=%.4f", e.rotation)
        case .swipe:   s = String(format: ">> SWIPE    dx=%.3f dy=%.3f", e.deltaX, e.deltaY)
        case .scrollWheel:
            s = String(format: ">> SCROLL   dx=%.3f dy=%.3f", e.scrollingDeltaX, e.scrollingDeltaY)
        case .gesture:
            if phase == 0 { return }          // idle container -> skip noise
            s = ">> GESTURE (container)"
        case .beginGesture: s = ">> BEGIN GESTURE"
        case .endGesture:   s = ">> END GESTURE"
        case .smartMagnify: s = ">> SMART MAGNIFY"
        default: return
        }
        let line = s + String(format: "  phase=%lu", phase)
        if line == lastNS { return }          // skip exact repeats
        lastNS = line
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
