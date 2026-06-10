import SwiftUI

/// Collects one raw touch per on-screen target and solves a linear panel→screen
/// mapping (independent X and Y scale + offset), then writes it into AppSettings.
final class CalibrationController: ObservableObject {
    // Targets as screen fractions: the four corners, inset for comfortable tapping.
    let fractions: [CGPoint] = [
        CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
        CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9),
    ]
    @Published var index = 0
    private var raws: [(frac: CGPoint, raw: (x: Int, y: Int))] = []
    var onDone: (() -> Void)?

    var currentFraction: CGPoint { fractions[min(index, fractions.count - 1)] }
    var progress: String { "\(min(index + 1, fractions.count)) / \(fractions.count)" }

    func record(_ rawX: Int, _ rawY: Int) {
        guard index < fractions.count else { return }
        raws.append((fractions[index], (rawX, rawY)))
        index += 1
        if index >= fractions.count { finish() }
    }

    private func finish() {
        let fLo = 0.1, fHi = 0.9
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let rawXL = avg(raws.filter { $0.frac.x < 0.5 }.map { Double($0.raw.x) })
        let rawXR = avg(raws.filter { $0.frac.x > 0.5 }.map { Double($0.raw.x) })
        let rawYT = avg(raws.filter { $0.frac.y < 0.5 }.map { Double($0.raw.y) })
        let rawYB = avg(raws.filter { $0.frac.y > 0.5 }.map { Double($0.raw.y) })
        // raw = calMin + frac*(calMax-calMin)  →  solve span from the two fractions.
        let spanX = (rawXR - rawXL) / (fHi - fLo)
        let spanY = (rawYB - rawYT) / (fHi - fLo)
        if abs(spanX) > 1, abs(spanY) > 1 {
            let s = AppSettings.shared
            s.calXMin = rawXL - spanX * fLo; s.calXMax = s.calXMin + spanX
            s.calYMin = rawYT - spanY * fLo; s.calYMax = s.calYMin + spanY
            s.save()
        }
        onDone?()
    }

    func cancel() { onDone?() }
}

private struct CalTarget: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 3).frame(width: 46, height: 46)
            Circle().fill(Color.accentColor).frame(width: 16, height: 16)
        }
        .shadow(radius: 4)
    }
}

struct CalibrationView: View {
    @ObservedObject var controller: CalibrationController
    var body: some View {
        ZStack {
            Color.black.opacity(GC.Op.scrim).ignoresSafeArea()
            GeometryReader { geo in
                CalTarget()
                    .position(x: geo.size.width * controller.currentFraction.x,
                              y: geo.size.height * controller.currentFraction.y)
                    .animation(.easeInOut(duration: 0.15), value: controller.index)
            }
            VStack(spacing: 10) {
                Text("Touch Calibration").font(.system(size: 30, weight: .bold))
                Text("Tap each target with one finger").font(.system(size: 19))
                Text(controller.progress).font(.system(size: 17).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(48)
            .foregroundColor(.white)
        }
    }
}
