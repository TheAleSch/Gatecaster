import Cocoa
import SwiftUI

/// Borderless overlay window that can still become key, so it receives the
/// number-key presses used to pick a display without a cursor.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One of these is shown full-screen on every display during first-run setup.
/// Each shows its own number large (like macOS "Identify"), plus tappable number
/// buttons and a hint that the number keys also work.
struct DisplayPickerView: View {
    let thisNumber: Int
    let total: Int
    let name: String
    var onPick: (Int) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(GC.Op.scrim).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("\(thisNumber)")
                    .font(.system(size: 170, weight: .bold))
                Text(name).font(.system(size: 22)).opacity(0.85)
                Spacer().frame(height: 8)
                Text("Which screen is your touchscreen?")
                    .font(.system(size: 24, weight: .semibold))
                Text("Tap its number below, or press that number key.")
                    .font(.system(size: 17)).opacity(0.75)
                HStack(spacing: 16) {
                    ForEach(1...max(total, 1), id: \.self) { i in
                        Button { onPick(i) } label: {
                            Text("\(i)")
                                .font(.system(size: 30, weight: .bold))
                                .frame(width: 74, height: 74)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 8)
            }
            .foregroundColor(.white)
            .padding(40)
        }
    }
}
