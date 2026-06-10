import SwiftUI

/// A small (160×160), semi-transparent, draggable touch launcher. Tap to open the
/// keyboard, cycle the gesture engine, or open Settings — without remembering an
/// edge gesture. Drag the grip (or any empty area) to move it; collapse it to a
/// thin tab on the screen edge with the chevron. The hosting panel is
/// non-activating so taps never steal focus from the app you're working in.
struct FloatingControlView: View {
    @ObservedObject var settings: AppSettings
    var onKeyboard: () -> Void
    var onTrackpad: () -> Void
    var onDeck: () -> Void
    var onSettings: () -> Void
    var onCollapse: () -> Void

    var body: some View {
        // One uniform inset on every side (GC.Space.m) so the button grid never
        // crowds the panel's rounded corners — the rows used to run edge-to-edge.
        VStack(spacing: GC.Space.s) {
            HStack {
                Capsule().fill(Color.secondary.opacity(GC.Op.grip)).frame(width: 36, height: 5)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.right.2").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(GCPressStyle()).foregroundColor(.secondary)
                .accessibilityLabel("Collapse launcher")
            }

            HStack(spacing: GC.Space.s) {
                ctlButton("keyboard", "Keys", action: onKeyboard)
                ctlButton("rectangle.and.hand.point.up.left", "Pad", action: onTrackpad)
            }
            HStack(spacing: GC.Space.s) {
                ctlButton("square.grid.2x2", "Deck", action: onDeck)
                ctlButton("hand.tap", settings.gestureMode.label, action: cycleMode)
            }
            ctlButton("gearshape", "Settings", action: onSettings)
        }
        .padding(GC.Space.m)
        .frame(width: 176, height: 232)
        .gcActiveBlur(cornerRadius: GC.Radius.panel)
    }

    private func cycleMode() {
        let all = GestureMode.allCases
        if let i = all.firstIndex(of: settings.gestureMode) {
            settings.gestureMode = all[(i + 1) % all.count]
        }
    }

    private func ctlButton(_ icon: String, _ label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21))
                Text(label).font(.system(size: 11)).lineLimit(1)
            }
            // Fill the row evenly: paired tiles split the width, a lone tile
            // (Settings) spans it — so side margins stay uniform at any panel size.
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundColor(.primary)
        }
        .buttonStyle(.bordered).controlSize(.large)
    }
}

/// The collapsed state: a thin tab pinned to the screen edge. Tap to expand.
struct FloatingTabView: View {
    var onExpand: () -> Void
    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 10) {
                // Which tab is this? The bare chevron was anonymous next to
                // the keyboard/deck tabs — the grid glyph names it.
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 22, weight: .bold))
            }
            .frame(width: 48, height: 170)
            .gcActiveBlur(cornerRadius: GC.Radius.panel)
                .contentShape(Rectangle())
        }
        .buttonStyle(GCPressStyle())
        .foregroundColor(.primary)
        .accessibilityLabel("Expand launcher")
    }
}
