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
