# Gatecaster Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raycast-quality first-run onboarding: full-screen Metal "vortex" intro → Welcome → Permissions → Monitor → Calibration, per `docs/superpowers/specs/2026-06-10-onboarding-design.md`.

**Architecture:** One full-screen borderless window hosts the whole experience. An `MTKView` renders the locked shader recipe (runtime-compiled MSL — no build-system changes, works on the macOS 13 floor); SwiftUI step content is overlaid centered, aligned to the same window-rect math the shader uses. `AppSettings` gains `hasOnboarded` + `onboardingStage` (auto-migrated); `main.swift` branches at launch.

**Tech Stack:** Swift / AppKit / SwiftUI / MetalKit (system framework, no Package.swift change).

**Reference:** The approved WebGL demo to port 1:1 is
`.superpowers/brainstorm/71582-1781147118/content/vortex-final.html`. All shader
constants are locked: SW=12, kepler `min(140/(r+70), 2.5)`, RUSH=14, STR=30,
AB=0.26, LENS=8, GAMP=110, GFREQ=0.03, DIVEZ=0.08. Timeline: fill 0–1.6 s, suck
1.6–4.6 s, dive+reveal together 4.6–6.0 s, then confined (clock never stops).

**Testing note:** This project has NO test suite (see CLAUDE.md). Verification
is `swift build` per task plus the manual checklist in the final task. Commit
after every task. **No `Co-Authored-By` lines in commits.**

**Project constraints that apply to every task (from CLAUDE.md):**
- No `nextEvent` tracking loops — they pause HID callbacks and deadlock touch input. Event-driven handlers only.
- All persistent state goes through `AppSettings` (single source of truth, versioned snapshot with optional fields for migration).
- Comment style: explain *why* (which constraint a line guards), not *what*.

---

### Task 1: AppSettings — `hasOnboarded` + `onboardingStage` with migration

**Files:**
- Modify: `Sources/Gatecaster/AppSettings.swift`

The Snapshot struct uses optional fields for forward/backward compatibility —
that IS the migration mechanism (no version int exists in this codebase; do not
add one). Existing users who already picked a display must skip onboarding:
`hasOnboarded` defaults to the loaded `hasPickedDisplay` value.

- [ ] **Step 1: Add the published properties**

In `AppSettings`, directly under the `// MARK: chosen display` block (after line `@Published var displayUUID = ""`), add:

```swift
    // MARK: onboarding (first-run assistant)
    @Published var hasOnboarded = false   // full Welcome→Calibration flow completed (or migrated)
    @Published var onboardingStage = 0    // resume point across the TCC-mandated relaunch
                                          // 0 welcome, 1 permissions, 2 monitor, 3 calibration
```

- [ ] **Step 2: Add Snapshot fields**

In `private struct Snapshot`, after `var displayUUID: String?`, add:

```swift
        var hasOnboarded: Bool?       // optional: absent in pre-onboarding settings files
        var onboardingStage: Int?
```

- [ ] **Step 3: Encode them in `snapshot`**

In the `snapshot` computed property, after `displayUUID: displayUUID,` add:

```swift
                 hasOnboarded: hasOnboarded, onboardingStage: onboardingStage,
```

(Argument order must match the Snapshot memberwise initializer — keep it right after `displayUUID`.)

- [ ] **Step 4: Decode with migration in `apply(_:)`**

In `apply(_:)`, after `displayUUID = s.displayUUID ?? ""`, add:

```swift
        // MIGRATION: settings files from before onboarding existed have no
        // hasOnboarded key. A user who already picked a display has a working
        // setup — never funnel them through the full first-run flow.
        hasOnboarded = s.hasOnboarded ?? s.hasPickedDisplay
        onboardingStage = s.onboardingStage ?? 0
```

- [ ] **Step 5: Add to `defaults`**

In `private static let defaults = Snapshot(...)`, after `displayUUID: "",` add:

```swift
        hasOnboarded: false, onboardingStage: 0,
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/Gatecaster/AppSettings.swift
git commit -m "settings: hasOnboarded + onboardingStage with picked-display migration"
```

---

### Task 2: Extract PermissionsView so onboarding can reuse it

**Files:**
- Create: `Sources/Gatecaster/Permissions.swift`
- Modify: `Sources/Gatecaster/SettingsView.swift` (delete the private copy)

`PermissionsView` currently lives `private` in `SettingsView.swift` (around
lines 109–197). Move it verbatim into its own file and drop `private` so the
onboarding permissions step can embed the same live checklist. DRY — do not
duplicate the poll/grant/relaunch logic.

- [ ] **Step 1: Create `Sources/Gatecaster/Permissions.swift`**

Cut the entire `private struct PermissionsView: View { ... }` block out of
`SettingsView.swift` (the struct including its `row`, `openPane`, and
`relaunch` helpers — find it by searching for `struct PermissionsView`) and
paste it into the new file with this header, changing `private struct` to
`struct`:

```swift
import SwiftUI
import IOKit.hid
import ServiceManagement

/// Live permission checklist — the pattern popularized by Rectangle / AltTab:
/// per-permission status (polled; TCC has no change notification), a Grant
/// button that triggers the system prompt, a deep link into the exact
/// System Settings pane, and Relaunch (TCC grants apply on next launch).
/// Shared by the Settings window and the onboarding Permissions step.
struct PermissionsView: View {
    // ... body unchanged from SettingsView.swift ...
}
```

Keep the struct body byte-identical (the `@State` polls, `row(...)`,
`openPane(...)`, `relaunch()`); only the access level and file change.
Check which imports `SettingsView.swift` has at the top and mirror the ones
the moved code needs (`IOHIDCheckAccess` needs `IOKit.hid`; if the compiler
doesn't complain without `ServiceManagement`, drop it — it belongs to the
LoginItemRow, not PermissionsView).

- [ ] **Step 2: Make `relaunch()` reusable**

The onboarding flow also needs to relaunch (same TCC constraint). Inside
`PermissionsView`, change `private func relaunch()` to a file-scope internal
function below the struct so both callers share it:

```swift
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
```

and inside the struct replace the old private method with a call-through:
`Button("Relaunch Gatecaster") { relaunchGatecaster() }`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (SettingsView still compiles because the struct is now internal in the same module.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Gatecaster/Permissions.swift Sources/Gatecaster/SettingsView.swift
git commit -m "refactor: extract PermissionsView for reuse by onboarding"
```

---

### Task 3: VortexIntro.swift — Metal port of the locked shader

**Files:**
- Create: `Sources/Gatecaster/VortexIntro.swift`

Port `vortex-final.html`'s fragment shader 1:1. MSL source is a Swift string
compiled at runtime via `device.makeLibrary(source:)` — no `.metal` build
phase, no SPM resource changes (macOS 13 floor; the SwiftUI shader API needs
macOS 14). **GLSL→MSL gotchas already accounted for below:**
- GLSL `mod(x,y)` is `x − y·floor(x/y)`; MSL `fmod` differs for negatives. Use the `glmod` helper for the angular wrap.
- GLSL `atan(y,x)` → MSL `atan2(y,x)`.
- Metal fragment coords are **top-left origin**, which already matches the demo (it flips y manually) — so NO flip in the port.

- [ ] **Step 1: Write the full file**

```swift
import Cocoa
import MetalKit

/// Full-screen vortex intro: the locked recipe from the approved WebGL demo
/// (vortex-final.html), ported 1:1 to a Metal fragment shader. MSL compiled at
/// RUNTIME so the SPM build needs no .metal phase (and no macOS-14 SwiftUI
/// shader API on our macOS 13 floor).
enum VortexShader {
    // Timeline: fill 0–1.6, suck 1.6–4.6, dive+reveal 4.6–6.0, then confined.
    // The vortex itself is INVISIBLE — no ring/halo/tunnel; only glass
    // distortion + gravitational lens bend the starfield. Color exists solely
    // as per-channel chromatic aberration.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 res; float2 win; float time; float pad; };
    struct VOut { float4 pos [[position]]; };

    vertex VOut vortex_vertex(uint vid [[vertex_id]]) {
        float2 v[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };  // fullscreen tri
        VOut o; o.pos = float4(v[vid], 0, 1); return o;
    }

    constant float TAU = 6.2831853;
    constant float FILL_END = 1.6;
    constant float SUCK_END = 4.6;
    constant float DIVE_END = 6.0;
    // Locked tuning (approved demo): do not tweak without updating the spec.
    constant float SW = 12.0, RUSH = 14.0, STR = 30.0, AB = 0.26;
    constant float LENS = 8.0, GAMP = 110.0, GFREQ = 0.03, DIVEZ = 0.08;

    // GLSL-style mod: fmod misbehaves on negatives and would break the
    // angular wrap (visible star seam at angle 0).
    float glmod(float x, float y) { return x - y*floor(x/y); }
    float hash21(float2 p) { p = fract(p*float2(123.34,456.21)); p += dot(p,p+45.32); return fract(p.x*p.y); }
    float easeS(float u) { u = clamp(u, 0.0, 1.0); return u*u*(3.0-2.0*u); }

    // log-polar star layer; y wraps every `cells` so the angular seam is invisible.
    float starLayerLP(float2 uv, float cells, float t, float fillT, float stretch) {
        float2 id = floor(uv);
        id.y = glmod(id.y, cells);
        float2 gv = fract(uv)-0.5;
        float h = hash21(id);
        if (h < 0.88) return 0.0;
        float2 off = (float2(hash21(id+1.1), hash21(id+2.7)) - 0.5)*0.7;
        float2 d2 = gv - off;
        float d = sqrt(d2.x*d2.x*(1.0+stretch*7.0) + d2.y*d2.y/(1.0+stretch*34.0));
        float birth = fract(h*7.13)*1.4;
        float alive = smoothstep(birth, birth+0.6, fillT);
        float tw = 0.55 + 0.45*sin(t*3.0 + h*40.0);
        return exp(-d*d*340.0) * tw * alive;
    }

    float field(float2 p, float t, float suck, float fillT, float swirlOff) {
        float r = length(p);
        float a = atan2(p.y, p.x);
        float rs = mix(r, r*RUSH + 80.0, suck*suck);
        // keplerian rotation: inner stars orbit fast (1/r), outer ones crawl
        float prof = min(140.0/(r + 70.0), 2.5);
        float a2 = a + (suck*SW + swirlOff) * prof;
        float lr = log(rs + 30.0);
        float stretch = suck * clamp(650.0/max(r,30.0), 0.5, STR);
        float m =        starLayerLP(float2(lr*6.0,        a2/TAU*48.0),  48.0,  t,     fillT, stretch);
        m += 0.8 * starLayerLP(float2(lr*9.0 + 17.0,  a2/TAU*80.0),  80.0,  t*1.3, fillT, stretch);
        m += 0.5 * starLayerLP(float2(lr*13.0 + 41.0, a2/TAU*128.0), 128.0, t*0.8, fillT, stretch);
        return m;
    }

    // calm round stars confined in the window after the dive
    float calmLayer(float2 uv, float t) {
        float2 id = floor(uv), gv = fract(uv)-0.5;
        float h = hash21(id);
        if (h < 0.88) return 0.0;
        float2 off = (float2(hash21(id+1.1), hash21(id+2.7)) - 0.5)*0.7;
        float d = length(gv - off);
        float tw = 0.55 + 0.45*sin(t*2.2 + h*40.0);
        return exp(-d*d*340.0) * tw;
    }
    float calmField(float2 p, float t) {
        float2 uv = p + float2(sin(t*0.21), cos(t*0.17))*6.0;
        return calmLayer(uv*0.02, t) + 0.7*calmLayer(uv*0.045 + 7.0, t*1.2);
    }

    float roundRectSD(float2 p, float2 hsz, float rad) {
        float2 q = abs(p) - hsz + rad;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    }

    // value noise + fbm for the glass ripple
    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f*f*(3.0-2.0*f);
        float a = hash21(i),                  b = hash21(i+float2(1.0,0.0));
        float c = hash21(i+float2(0.0,1.0)),  d = hash21(i+float2(1.0,1.0));
        return mix(mix(a,b,f.x), mix(c,d,f.x), f.y);
    }
    float fbm(float2 p) {
        float v = 0.0, amp = 0.5;
        for (int i = 0; i < 4; i++) { v += amp*vnoise(p); p = p*2.1 + 13.7; amp *= 0.5; }
        return v;
    }

    fragment float4 vortex_fragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
        // Metal frag coords are top-left origin — same orientation the demo
        // produces after its manual y-flip, so no flip here.
        float2 sp = in.pos.xy - U.res*0.5;
        float t = U.time;
        float suck   = easeS((t-FILL_END)/(SUCK_END-FILL_END));
        float dive   = easeS((t-SUCK_END)/(DIVE_END-SUCK_END));
        float reveal = dive;   // modal opens DURING the dive, not after

        // camera dives INTO the vortex: world coords shrink during the dive
        float zoom = mix(1.0, DIVEZ, dive);
        float2 p = sp * zoom;
        float r = length(p);
        float hr = 26.0 + 40.0*(1.0-suck);  // virtual horizon: drives glass/lens falloff, never drawn

        float3 col = float3(0.0);   // pure black space

        // glass distortion: wavy fbm displacement strongest near the horizon
        float gMask = exp(-abs(r-hr)/(hr*1.6)) * suck;
        float2 gd = float2(fbm(p*GFREQ + t*0.3), fbm(p*GFREQ - 7.0 - t*0.25)) - 0.5;
        float2 pg = p + gd * GAMP * gMask;

        // gravitational lens: stars bow around the core instead of passing straight
        float lens = suck * hr*hr*LENS / (r*r + hr*hr*0.5);
        float2 pl = pg * (1.0 + lens);
        float rl = length(pl);

        // chromatic aberration: per-channel swirl offset (the only color in the scene)
        float ab = suck * clamp(340.0/max(rl,40.0), 0.0, 6.0) * AB;
        float3 stars = float3(field(pl, t, suck, t,  ab),
                              field(pl, t, suck, t,  0.0),
                              field(pl, t, suck, t, -ab));
        stars *= (1.0 - reveal) * (1.0 - dive*0.7);
        col += stars;

        // the modal pops OUT of the vortex centre with an easeOutBack overshoot
        if (t > SUCK_END) {
            float u = clamp((t-SUCK_END)/(DIVE_END-SUCK_END), 0.0, 1.0);
            float ob = 1.0 + 2.70158*pow(u-1.0,3.0) + 1.70158*pow(u-1.0,2.0);
            float2 hsz = U.win*0.5 * max(ob, 0.02);
            float sd = roundRectSD(sp, hsz, 18.0);
            float inside = smoothstep(1.5, -1.5, sd);
            col *= mix(1.0, 0.05, reveal * (1.0-inside));
            col = mix(col, float3(0.01), inside*reveal*0.94);
            float em = easeS((t-SUCK_END)/1.4);
            float cf = calmField(sp, t);
            col += float3(cf) * inside * em * reveal;
            col += float3(1.0) * exp(-abs(sd)*0.35) * reveal * 0.18;
        }

        return float4(col, 1.0);
    }
    """
}

/// Renders the vortex into an MTKView. Returns nil when Metal is unavailable
/// or the runtime shader compile fails — callers MUST fall back to the static
/// (Reduce Motion) path; onboarding never blocks on the animation.
final class VortexRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var startTime = CACurrentMediaTime()
    /// Modal size in POINTS; converted to pixels per-frame so the shader's
    /// window rect always matches the SwiftUI overlay exactly.
    var windowSize = CGSize(width: 780, height: 620)
    /// Fired on the main thread once per frame with the current timeline time.
    var onTick: ((Double) -> Void)?

    private struct Uniforms { var res: SIMD2<Float>; var win: SIMD2<Float>; var time: Float; var pad: Float }

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: VortexShader.source, options: nil),
              let vfn = lib.makeFunction(name: "vortex_vertex"),
              let ffn = lib.makeFunction(name: "vortex_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        queue = q
        pipeline = p
        super.init()
    }

    /// Jump the timeline to the confined end-state (skip / Reduce Motion).
    /// The clock keeps running past the end on purpose — the confined stars
    /// twinkle via sin(t), so freezing time freezes them (demo bug, fixed there too).
    func skipToEnd() {
        let now = CACurrentMediaTime()
        if now - startTime < 6.0 { startTime = now - 6.0 }
    }

    var currentTime: Double { CACurrentMediaTime() - startTime }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let t = Float(currentTime)
        let scale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 1
        var u = Uniforms(
            res: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            win: SIMD2(Float(windowSize.width * scale), Float(windowSize.height * scale)),
            time: t, pad: 0)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        let td = Double(t)
        DispatchQueue.main.async { [weak self] in self?.onTick?(td) }
    }
}

/// Factory: a continuously-drawing MTKView wired to a VortexRenderer, or nil
/// when Metal isn't available (caller falls back to a plain fade-in).
func makeVortexView(frame: NSRect, windowSize: CGSize) -> (MTKView, VortexRenderer)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let renderer = VortexRenderer(device: device) else { return nil }
    renderer.windowSize = windowSize
    let view = MTKView(frame: frame, device: device)
    view.colorPixelFormat = .bgra8Unorm
    view.preferredFramesPerSecond = 60
    view.isPaused = false
    view.enableSetNeedsDisplay = false   // free-running clock: confined stars twinkle forever
    view.delegate = renderer
    return (view, renderer)
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

The MSL string only compiles at RUNTIME — a typo inside it builds fine but
fails at launch. So also sanity-compile it now:

- [ ] **Step 3: Verify the MSL compiles**

Run:
```bash
swift build -c release 2>&1 | tail -2 && cat > /tmp/msltest.swift <<'EOF'
// Compile the embedded MSL the same way the app does; exit non-zero on failure.
import Metal
let src = try String(contentsOfFile: CommandLine.arguments[1])
// crude extraction: the MSL is the Swift string between the first pair of \"\"\" fences
let parts = src.components(separatedBy: "\"\"\"")
guard parts.count >= 3 else { fatalError("no MSL block found") }
let msl = parts[1]
guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
do { _ = try dev.makeLibrary(source: msl, options: nil); print("MSL OK") }
catch { print("MSL FAIL: \(error)"); exit(1) }
EOF
swift /tmp/msltest.swift Sources/Gatecaster/VortexIntro.swift
```
Expected: `MSL OK`. If it prints `MSL FAIL`, the error message has the MSL line number — fix the shader string and re-run.

- [ ] **Step 4: Commit**

```bash
git add Sources/Gatecaster/VortexIntro.swift
git commit -m "feat: Metal vortex intro (runtime-compiled MSL port of approved demo)"
```

---

### Task 4: IdentifyBadgeView for the monitor step

**Files:**
- Modify: `Sources/Gatecaster/DisplayPicker.swift`

Small numbered corner badge shown on every display during the monitor step.
IDENTIFY-only by design: touch reports carry no display identity, so until a
display is bound, touches click through to the currently-bound display —
badges therefore must not be the primary tap target (mouse clicks are fine).
The existing full-screen `DisplayPickerView` stays untouched (still used by
the menu item).

- [ ] **Step 1: Append the badge view**

Add at the end of `Sources/Gatecaster/DisplayPicker.swift`:

```swift
/// Corner badge shown on each display during the onboarding Monitor step.
/// Identify-first (touch can't safely pick before a display is bound — see
/// spec), but a MOUSE click is accepted as a pick.
struct IdentifyBadgeView: View {
    let number: Int
    let name: String
    var onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: 2) {
                Text("\(number)")
                    .font(.system(size: 44, weight: .bold))
                Text(name)
                    .font(.system(size: 11))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .frame(width: 150, height: 90)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.78))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Gatecaster/DisplayPicker.swift
git commit -m "feat: identify badge view for onboarding monitor step"
```

---

### Task 5: Onboarding.swift — controller, stage machine, step views

**Files:**
- Create: `Sources/Gatecaster/Onboarding.swift`

One full-screen borderless `KeyableWindow` on the main display hosting:
the MTKView (full-frame, behind) + an NSHostingView with the SwiftUI step
content (full-frame, transparent, in front). The SwiftUI modal is centered
with the SAME size passed to the shader (`windowSize`), so shader glass and
SwiftUI content can't misalign.

**Window level is `.normal`, NOT `.screenSaver`** — the Permissions step
deep-links into System Settings and triggers TCC prompts; a screen-saver-level
overlay would cover them.

- [ ] **Step 1: Write the full file**

```swift
import Cocoa
import SwiftUI
import IOKit.hid

/// Stages persist in AppSettings.onboardingStage so the TCC-mandated relaunch
/// resumes where the user left off.
enum OnboardingStage: Int {
    case welcome = 0, permissions = 1, monitor = 2, calibration = 3
}

/// Observable state shared by the controller (AppKit) and the step views (SwiftUI).
final class OnboardingModel: ObservableObject {
    @Published var stage: OnboardingStage = .welcome
    @Published var introDone = false           // true once the vortex reveal finished (t >= 6)
    @Published var displays: [(number: Int, name: String, size: String)] = []
    @Published var calibrationRunning = false
    @Published var finished = false            // close-out "You're all set" card
}

/// Owns the full-screen onboarding window. AppController wires the callbacks —
/// the controller itself never touches Engine/HID/display state directly.
final class OnboardingController {
    let model = OnboardingModel()
    private let settings: AppSettings
    private var window: KeyableWindow?
    private var renderer: VortexRenderer?
    private var badgeWindows: [NSWindow] = []
    private var keyMonitor: Any?

    /// AppController hooks (set before show()):
    var onPickDisplay: ((Int) -> Void)?        // monitor-step pick (1-based screen index)
    var onStartCalibration: (() -> Void)?      // opens the existing corner-tap flow
    var onFinished: (() -> Void)?              // flow complete; tear down

    init(settings: AppSettings) { self.settings = settings }

    // MARK: lifecycle
    /// `resumeAt` non-nil = jump straight to a step with no intro (relaunch
    /// resume, or "existing user missing a permission").
    func show(resumeAt: OnboardingStage?) {
        guard window == nil, let screen = NSScreen.main else { return }
        let frame = screen.frame
        // Modal size: spec's Raycast-like ~780×620, clamped on small screens.
        let winSize = CGSize(width: min(780, frame.width * 0.6),
                             height: min(620, frame.height * 0.75))

        let win = KeyableWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.level = .normal       // System Settings / TCC prompts must be able to cover us
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))

        // Reduce Motion (or Metal unavailable / MSL compile failure) → static
        // path: no vortex, content fades in over black. Never block onboarding.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let (mtk, r) = makeVortexView(frame: container.bounds, windowSize: winSize) {
            renderer = r
            if reduceMotion || resumeAt != nil { r.skipToEnd() }
            r.onTick = { [weak self] t in
                guard let self = self, !self.model.introDone, t >= 6.0 else { return }
                self.model.introDone = true
            }
            mtk.autoresizingMask = [.width, .height]
            container.addSubview(mtk)
        } else {
            model.introDone = true   // static fallback: show content immediately
        }
        if reduceMotion || resumeAt != nil { model.introDone = true }

        if let stage = resumeAt { model.stage = stage }
        else { model.stage = OnboardingStage(rawValue: settings.onboardingStage) ?? .welcome }
        settings.onboardingStage = model.stage.rawValue

        let host = NSHostingView(rootView: OnboardingView(
            model: model, settings: settings, modalSize: winSize,
            advance: { [weak self] in self?.advance() },
            back: { [weak self] in self?.back() },
            pick: { [weak self] n in self?.pickDisplay(n) },
            startCalibration: { [weak self] in self?.beginCalibration() },
            finish: { [weak self] in self?.finish() }))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        win.contentView = container
        win.setFrame(frame, display: true)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Any key during the intro skips it; number keys pick a display on the
        // monitor step. Local monitor only — no nextEvent loops (HID deadlock).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if !self.model.introDone { self.skipIntro(); return nil }
            if self.model.stage == .monitor,
               let s = ev.charactersIgnoringModifiers, let n = Int(s),
               n >= 1, n <= NSScreen.screens.count {
                self.pickDisplay(n)
                return nil
            }
            return ev
        }
    }

    func skipIntro() {
        renderer?.skipToEnd()
        model.introDone = true
    }

    private func advance() {
        switch model.stage {
        case .welcome:      setStage(.permissions)
        case .permissions:  setStage(.monitor)
        case .monitor:      setStage(.calibration)
        case .calibration:  finish()
        }
    }

    private func back() {
        guard let prev = OnboardingStage(rawValue: model.stage.rawValue - 1) else { return }
        setStage(prev)
    }

    private func setStage(_ s: OnboardingStage) {
        model.stage = s
        settings.onboardingStage = s.rawValue   // relaunch resumes here
        settings.save()
        if s == .monitor { showBadges() } else { hideBadges() }
        if s == .monitor { refreshDisplays() }
    }

    // MARK: monitor step
    private func refreshDisplays() {
        model.displays = NSScreen.screens.enumerated().map { i, s in
            (i + 1, s.localizedName,
             "\(Int(s.frame.width)) × \(Int(s.frame.height))")
        }
    }

    private func showBadges() {
        hideBadges()
        for (i, screen) in NSScreen.screens.enumerated() {
            let n = i + 1
            let size = NSSize(width: 150, height: 90)
            let rect = NSRect(x: screen.frame.maxX - size.width - 24,
                              y: screen.frame.maxY - size.height - 24,
                              width: size.width, height: size.height)
            let w = NSWindow(contentRect: rect, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView:
                IdentifyBadgeView(number: n, name: screen.localizedName) { [weak self] in
                    self?.pickDisplay(n)
                })
            w.orderFrontRegardless()
            badgeWindows.append(w)
        }
    }

    private func hideBadges() {
        badgeWindows.forEach { $0.orderOut(nil) }
        badgeWindows.removeAll()
    }

    /// Display hotplug while the monitor step is open: refresh rows + badges.
    /// AppController calls this from its existing screensChanged observer.
    func screensChanged() {
        guard model.stage == .monitor else { return }
        refreshDisplays()
        showBadges()
    }

    private func pickDisplay(_ n: Int) {
        onPickDisplay?(n)
        setStage(.calibration)
    }

    // MARK: calibration step
    private func beginCalibration() {
        model.calibrationRunning = true
        window?.orderOut(nil)            // get out of the way of the corner targets
        onStartCalibration?()
    }

    /// AppController calls this from endCalibration().
    func calibrationFinished() {
        guard model.calibrationRunning else { return }
        model.calibrationRunning = false
        model.finished = true
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        settings.hasOnboarded = true
        settings.onboardingStage = 0
        settings.save()
        teardown()
        onFinished?()
    }

    func teardown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        hideBadges()
        window?.orderOut(nil)
        window = nil
        renderer = nil
    }
}

// MARK: - SwiftUI step content

/// Full-frame transparent overlay; the visible "modal" is a centered region
/// whose size EXACTLY matches the shader's window rect (same numbers), so the
/// Metal glass panel and the SwiftUI content always align.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    let modalSize: CGSize
    var advance: () -> Void
    var back: () -> Void
    var pick: (Int) -> Void
    var startCalibration: () -> Void
    var finish: () -> Void

    var body: some View {
        ZStack {
            if model.introDone {
                content
                    .frame(width: modalSize.width, height: modalSize.height)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeIn(duration: 0.5), value: model.introDone)
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            Group {
                if model.finished { doneCard }
                else {
                    switch model.stage {
                    case .welcome:      welcome
                    case .permissions:  permissions
                    case .monitor:      monitor
                    case .calibration:  calibration
                    }
                }
            }
            .frame(maxHeight: .infinity)
            pageDots
                .padding(.bottom, 26)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i == model.stage.rawValue ? Color.white : Color.white.opacity(0.22))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func cta(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 200, height: 38)
                .background(LinearGradient(colors: [.white, Color(white: 0.85)],
                                           startPoint: .top, endPoint: .bottom))
                .cornerRadius(9)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: steps
    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Welcome to Gatecaster")
                .font(.system(size: 26, weight: .bold))
            Text("Your touchscreen, cast into a true Mac input surface.")
                .font(.system(size: 13)).opacity(0.62)
            Spacer().frame(height: 18)
            VStack(alignment: .leading, spacing: 14) {
                featureRow("🌀", "Open the gate", "pointer, taps, native gestures")
                featureRow("✨", "Cast across space", "pinch, rotate, momentum scroll")
                featureRow("🛰️", "Summon controls", "keyboard, trackpad & deck")
            }
            Spacer()
            cta("Get Started") { advance() }
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(icon).font(.system(size: 15))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("— " + detail).font(.system(size: 13)).opacity(0.6)
        }
    }

    private var permissions: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Open the Gate")
                .font(.system(size: 24, weight: .bold))
            Text("Gatecaster needs two permissions to read the panel and move the pointer.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 8)
            PermissionsView()                      // shared live checklist (Task 2)
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                .frame(maxWidth: 460)
            Spacer()
            cta("Continue") { advance() }
                .disabled(!permissionsGranted)
                .opacity(permissionsGranted ? 1 : 0.4)
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private var permissionsGranted: Bool {
        AXIsProcessTrusted() &&
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private var monitor: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Which screen is the touchscreen?")
                .font(.system(size: 24, weight: .bold))
            Text("Badges mark each display. Click its row, press its number key, or click the badge with the mouse.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 8)
            VStack(spacing: 8) {
                ForEach(model.displays, id: \.number) { d in
                    Button { pick(d.number) } label: {
                        HStack(spacing: 12) {
                            Text("\(d.number)")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.system(size: 13, weight: .medium))
                                Text(d.size).font(.system(size: 11)).opacity(0.55)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").opacity(0.4)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 440)
            Spacer()
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private var calibration: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Final step — map the corners")
                .font(.system(size: 24, weight: .bold))
            Text("Tap each corner target on the touchscreen so Gatecaster knows exactly where the panel edges land.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
            cta("Start Calibration") { startCalibration() }
            Button("Skip for now") { finish() }    // calibration re-runnable from Settings
                .buttonStyle(.plain)
                .font(.system(size: 12)).opacity(0.5)
                .padding(.top, 4)
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }

    private var doneCard: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("You're all set")
                .font(.system(size: 26, weight: .bold))
            Text("The gate is open. Gatecaster lives in the menu bar — settings, keyboard, trackpad and deck are one tap away.")
                .font(.system(size: 13)).opacity(0.62)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
            cta("Finish") { finish() }
            Spacer().frame(height: 18)
        }
        .foregroundColor(.white)
    }
}
```

Note: `permissionsGranted` is recomputed when the embedded `PermissionsView`'s
2-second poll fires its own `@State` updates; that doesn't re-render the
PARENT. Simplest reliable fix is a local poll — add to `OnboardingView`:

```swift
    @State private var permTick = false
    private let permPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
```

and on the `permissions` VStack append:

```swift
            .onReceive(permPoll) { _ in permTick.toggle() }   // re-evaluate permissionsGranted
```

(`permTick` exists only to invalidate the view; the granted check reads the
TCC APIs directly.)

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Gatecaster/Onboarding.swift
git commit -m "feat: onboarding window, stage machine, and step views"
```

---

### Task 6: main.swift — launch branching, wiring, menu item

**Files:**
- Modify: `Sources/Gatecaster/main.swift`

- [ ] **Step 1: Add the controller ivar**

In `AppController`, next to `private var calController: CalibrationController?` add:

```swift
    private var onboarding: OnboardingController?
```

- [ ] **Step 2: Branch at launch**

In `applicationDidFinishLaunching`, REPLACE this existing block (currently right after `hid.start()`):

```swift
        // Resolve the saved monitor by its STABLE uuid. If it's connected, use it
        // (no prompt). If we'd picked one before but it's genuinely absent and there's
        // more than one screen to choose from, ask again. First run → ask.
        if let id = displayID(forUUID: settings.displayUUID) {
            applyDisplay(id)
        } else if settings.hasPickedDisplay && NSScreen.screens.count > 1 {
            startDisplayPicker()
        } else if settings.hasPickedDisplay {
            applyDisplay(CGMainDisplayID())   // single screen: just use it, don't nag
        } else {
            startDisplayPicker()
        }
```

with:

```swift
        // First-run (or resumed) onboarding replaces the bare display picker.
        // Existing users with everything granted never see it (hasOnboarded is
        // migrated from hasPickedDisplay). Existing users MISSING a permission
        // get dropped directly on the Permissions step — no intro, no welcome.
        let permissionsOK = AXIsProcessTrusted() &&
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !settings.hasOnboarded {
            // Mid-flow relaunch (TCC grant) resumes at the persisted stage.
            let resume = settings.onboardingStage > 0
                ? OnboardingStage(rawValue: settings.onboardingStage) : nil
            startOnboarding(resumeAt: resume)
        } else if !permissionsOK {
            startOnboarding(resumeAt: .permissions)
        } else {
            resolveSavedDisplay()
        }
```

Note `IOHIDCheckAccess` needs `import IOKit.hid` at the top of main.swift —
add it under `import Combine`.

Also REPLACE the launch-time AX prompt block (the `axOpts` lines near the top
of `applicationDidFinishLaunching`) with a passive check — the prompt now
belongs to the Permissions step, prompting before the welcome screen looks
broken:

```swift
        // Permission prompting now lives in onboarding's Permissions step;
        // just log so a headless launch isn't silently dead.
        if !AXIsProcessTrusted() {
            FileHandle.standardError.write(
                Data("[gatecaster] waiting for Accessibility permission…\n".utf8))
        }
```

- [ ] **Step 3: Extract `resolveSavedDisplay()` and add the onboarding plumbing**

Add these methods to `AppController` (put them next to `startDisplayPicker`):

```swift
    // MARK: onboarding
    /// The old launch-time display resolution, reused after onboarding finishes.
    private func resolveSavedDisplay() {
        if let id = displayID(forUUID: settings.displayUUID) {
            applyDisplay(id)
        } else if settings.hasPickedDisplay && NSScreen.screens.count > 1 {
            startDisplayPicker()
        } else if settings.hasPickedDisplay {
            applyDisplay(CGMainDisplayID())   // single screen: just use it, don't nag
        } else {
            startDisplayPicker()
        }
    }

    private func startOnboarding(resumeAt: OnboardingStage?) {
        guard onboarding == nil else { return }
        let ob = OnboardingController(settings: settings)
        ob.onPickDisplay = { [weak self] n in self?.onboardingPickDisplay(n) }
        ob.onStartCalibration = { [weak self] in self?.startCalibration() }
        ob.onFinished = { [weak self] in
            guard let self = self else { return }
            self.onboarding = nil
            self.resolveSavedDisplay()   // bind whatever was picked (or re-ask)
            self.rebuildMenu()
        }
        onboarding = ob
        ob.show(resumeAt: resumeAt)
    }

    /// Setup Assistant menu item: full flow from the top, intro included.
    @objc private func startSetupAssistant() {
        settings.onboardingStage = 0
        startOnboarding(resumeAt: nil)
    }

    /// Monitor-step pick: bind + persist, but do NOT auto-start calibration —
    /// onboarding's Calibration step owns that handoff (it has its own intro).
    private func onboardingPickDisplay(_ number: Int) {
        let screens = NSScreen.screens
        guard number >= 1, number <= screens.count else { return }
        if let id = (screens[number - 1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? NSNumber)?.uint32Value {
            applyDisplay(id)
            settings.displayID = Double(id)
            settings.displayUUID = uuid(for: id) ?? ""
            settings.hasPickedDisplay = true
            settings.save()
        }
    }
```

- [ ] **Step 4: Notify onboarding when calibration ends and screens change**

In `endCalibration()`, after `calController = nil`, add:

```swift
        onboarding?.calibrationFinished()   // onboarding shows its close-out card
```

In `screensChanged()`, at the end, add:

```swift
        onboarding?.screensChanged()        // monitor step refreshes rows + badges
```

- [ ] **Step 5: Menu item**

In `rebuildMenu()`, after the `item(menu, "Calibrate Touchscreen…", ...)` line, add:

```swift
        item(menu, "Setup Assistant…", #selector(startSetupAssistant))
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/Gatecaster/main.swift
git commit -m "feat: launch into onboarding; Setup Assistant menu item"
```

---

### Task 7: Manual verification (no test suite — exercise the spec's checklist)

**Files:** none (verification only)

- [ ] **Step 1: Release build + run from a clean slate**

```bash
swift build -c release 2>&1 | tail -2
mv ~/v17ut-settings.json ~/v17ut-settings.json.bak 2>/dev/null
.build/release/Gatecaster
```

Verify, in order:
1. Vortex intro plays full-screen: stars fill (1.6 s) → spiral suck with visible glass wobble + lens bowing + per-channel color fringing, NO visible ring/halo → camera dives in while the modal pops out with an overshoot (4.6–6.0 s) → confined twinkling stars inside the modal (twinkle must NOT freeze).
2. Any key during the intro skips straight to the welcome card.
3. Welcome copy matches the spec (gate/space wording, no Stream Deck mention).
4. Permissions step: rows show live status; Grant buttons fire the system prompts; Continue stays disabled until both are granted; Relaunch resumes on the next stage.
5. Monitor step: rows list every display; corner badges appear on each; number keys 1–9 and mouse-clicking a badge both pick.
6. Calibration step: Start hands off to the corner-tap flow; finishing returns to the "You're all set" card; Skip also completes.
7. After Finish: app behaves normally; `cat ~/v17ut-settings.json | grep -i onboard` shows `"hasOnboarded" : true`.

- [ ] **Step 2: Migration + permissions-missing paths**

```bash
mv ~/v17ut-settings.json.bak ~/v17ut-settings.json
.build/release/Gatecaster
```
Verify an existing settings file (which has `hasPickedDisplay: true` but no
`hasOnboarded` key) boots straight into normal operation — no onboarding.

Then revoke Accessibility for the binary in System Settings → Privacy &
Security and relaunch: the app must open directly on the Permissions step
(no intro, no welcome).

- [ ] **Step 3: Reduce Motion path**

System Settings → Accessibility → Display → Reduce motion ON, then
`Setup Assistant…` from the menu: the welcome card must fade in over plain
black with no vortex.

- [ ] **Step 4: Commit any fixes found, then finish the branch**

Fixes discovered during verification get their own commits. When everything
passes, use the superpowers:finishing-a-development-branch skill to wrap up
(merge/PR decision belongs to the user).
```

---

## Self-review notes (already applied)

- **Spec coverage:** intro (Task 3+5), welcome copy (5), permissions reuse + relaunch resume (2, 5, 6), hybrid monitor + identify badges (4, 5), calibration handoff + skip (5, 6), hasOnboarded/onboardingStage + migration (1), launch branching + menu item (6), Reduce Motion + Metal-failure fallback (3, 5), error handling for display unplug (5 `screensChanged`), manual test list (7).
- **Spec deviation (intentional):** the spec's "version bump + migration" maps to this codebase's actual mechanism — optional Snapshot fields with defaulting in `apply(_:)`. There is no version int to bump; inventing one would churn every existing field.
- **Types cross-checked:** `OnboardingStage` raw values match `onboardingStage` comments; `makeVortexView(frame:windowSize:)` matches the Task 5 call; `relaunchGatecaster()` defined in Task 2, used in Task 2's button; `IdentifyBadgeView(number:name:onPick:)` matches Task 5's call; `calibrationFinished()`/`screensChanged()` defined in Task 5, called in Task 6.
