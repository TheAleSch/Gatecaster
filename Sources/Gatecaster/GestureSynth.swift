import Foundation
import GestureKit

/// Posts synthesized trackpad gestures using the proven recipe (INTERNALS.md §4.7):
/// a type-29 gesture event based on a real mouse event, magic ints 50=248 and
/// 101=4, gesture subtype in field 110 (8 = magnify, 5 = rotate), the value in
/// double fields 113/114/116/118, and the phase in 132 (1 began / 2 changed /
/// 4 ended). The recipe is fixed and validated, so it's hardcoded — the old
/// ~/v17ut-gesture.json tuning file is no longer read and can be deleted.
final class GestureSynth {
    static let shared = GestureSynth()
    private init() {}

    // API suppression kill-switch (the "gestures" category). Set by the Touch-API
    // socket server; see the matching note on `Pointer.suppressInput`.
    static var suppressGestures = false

    func magnify(_ v: Double, phase: Int) { post(subtype: 8, v, phase) }
    func rotate(_ v: Double, phase: Int)  { post(subtype: 5, v, phase) }

    private func post(subtype: Int64, _ value: Double, _ phase: Int) {
        // CRITICAL: even while suppressed we MUST still emit the `ended` phase
        // (4). An open gesture that never receives its `ended` wedges the macOS
        // recognizer system-wide (INTERNALS.md §4.7). So suppression drops only
        // began (1) / changed (2); a closing `ended` always goes through, which
        // also can never *start* a gesture, so the screen stays clean.
        if GestureSynth.suppressGestures && phase != 4 { return }
        let ifields: [Int32] = [50, 101, 110, 132]
        let ivals: [Int64] = [248, 4, subtype, Int64(phase)]
        let dfields: [Int32] = [113, 114, 116, 118]
        let dvals: [Double] = [value, value, value, value]
        ifields.withUnsafeBufferPointer { ip in
            ivals.withUnsafeBufferPointer { vp in
                dfields.withUnsafeBufferPointer { dp in
                    dvals.withUnsafeBufferPointer { dvp in
                        gk_post_fields(29, ip.baseAddress, vp.baseAddress, Int32(ifields.count),
                                       dp.baseAddress, dvp.baseAddress, Int32(dfields.count))
                    }
                }
            }
        }
    }
}
