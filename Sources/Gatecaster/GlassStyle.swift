import SwiftUI

// Liquid Glass experiment (Apple's macOS Tahoe 26 design language).
// `.glassEffect` only exists in the macOS 26 SDK, so it's gated twice:
//  - `#if compiler(>=6.2)`  → older Xcode still compiles (branch removed)
//  - `if #available(macOS 26, *)` → older macOS still runs (fallback style)
// Fallback = the translucent windowBackgroundColor look used until now.
extension View {
    @ViewBuilder
    func gcGlass(cornerRadius: CGFloat, fallbackOpacity: Double) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(fallbackOpacity)))
        }
        #else
        self.background(RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(fallbackOpacity)))
        #endif
    }

    @ViewBuilder
    func gcGlassCapsule(fallbackOpacity: Double) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(fallbackOpacity)))
        }
        #else
        self.background(Capsule()
            .fill(Color(nsColor: .windowBackgroundColor).opacity(fallbackOpacity)))
        #endif
    }
}
