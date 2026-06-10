import Cocoa
import SwiftUI

/// Corner "bean" that resizes its window. IMPORTANT: event-driven (separate
/// mouseDown/Dragged/Up overrides), NOT a nextEvent tracking loop — a tracking
/// loop switches the run loop to event-tracking mode, which would pause the HID
/// callbacks that generate our synthetic drag events and deadlock touch input.
struct ResizeHandle: NSViewRepresentable {
    final class ResizeView: NSView {
        private var lastGlobal: NSPoint?
        override func mouseDown(with event: NSEvent) { lastGlobal = NSEvent.mouseLocation }
        override func mouseUp(with event: NSEvent) { lastGlobal = nil }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window, let last = lastGlobal else { return }
            let now = NSEvent.mouseLocation
            var f = w.frame
            f.size.width = max(300, f.width + (now.x - last.x))
            let dy = now.y - last.y           // AppKit y-up: keep the TOP edge fixed
            f.origin.y += dy
            f.size.height = max(170, f.height - dy)
            w.setFrame(f, display: true)
            lastGlobal = now
        }
    }
    func makeNSView(context: Context) -> NSView { ResizeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Mouse-only window drag, restricted to the title bar. Panels have
/// `isMovableByWindowBackground = false` (dragging the body moved the window
/// under sliders), so this view re-enables window dragging just on the header
/// for mouse users. Touch uses the engine's top-bar panelDrag instead. Place
/// it as a `.background` of the header; foreground buttons consume their own
/// clicks, so only empty header areas start a drag.
struct TitleBarDrag: NSViewRepresentable {
    final class V: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A small visible grip that marks the draggable title bar.
struct DragHandle: View {
    var body: some View {
        Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5)
    }
}

/// The visual bean + the resize behavior, for panel header bars.
struct ResizeBean: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color.secondary.opacity(0.35))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
            ResizeHandle()
        }
        .frame(width: 52, height: 28)
    }
}

/// Live state of the edge-gesture zones, pushed by the Engine.
/// 0 = idle · 1 = right finger count resting in the zone · 2 = armed (dwell done).
final class EdgeZoneStates: ObservableObject {
    @Published var bottom = 0
    @Published var right = 0
}

/// Pass-through strip marking an edge-gesture zone (bottom = keyboard, right =
/// Notification Center), with live feedback: idle = faint accent, fingers
/// detected = lighter blue, armed (ready to pull) = black. The hosting panel
/// ignores mouse events — the Engine does the actual detection.
struct EdgeHintView: View {
    var horizontal: Bool
    @ObservedObject var states: EdgeZoneStates

    private var st: Int { horizontal ? states.bottom : states.right }

    private var fill: Color {
        switch st {
        case 2:  return Color.black.opacity(0.65)          // armed — pull now
        case 1:  return Color.blue.opacity(0.40)           // fingers detected
        default: return Color.accentColor.opacity(0.14)    // idle
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(fill)
            Rectangle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            Image(systemName: horizontal ? "keyboard.chevron.compact.down" : "bell")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(st == 2 ? .white : .accentColor.opacity(0.8))
        }
        .animation(.easeInOut(duration: 0.12), value: st)
    }
}

/// A virtual trackpad: the surface is intentionally inert — the Engine intercepts
/// touches that start inside it (`trackpadRect`) and converts them to RELATIVE
/// pointer movement, tap-to-click, and two-finger scroll, exactly like a physical
/// trackpad. Useful when there's no mouse or trackpad attached at all.
struct TrackpadView: View {
    @ObservedObject var settings: AppSettings
    var onHide: () -> Void

    var body: some View {
        VStack(spacing: 6) {
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

            ZStack {
                RoundedRectangle(cornerRadius: GC.Radius.tile)
                    .fill(Color(nsColor: .controlColor).opacity(0.45))
                VStack(spacing: 4) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 26)).foregroundColor(.secondary.opacity(0.5))
                    Text("Trackpad — move, tap, 2-finger scroll")
                        .font(.system(size: 12)).foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(8)
        // Always-live blur: Liquid Glass froze a stale snapshot when these
        // never-key panels lost focus (macOS 26), so all panels use this.
        .gcActiveBlur(cornerRadius: GC.Radius.panel, blur: settings.panelBlur, opacity: settings.keyboardOpacity)
    }
}
