import SwiftUI
import AppKit

/// Shared design tokens. Every UI surface (Settings, keyboard, trackpad,
/// launcher, Deck, overlays) picks from these instead of inventing its own
/// radius/spacing/opacity — the app previously mixed 10/12/14/16/22pt corners
/// and ~14 distinct opacities for the same semantic intents.
enum GC {
    /// Corner radii. Three tiers only.
    enum Radius {
        static let panel: CGFloat = 16   // floating panel backgrounds
        static let tile: CGFloat = 12    // cards, deck tiles, inner surfaces
        static let key: CGFloat = 6      // keycaps, small chips
    }
    /// Spacing scale (4-pt grid).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }
    /// Opacity palette for recurring intents.
    enum Op {
        static let hairline = 0.10       // subtle borders on tiles/cards
        static let grip = 0.5            // drag-handle capsules
        static let scrim = 0.88          // full-screen overlay backgrounds
        static let fillSubtle = 0.15     // quiet fills (unselected chips, etc.)
    }
}

/// Pressed-state feedback for icon buttons on the touch panels. There is no
/// hover on a touchscreen and these panels never become key, so a visible
/// press dip is the ONLY confirmation a tap landed. `isPressed` works on
/// non-activating panels (KeyCapStyle relies on the same mechanism).
struct GCPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

extension View {
    /// Pin a subtree to the live SYSTEM appearance. The Deck forces
    /// `colorScheme` to match its theme, and SwiftUI leaks that override into
    /// popover *content* — but a macOS popover's bubble chrome always follows
    /// the system appearance, so a dark-themed deck on a light Mac rendered
    /// dark controls (black field, pale text) on a light bubble: unreadable.
    /// Resetting popover content to the system scheme makes chrome and content
    /// agree again, in either mode.
    func gcSystemColorScheme() -> some View {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return environment(\.colorScheme, dark ? .dark : .light)
    }
}
