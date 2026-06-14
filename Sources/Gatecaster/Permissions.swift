import SwiftUI
import IOKit.hid

/// Live permission checklist — the pattern popularized by Rectangle / AltTab:
/// per-permission status (polled; TCC has no change notification), a Grant
/// button that triggers the system prompt, a deep link into the exact
/// System Settings pane, and Relaunch (TCC grants apply on next launch).
/// Shared by the Settings window and the onboarding Permissions step.
struct PermissionsView: View {
    @State private var axGranted = AXIsProcessTrusted()
    @State private var inputGranted =
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(name: "Accessibility",
                detail: "Lets Gatecaster move the pointer, click, and post gestures.",
                granted: axGranted,
                grant: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                                as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                },
                pane: "Privacy_Accessibility")
            Divider()
            row(name: "Input Monitoring",
                detail: "Lets Gatecaster read raw touch reports from the USB controller.",
                granted: inputGranted,
                grant: { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) },
                pane: "Privacy_ListenEvent")

            if !(axGranted && inputGranted) {
                Divider()
                HStack(spacing: 8) {
                    Text("Grants take effect after a relaunch.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button("Relaunch Gatecaster") { relaunchGatecaster() }
                        .font(.system(size: 12))
                }
            }
        }
        .onReceive(poll) { _ in
            axGranted = AXIsProcessTrusted()
            inputGranted =
                IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    private func row(name: String, detail: String, granted: Bool,
                     grant: @escaping () -> Void, pane: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(granted ? "Granted" : detail)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Grant…") { grant() }.font(.system(size: 12))
                Button("Open Settings") { openPane(pane) }.font(.system(size: 12))
            }
        }
        .padding(.vertical, 3)
    }

    private func openPane(_ pane: String) {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Spawn a fresh instance, then quit. Works bundled (`open -n App.app`)
/// and unbundled (exec the bare binary). TCC grants only apply on relaunch.
func relaunchGatecaster() {
    let bundle = Bundle.main.bundlePath
    let p = Process()
    if bundle.hasSuffix(".app") {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", bundle]
    } else if let exe = Bundle.main.executablePath {
        p.executableURL = URL(fileURLWithPath: exe)
    } else { return }
    try? p.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
}
