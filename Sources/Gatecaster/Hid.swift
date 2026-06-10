import Foundation
import IOKit
import IOKit.hid

/// Opens the Visual Beat V17UT (ELAN) touchscreen, switches it into its
/// 10-finger digitizer mode, and delivers Report ID 1 packets to `onReport`.
final class HidTouch {
    static let vendorID = 0x04f3
    static let productID = 0x5512

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    // Stable heap buffer: the HID callback keeps writing into it for the lifetime of
    // the registration, so it must NOT be a Swift Array whose storage can move.
    private let bufferSize = 256
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    var onReport: (([UInt8]) -> Void)?
    var onDeviceInfo: ((String?) -> Void)?     // product name + ids, nil on unplug

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        reportBuffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit {
        // The HID callback writes into reportBuffer for the registration's
        // lifetime — close the manager BEFORE freeing the buffer.
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer.deallocate()
    }

    func start() {
        // Prompt for Input Monitoring on first run (reading HID silently fails without it).
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: HidTouch.vendorID,
            kIOHIDProductIDKey as String: HidTouch.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<HidTouch>.fromOpaque(ctx!).takeUnretainedValue()
            me.attach(dev)
        }, ctx)
        // Track unplug so a replug is treated as a fresh attach (the panel boots
        // back into mouse mode and needs the wake handshake again).
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<HidTouch>.fromOpaque(ctx!).takeUnretainedValue()
            if me.device === dev { me.device = nil; me.onDeviceInfo?(nil) }
        }, ctx)

        // .commonModes, NOT .defaultMode: while a menu is open or a window is
        // being dragged, the main run loop leaves default mode — default-mode
        // sources go silent and touch freezes until the menu closes.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ dev: IOHIDDevice) {
        device = dev

        // Report the actual controller (product string + vendor:product ids).
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
        let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        onDeviceInfo?("\(name ?? "Touch controller") (\(String(format: "%04X:%04X", vid, pid)))")

        // Register the input-report callback before enabling, so we don't miss
        // the first digitizer packets. The buffer is a stable heap allocation.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev, reportBuffer, bufferSize,
            { ctx, _, _, _, _, report, length in
                let me = Unmanaged<HidTouch>.fromOpaque(ctx!).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                me.onReport?(bytes)
            }, ctx)

        enableMultitouch(dev)
        // On a replug, the handshake can race firmware that isn't ready yet —
        // re-send it a couple of times. (Reading the feature reports is idempotent.)
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, let d = self.device else { return }
                self.enableMultitouch(d)
            }
        }
    }

    /// Manual recovery: re-send the wake handshake; if the device never re-matched
    /// after a replug, bounce the manager so matching fires again.
    func reconnect() {
        if let d = device {
            enableMultitouch(d)
        } else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// The magic: reading the vendor feature reports flips the ELAN firmware
    /// out of single-touch mouse mode into the digitizer stream.
    private func enableMultitouch(_ dev: IOHIDDevice) {
        for reportID in [0x0a, 0x44] {
            var len = 257
            var buf = [UInt8](repeating: 0, count: len)
            _ = buf.withUnsafeMutableBufferPointer { p in
                IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature,
                                     CFIndex(reportID), p.baseAddress!, &len)
            }
        }
    }
}
