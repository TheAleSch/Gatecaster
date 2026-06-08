import SwiftUI
import AppKit

/// Hosting view for our floating panels. Panels are non-activating (they must
/// never steal focus), so AppKit treats them as permanently INACTIVE — and an
/// inactive window's blur backdrop is a frozen snapshot, not a live sample
/// (`NSVisualEffectView.state` defaults to `.followsWindowActiveState`).
/// After every layout pass, force any effect view in the hierarchy to
/// `.active` so the glass keeps sampling what's actually behind the panel.
final class GlassHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        Self.activateEffects(self)
    }
    private static func activateEffects(_ v: NSView) {
        if let e = v as? NSVisualEffectView, e.state != .active { e.state = .active }
        for sub in v.subviews { activateEffects(sub) }
    }
    required init(rootView: Content) { super.init(rootView: rootView) }
    @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

/// Always-live blur for never-activating panels. Liquid Glass
/// (NSGlassEffectView) intentionally flattens to gray when its window is
/// unfocused and has NO public always-active control — but classic
/// NSVisualEffectView still honors `state = .active`, so it keeps sampling
/// the real background regardless of focus.
struct ActiveBlurView: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active                  // never freeze, focused or not
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.layer?.cornerRadius = cornerRadius
        v.state = .active
    }
}

extension View {
    /// Panel backdrop for never-key panels. `blur` true → live always-active
    /// glass blur (samples what's behind, focused or not). `blur` false → a
    /// flat translucent fill at `opacity` — no compositing cost, the cheaper
    /// pre-glass look (Settings → General → "Blur panel backgrounds").
    @ViewBuilder
    func gcActiveBlur(cornerRadius: CGFloat, blur: Bool = true,
                      opacity: Double = 0.9) -> some View {
        if blur {
            background(
                ZStack {
                    ActiveBlurView(cornerRadius: cornerRadius)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                })
        } else {
            background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(opacity))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)))
        }
    }
}

