import SwiftUI
import AppKit
import Foundation

// MARK: - widget model

/// A widget occupies a wider slot than a button (W×H cells) and shows live
/// content. Two sources:
///  - `builtin`  — shipped with the app (clock, media).
///  - `extension` — a third-party pack installed in the Extensions folder,
///    referenced by its manifest id. Declarative + sandboxed (see below).
struct DeckWidget: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: String = "clock"          // "clock" | "media" | "ext:<extensionId>"
    var spanW = 2                        // width in grid cells
    var spanH = 2                        // height in grid cells
    var config: [String: String] = [:]  // per-instance settings (extension fields)
    // Explicit grid placement (cell coordinates). nil = auto first-fit. See the
    // matching note on DeckButton — integers so they survive a Block-Size change.
    var gridCol: Int?
    var gridRow: Int?

    // Tolerant decode (forward/backward-compat): a widget saved before `config`
    // or the span fields existed, or with a missing id, decodes to its default
    // rather than hard-failing — Swift's synthesized decoder otherwise demands
    // every non-optional key be present (defaults only feed memberwise init, not
    // Decodable), so one missing field in a saved/exported deck would, via the
    // `try?` in DeckStore.load/importLayout, silently discard the whole layout.
    // gridCol/gridRow stay Optional: absent → nil → auto first-fit.
    init() {}
    init(id: UUID = UUID(), kind: String = "clock", spanW: Int = 2, spanH: Int = 2,
         config: [String: String] = [:], gridCol: Int? = nil, gridRow: Int? = nil) {
        self.id = id; self.kind = kind; self.spanW = spanW; self.spanH = spanH
        self.config = config; self.gridCol = gridCol; self.gridRow = gridRow
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, spanW, spanH, config, gridCol, gridRow
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "clock"
        spanW = try c.decodeIfPresent(Int.self, forKey: .spanW) ?? 2
        spanH = try c.decodeIfPresent(Int.self, forKey: .spanH) ?? 2
        config = try c.decodeIfPresent([String: String].self, forKey: .config) ?? [:]
        gridCol = try c.decodeIfPresent(Int.self, forKey: .gridCol)
        gridRow = try c.decodeIfPresent(Int.self, forKey: .gridRow)
    }

    var isExtension: Bool { kind.hasPrefix("ext:") }
    var extensionId: String? { isExtension ? String(kind.dropFirst(4)) : nil }
}

// MARK: - third-party extension manifest (declarative; no arbitrary code)

/// A widget extension is a folder under
/// ~/Library/Application Support/Gatecaster/Extensions/<id>/ containing
/// manifest.json. It is DECLARATIVE: it describes a tile (title, icon, color),
/// optional live fields populated by a `refresh` command's JSON stdout, and
/// buttons that fire the SAME safe DeckAction types (app/url/keystroke/
/// shortcut/shell/volume). There is no linked/native third-party code — the
/// only execution is the actions and the refresh command the user installed,
/// which run with the user's privileges (documented; v1 marketplace reviews).
struct WidgetManifest: Codable, Identifiable {
    var id: String                       // reverse-DNS, e.g. com.spotify.nowplaying
    var name: String
    var symbol: String?                  // SF Symbol for the header
    var colorHex: String?
    var minW: Int?                       // smallest span the widget renders well at
    var minH: Int?
    var defaultW: Int?                   // span when first dropped (defaults to min)
    var defaultH: Int?
    var fields: [ManifestField]?         // labels shown; value via refreshKey
    var buttons: [ManifestButton]?       // action buttons in the tile
    var refresh: ManifestRefresh?        // optional polling command → JSON

    // ── schema v2 (PLATFORM_SPEC §5) — all ADDITIVE; a v1 manifest decodes with
    //    every one of these nil and behaves exactly as before. `schemaVersion`
    //    (the manifest's "v") is absent/1 for v1, 2 for v2. We never read it to
    //    GATE features (everything is tolerant), only to record provenance and
    //    drive the migrator's normalize() pass — mirroring the Touch API's `v`
    //    discipline: additive fields don't bump v, clients ignore unknown fields.
    var schemaVersion: Int?              // "v"  — absent/1 = v1, 2 = v2
    var view: ManifestView?              // presentation axis (declarative | webview)
    var provider: ManifestProvider?      // data axis: push monitor process (§5.5/§10)
    var actions: [String: ManifestAction]? // named, parameterized actions (§5.3)
    var configSchema: [ManifestConfigField]? // per-instance settings form (§6)
    var capabilities: [String]?          // declared host facilities (§8) — runtime ceiling
    var secrets: [ManifestSecret]?       // keychain-backed token declarations (§7)
    var oauth: ManifestOAuth?            // browser auth round-trip (§7)

    // Tolerant decode (forward/backward-compat). A future manifest schema that
    // adds keys must still load older manifests, and a hand-written manifest
    // missing an optional key must not nuke the whole registry reload (the `try?`
    // in WidgetRegistry.reload would otherwise drop the entire extension). `id`
    // and `name` have no natural default, so they fall back to "" — a nameless
    // manifest is harmless (sorts empty) and far better than a hard failure.
    init(id: String = "", name: String = "", symbol: String? = nil,
         colorHex: String? = nil, minW: Int? = nil, minH: Int? = nil,
         defaultW: Int? = nil, defaultH: Int? = nil,
         fields: [ManifestField]? = nil, buttons: [ManifestButton]? = nil,
         refresh: ManifestRefresh? = nil, schemaVersion: Int? = nil,
         view: ManifestView? = nil, provider: ManifestProvider? = nil,
         actions: [String: ManifestAction]? = nil,
         configSchema: [ManifestConfigField]? = nil, capabilities: [String]? = nil,
         secrets: [ManifestSecret]? = nil, oauth: ManifestOAuth? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.colorHex = colorHex
        self.minW = minW; self.minH = minH; self.defaultW = defaultW; self.defaultH = defaultH
        self.fields = fields; self.buttons = buttons; self.refresh = refresh
        self.schemaVersion = schemaVersion; self.view = view; self.provider = provider
        self.actions = actions; self.configSchema = configSchema
        self.capabilities = capabilities; self.secrets = secrets; self.oauth = oauth
    }
    enum CodingKeys: String, CodingKey {
        case id, name, symbol, colorHex, minW, minH, defaultW, defaultH
        case fields, buttons, refresh
        case schemaVersion = "v"
        case view, provider, actions, configSchema, capabilities, secrets, oauth
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        minW = try c.decodeIfPresent(Int.self, forKey: .minW)
        minH = try c.decodeIfPresent(Int.self, forKey: .minH)
        defaultW = try c.decodeIfPresent(Int.self, forKey: .defaultW)
        defaultH = try c.decodeIfPresent(Int.self, forKey: .defaultH)
        fields = try c.decodeIfPresent([ManifestField].self, forKey: .fields)
        buttons = try c.decodeIfPresent([ManifestButton].self, forKey: .buttons)
        refresh = try c.decodeIfPresent(ManifestRefresh.self, forKey: .refresh)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        view = try c.decodeIfPresent(ManifestView.self, forKey: .view)
        provider = try c.decodeIfPresent(ManifestProvider.self, forKey: .provider)
        actions = try c.decodeIfPresent([String: ManifestAction].self, forKey: .actions)
        configSchema = try c.decodeIfPresent([ManifestConfigField].self, forKey: .configSchema)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)
        secrets = try c.decodeIfPresent([ManifestSecret].self, forKey: .secrets)
        oauth = try c.decodeIfPresent(ManifestOAuth.self, forKey: .oauth)
    }

    /// Presentation axis (§5.1). `declarative` (default) renders fields+buttons;
    /// `webview` loads `entry` HTML (P1 — modelled now, rendered later). Unknown
    /// kinds fall back to declarative so a forward manifest still shows *something*.
    var isWebView: Bool { (view?.kind ?? "declarative") == "webview" }
    /// Whether this tile pushes (provider) vs polls (refresh) vs neither (static).
    var hasProvider: Bool { provider?.command.isEmpty == false }

    /// §5.6 — v1→v2 migrator. The decode above is fully tolerant, so a v1 pack
    /// already loads; this NORMALIZES it to the v2 shape so downstream code can
    /// rely on `schemaVersion` and `view` being populated rather than re-deriving
    /// defaults at every read site. Mirrors AppSettings' "bump and migrate, never
    /// silently feed a stale shape" discipline (CLAUDE.md).
    ///
    /// Contract (§5.6):
    ///   • `v` absent or 1  ⇒ wrap as declarative, treat refresh as parse:"json",
    ///                         leave fields/buttons untouched. No author action.
    ///   • `v` == 2         ⇒ already v2; only fill in implicit defaults.
    ///   • `v` >  2         ⇒ a future/unknown schema; load tolerantly as v2
    ///                         (additive-forward), never hard-fail.
    func normalized() -> WidgetManifest {
        var m = self
        let v = m.schemaVersion ?? 1
        m.schemaVersion = max(v, 2)                 // record provenance as ≥2 post-migrate
        if m.view == nil { m.view = ManifestView(kind: "declarative") }
        // A v1 `refresh` with no `parse` is implicitly JSON — make it explicit so
        // the poll path (§5.4) has a concrete kind to switch on.
        if m.refresh != nil, m.refresh?.parse == nil {
            m.refresh?.parse = ManifestParse(kind: "json")
        }
        return m
    }

    struct ManifestField: Codable, Hashable {
        var label: String
        var refreshKey: String?          // key into refresh JSON; else static `value`
        var value: String?
        // v2 (§5.2) — all additive. `type` ∈ text|image|range|slider|dial (default
        // text; unknown ⇒ text, forward-compat). `image` renders the state value as
        // a tile image (data URI / file path / provider-pushed PNG, §9). `range`
        // draws a read-only 0..max bar. `slider`/`dial` are INTERACTIVE: the user
        // drags to set a value in [min,max] (default 0..100) and the dragged int is
        // substituted as `$value` into the field's `action`/`run`, fired throttled
        // (§5.9). A slider/dial with no action just displays. `size` ∈
        // small|regular|large. `orientation` ∈ vertical(default)|horizontal (slider).
        var type: String?
        var size: String?
        var min: Double?
        var max: Double?
        var orientation: String?         // slider axis; dial ignores it
        // Interactive set-value action (slider/dial). EITHER inline `action` OR a
        // named `run` (resolved against the manifest's `actions` map) — `run` wins.
        // The dragged value is injected as the `$value` token before $config.
        var action: ManifestAction?
        var run: String?

        // Tolerant decode — a field with no `label` falls back to "" rather than
        // failing the parent manifest's whole decode (forward/backward-compat).
        init(label: String = "", refreshKey: String? = nil, value: String? = nil,
             type: String? = nil, size: String? = nil, min: Double? = nil, max: Double? = nil,
             orientation: String? = nil, action: ManifestAction? = nil, run: String? = nil) {
            self.label = label; self.refreshKey = refreshKey; self.value = value
            self.type = type; self.size = size; self.min = min; self.max = max
            self.orientation = orientation; self.action = action; self.run = run
        }
        enum CodingKeys: String, CodingKey {
            case label, refreshKey, value, type, size, min, max, orientation, action, run
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            refreshKey = try c.decodeIfPresent(String.self, forKey: .refreshKey)
            value = try c.decodeIfPresent(String.self, forKey: .value)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            size = try c.decodeIfPresent(String.self, forKey: .size)
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            max = try c.decodeIfPresent(Double.self, forKey: .max)
            orientation = try c.decodeIfPresent(String.self, forKey: .orientation)
            action = try c.decodeIfPresent(ManifestAction.self, forKey: .action)
            run = try c.decodeIfPresent(String.self, forKey: .run)
        }
    }
    struct ManifestButton: Codable, Hashable {
        var label: String?
        var symbol: String?
        var action: DeckAction
        // Toggle button: tracks an on/off state and can show alternate
        // label/icon when on. `actionAlt` fires when turning off (if absent,
        // `action` fires both ways — e.g. a shortcut that itself toggles).
        var toggle: Bool?
        var altLabel: String?
        var altSymbol: String?
        var actionAlt: DeckAction?
        // Multi-state button: cycles through these on each tap, showing the
        // current state's label/icon and firing its action. Supersedes toggle.
        var states: [ManifestState]?
        // v2 (§5.3) — reference a named action by id (enables params + then).
        // A button has EITHER inline `action` OR `run`, never both; `run` wins
        // when present (resolved against the manifest's `actions` map).
        var run: String?

        // Tolerant decode (forward/backward-compat): a button missing `action`
        // falls back to a no-op DeckAction (default kind .none) instead of
        // failing the manifest decode — a button that does nothing is a far
        // better failure mode than a dropped extension.
        init(label: String? = nil, symbol: String? = nil, action: DeckAction = DeckAction(),
             toggle: Bool? = nil, altLabel: String? = nil, altSymbol: String? = nil,
             actionAlt: DeckAction? = nil, states: [ManifestState]? = nil, run: String? = nil) {
            self.label = label; self.symbol = symbol; self.action = action
            self.toggle = toggle; self.altLabel = altLabel; self.altSymbol = altSymbol
            self.actionAlt = actionAlt; self.states = states; self.run = run
        }
        enum CodingKeys: String, CodingKey {
            case label, symbol, action, toggle, altLabel, altSymbol, actionAlt, states, run
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            action = try c.decodeIfPresent(DeckAction.self, forKey: .action) ?? DeckAction()
            toggle = try c.decodeIfPresent(Bool.self, forKey: .toggle)
            altLabel = try c.decodeIfPresent(String.self, forKey: .altLabel)
            altSymbol = try c.decodeIfPresent(String.self, forKey: .altSymbol)
            actionAlt = try c.decodeIfPresent(DeckAction.self, forKey: .actionAlt)
            states = try c.decodeIfPresent([ManifestState].self, forKey: .states)
            run = try c.decodeIfPresent(String.self, forKey: .run)
        }
    }

    /// One state of a multi-state button.
    struct ManifestState: Codable, Hashable {
        var label: String?
        var symbol: String?
        var action: DeckAction

        // Tolerant decode — missing `action` → no-op default (see ManifestButton).
        init(label: String? = nil, symbol: String? = nil, action: DeckAction = DeckAction()) {
            self.label = label; self.symbol = symbol; self.action = action
        }
        enum CodingKeys: String, CodingKey { case label, symbol, action }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            action = try c.decodeIfPresent(DeckAction.self, forKey: .action) ?? DeckAction()
        }
    }
    struct ManifestRefresh: Codable, Hashable {
        var command: String              // zsh; stdout must be a flat JSON object
        var everySeconds: Double         // poll interval (min clamped to 2s)
        // v2 (§5.4) — optional parsing of non-JSON stdout, and value remapping.
        // Both additive: a v1 refresh with neither parses stdout as flat JSON
        // (the original behavior) and applies no transform.
        var parse: ManifestParse?
        var transform: [String: ManifestTransform]?

        // Tolerant decode (forward/backward-compat): missing `command` → "" (no
        // poll runs) and missing `everySeconds` → 2 (the clamp floor) instead of
        // failing the manifest decode.
        init(command: String = "", everySeconds: Double = 2,
             parse: ManifestParse? = nil, transform: [String: ManifestTransform]? = nil) {
            self.command = command; self.everySeconds = everySeconds
            self.parse = parse; self.transform = transform
        }
        enum CodingKeys: String, CodingKey { case command, everySeconds, parse, transform }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
            everySeconds = try c.decodeIfPresent(Double.self, forKey: .everySeconds) ?? 2
            parse = try c.decodeIfPresent(ManifestParse.self, forKey: .parse)
            transform = try c.decodeIfPresent([String: ManifestTransform].self, forKey: .transform)
        }
    }

    // MARK: - v2 nested types (§5) — all tolerant-decoding, all optional

    /// §5.4 — how to turn a refresh command's stdout into a flat key→value dict.
    /// Default (nil / kind "json") = parse stdout as flat JSON, the v1 behavior.
    /// A delimiter spec splits ONE line into named keys: e.g. "40|0|MacBook"
    /// + fields ["volume","muted","device"] → {volume:40, muted:0, device:MacBook}.
    struct ManifestParse: Codable, Hashable {
        var kind: String?                // "json" (default) | "delimited"
        var delimiter: String?           // when delimited
        var fields: [String]?            // names, positional
        var trim: Bool?
        init(kind: String? = nil, delimiter: String? = nil, fields: [String]? = nil, trim: Bool? = nil) {
            self.kind = kind; self.delimiter = delimiter; self.fields = fields; self.trim = trim
        }
        enum CodingKeys: String, CodingKey { case kind, delimiter, fields, trim }
        init(from decoder: Decoder) throws {
            // `parse` may be the bare string "json" / a delimiter, OR an object.
            // Accept both so authors can write `"parse":"json"` (the common case).
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                kind = s; delimiter = nil; fields = nil; trim = nil; return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            delimiter = try c.decodeIfPresent(String.self, forKey: .delimiter)
            fields = try c.decodeIfPresent([String].self, forKey: .fields)
            trim = try c.decodeIfPresent(Bool.self, forKey: .trim)
        }
    }

    /// §5.4 — per-key value remap. EITHER a `$value` template string
    /// ("Volume: $value%") OR a lookup map ({"true":"Muted","false":""}).
    /// Tolerant: decodes whichever JSON shape is present.
    struct ManifestTransform: Codable, Hashable {
        var template: String?            // contains $value
        var map: [String: String]?       // exact-match lookup
        init(template: String? = nil, map: [String: String]? = nil) {
            self.template = template; self.map = map
        }
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                template = s; map = nil
            } else {
                template = nil
                map = try? decoder.singleValueContainer().decode([String: String].self)
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            if let t = template { try c.encode(t) } else { try c.encode(map ?? [:]) }
        }
        /// Apply to a raw value: map lookup wins; else template substitution; else identity.
        func apply(_ raw: String) -> String {
            if let m = map { return m[raw] ?? raw }
            if let t = template { return t.replacingOccurrences(of: "$value", with: raw) }
            return raw
        }
    }

    /// §5.1 — presentation axis.
    struct ManifestView: Codable, Hashable {
        var kind: String?                // "declarative" (default) | "webview"
        var entry: String?               // webview: relative HTML path in the pack
        init(kind: String? = nil, entry: String? = nil) { self.kind = kind; self.entry = entry }
        enum CodingKeys: String, CodingKey { case kind, entry }
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                kind = s; entry = nil; return       // allow `"view":"webview"` shorthand
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            entry = try c.decodeIfPresent(String.self, forKey: .entry)
        }
    }

    /// §5.5 / §10 — the push `monitor` process. Long-lived, NDJSON over stdio,
    /// spawned on demand. `caps` is advisory (what it pushes); the HOST enforces
    /// the real ceiling from the manifest's `capabilities` (§8), not from this.
    struct ManifestProvider: Codable, Hashable {
        var command: String              // e.g. "node provider.js" — relative to pack dir
        var args: [String]?
        var caps: [String]?              // advisory: ["state","image","devices"]
        init(command: String = "", args: [String]? = nil, caps: [String]? = nil) {
            self.command = command; self.args = args; self.caps = caps
        }
        enum CodingKeys: String, CodingKey { case command, args, caps }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
            args = try c.decodeIfPresent([String].self, forKey: .args)
            caps = try c.decodeIfPresent([String].self, forKey: .caps)
        }
    }

    /// §5.3 — a named, parameterized action referenced by a button's `run`.
    /// EITHER `kind`+`value` (a safe DeckAction) OR `interpreter`+`script`
    /// (multi-line osascript/zsh). `then:"refresh"` re-pulls after firing.
    struct ManifestAction: Codable, Hashable {
        var kind: String?                // safe action kind (§5.7); incl. activate/provider
        var value: String?
        var interpreter: String?         // "osascript" | "zsh" — alternative to kind/value
        var script: String?
        var params: [String]?            // names resolved from $config / caller
        var then: String?                // "refresh" | "none" (default)
        init(kind: String? = nil, value: String? = nil, interpreter: String? = nil,
             script: String? = nil, params: [String]? = nil, then: String? = nil) {
            self.kind = kind; self.value = value; self.interpreter = interpreter
            self.script = script; self.params = params; self.then = then
        }
        enum CodingKeys: String, CodingKey { case kind, value, interpreter, script, params, then }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            value = try c.decodeIfPresent(String.self, forKey: .value)
            interpreter = try c.decodeIfPresent(String.self, forKey: .interpreter)
            script = try c.decodeIfPresent(String.self, forKey: .script)
            params = try c.decodeIfPresent([String].self, forKey: .params)
            then = try c.decodeIfPresent(String.self, forKey: .then)
        }
        var wantsRefresh: Bool { then == "refresh" }
    }

    /// §6 — one row of the per-instance Config Panel form.
    struct ManifestConfigField: Codable, Hashable {
        var key: String                  // surfaces as $config.<key>
        var label: String?
        var type: String?                // text|toggle|slider|select|device-picker|connect-button|secret
        var min: Double?
        var max: Double?
        var `default`: String?
        var options: [String]?           // static select options
        var source: String?              // live options, e.g. "provider:devices"
        var action: String?              // connect-button: named action to fire (pairing/oauth)
        var secret: String?             // connect-button/secret: secret key to store the result
        init(key: String = "", label: String? = nil, type: String? = nil, min: Double? = nil,
             max: Double? = nil, default: String? = nil, options: [String]? = nil,
             source: String? = nil, action: String? = nil, secret: String? = nil) {
            self.key = key; self.label = label; self.type = type; self.min = min; self.max = max
            self.default = `default`; self.options = options; self.source = source
            self.action = action; self.secret = secret
        }
        enum CodingKeys: String, CodingKey {
            case key, label, type, min, max, `default`, options, source, action, secret
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            max = try c.decodeIfPresent(Double.self, forKey: .max)
            `default` = try c.decodeIfPresent(String.self, forKey: .default)
            options = try c.decodeIfPresent([String].self, forKey: .options)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            action = try c.decodeIfPresent(String.self, forKey: .action)
            secret = try c.decodeIfPresent(String.self, forKey: .secret)
        }
    }

    /// §7 — a keychain-backed secret this pack uses. Never serialized to the
    /// manifest/settings on disk; injected into provider/command env at spawn.
    struct ManifestSecret: Codable, Hashable {
        var key: String                  // GATECASTER_SECRET_<KEY> in child env
        var label: String?
        var oauth: Bool?                 // true ⇒ obtained via the oauth flow (§7)
        init(key: String = "", label: String? = nil, oauth: Bool? = nil) {
            self.key = key; self.label = label; self.oauth = oauth
        }
        enum CodingKeys: String, CodingKey { case key, label, oauth }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label)
            oauth = try c.decodeIfPresent(Bool.self, forKey: .oauth)
        }
    }

    /// §7 — browser auth round-trip. Host opens `authUrl`, catches the redirect
    /// (loopback HTTP or registered x-gatecaster:// scheme), stores the token.
    struct ManifestOAuth: Codable, Hashable {
        var authUrl: String?
        var redirect: String?            // "loopback" | "scheme"
        var scheme: String?              // when redirect == "scheme"
        var store: String?               // secret key to write the captured token to
        init(authUrl: String? = nil, redirect: String? = nil, scheme: String? = nil, store: String? = nil) {
            self.authUrl = authUrl; self.redirect = redirect; self.scheme = scheme; self.store = store
        }
        enum CodingKeys: String, CodingKey { case authUrl, redirect, scheme, store }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            authUrl = try c.decodeIfPresent(String.self, forKey: .authUrl)
            redirect = try c.decodeIfPresent(String.self, forKey: .redirect)
            scheme = try c.decodeIfPresent(String.self, forKey: .scheme)
            store = try c.decodeIfPresent(String.self, forKey: .store)
        }
    }
}

/// Discovers and caches installed extension manifests.
final class WidgetRegistry: ObservableObject {
    static let shared = WidgetRegistry()
    @Published private(set) var manifests: [WidgetManifest] = []

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Gatecaster/Extensions", isDirectory: true)
    }

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var found: [WidgetManifest] = []
        if let dirs = try? fm.contentsOfDirectory(at: Self.folder,
                                                  includingPropertiesForKeys: nil) {
            for dir in dirs {
                let manifestURL = dir.appendingPathComponent("manifest.json")
                if let data = try? Data(contentsOf: manifestURL),
                   let m = try? JSONDecoder().decode(WidgetManifest.self, from: data) {
                    found.append(m.normalized())   // §5.6 v1→v2 migrate on load
                }
            }
        }
        manifests = found.sorted { $0.name < $1.name }
    }

    func manifest(id: String) -> WidgetManifest? { manifests.first { $0.id == id } }
}

// MARK: - live values for extension refresh commands

/// Backs one visible extension tile. A tile is EITHER poll (`refresh`) OR push
/// (`provider`), never both (PLATFORM_SPEC §5.4). Both paths converge on the same
/// `values` dict — `fields[].refreshKey` reads it and (later) the WebView bridge
/// exposes it — so the tile renders identically regardless of data source.
final class WidgetDataSource: ObservableObject {
    @Published var values: [String: String] = [:]
    @Published var images: [String: Data] = [:]    // §9 dynamic tile images, by field key
    @Published var providerError: String?          // surfaced stale-not-wedged state
    private var timer: Timer?
    private var refresh: WidgetManifest.ManifestRefresh?   // retained for then:"refresh" re-poll
    // Provider push (§10). We hold the instance id so stop() can release our
    // ref-count with the host (the last release reaps the process).
    private weak var provider: ProviderProcess?
    private var providerInstance: UUID?

    // MARK: poll (§5.4)

    func start(_ refresh: WidgetManifest.ManifestRefresh) {
        stop()
        self.refresh = refresh
        let interval = max(2, refresh.everySeconds)
        let run = { [weak self] in self?.poll(refresh) }
        run()
        let t = Timer(timeInterval: interval, repeats: true) { _ in run() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-run the poll immediately (the `then:"refresh"` loop on a button action).
    func repoll() {
        if let r = refresh { poll(r) }
        else { provider?.requestRefresh() }
    }

    /// Forward a `provider`-kind action to this tile's running provider (§10.3).
    func sendToProvider(action: String, params: [String: String]) {
        provider?.send(action: action, params: params)
    }

    // MARK: push (§10)

    /// Acquire this tile instance's provider and route its patches into `values`.
    /// Returns the process so the tile can forward `provider`-kind button commands.
    @discardableResult
    func startProvider(_ manifest: WidgetManifest, instance: UUID,
                       config: [String: String]) -> ProviderProcess? {
        stop()
        guard let proc = ProviderHost.shared.acquire(manifest: manifest,
                                                     instance: instance, config: config)
        else {
            // No provider, or `process` capability not granted (§9.3 L4) — show a
            // clear error rather than a silently-dead tile.
            DispatchQueue.main.async { [weak self] in
                self?.providerError = "Provider unavailable (missing `process` capability?)"
            }
            return nil
        }
        let transform = manifest.refresh?.transform   // provider tiles may still declare transforms
        proc.onState = { [weak self] patch in
            guard let self else { return }
            // Shallow-merge the patch into our state, applying any per-key transform.
            var v = self.values
            for (k, raw) in patch { v[k] = transform?[k]?.apply(raw) ?? raw }
            self.values = v
            self.providerError = nil
        }
        proc.onImage = { [weak self] field, data in self?.images[field] = data }
        proc.onError = { [weak self] msg in self?.providerError = msg }
        provider = proc
        providerInstance = instance
        return proc
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let inst = providerInstance { ProviderHost.shared.release(instance: inst) }
        provider = nil; providerInstance = nil
    }
    deinit { stop() }

    private func poll(_ refresh: WidgetManifest.ManifestRefresh) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", refresh.command]
            let pipe = Pipe(); p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let raw = Self.parse(data, with: refresh.parse) else { return }
            // Apply per-key transforms (§5.4): map lookup or $value template.
            var out = raw
            if let tf = refresh.transform {
                for (k, t) in tf where out[k] != nil { out[k] = t.apply(out[k]!) }
            }
            DispatchQueue.main.async { self?.values = out }
        }
    }

    /// §5.4 — turn a refresh command's stdout into a flat key→value dict.
    /// nil / kind "json" = parse stdout as a flat JSON object (the v1 behavior).
    /// A delimited spec splits the FIRST non-empty line into the named fields.
    private static func parse(_ data: Data,
                              with spec: WidgetManifest.ManifestParse?) -> [String: String]? {
        let kind = spec?.kind ?? "json"
        if kind == "delimited", let delim = spec?.delimiter, let names = spec?.fields {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let parts = line.components(separatedBy: delim)
            var out: [String: String] = [:]
            for (i, name) in names.enumerated() where i < parts.count {
                let v = parts[i]
                out[name] = (spec?.trim == true) ? v.trimmingCharacters(in: .whitespaces) : v
            }
            return out
        }
        // Default: flat JSON object on stdout.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj.mapValues { "\($0)" }
    }
}

// MARK: - widget sizing (per-kind minimum + default spans)

/// Smallest span a widget renders well at. Resizing clamps to this; extensions
/// declare their own via the manifest (minW/minH).
func widgetMinSpan(_ w: DeckWidget) -> (w: Int, h: Int) {
    switch w.kind {
    case "volume":  return (1, 2)
    case "clock":   return (2, 1)
    case "media":   return (2, 1)
    case "claude":  return (2, 2)
    case "battery": return (1, 1)
    case "cpu":     return (1, 1)
    case "ram":     return (2, 1)
    case "emoji":   return (3, 1)
    case "timer":   return (2, 2)
    default:
        if let id = w.extensionId, let m = WidgetRegistry.shared.manifest(id: id) {
            return (max(1, m.minW ?? 2), max(1, m.minH ?? 1))
        }
        return (1, 1)
    }
}

/// Span a widget gets when first dropped (defaults to its minimum).
func widgetDefaultSpan(_ kind: String) -> (w: Int, h: Int) {
    switch kind {
    case "volume":  return (1, 2)
    case "clock":   return (2, 1)
    case "media":   return (2, 1)
    case "claude":  return (2, 2)
    case "battery": return (1, 1)
    case "cpu":     return (1, 1)
    case "ram":     return (2, 2)
    case "emoji":   return (4, 3)
    case "timer":   return (2, 2)
    default:
        let id = kind.hasPrefix("ext:") ? String(kind.dropFirst(4)) : kind
        if let m = WidgetRegistry.shared.manifest(id: id) {
            return (max(1, m.defaultW ?? m.minW ?? 2), max(1, m.defaultH ?? m.minH ?? 2))
        }
        return (2, 2)
    }
}

// MARK: - drag regions (draggable controls opt OUT of the deck's scroll routing)

/// Panel-local frames (top-left points, from SwiftUI `.global`) of on-screen
/// draggable controls — the built-in volume bar AND any third-party extension
/// `slider`/`dial` field. The deck routes one-finger drags below its header to a
/// native ScrollView by default (the engine drives the scroll, since SwiftUI
/// gestures don't receive our synthetic drags on a non-key panel). A draggable
/// control needs a real mouse DRAG instead, so it publishes its frame here and
/// `AppDelegate.deckScrollRegion` excludes these rects — making the engine send a
/// leftDown/leftDrag the control's gesture can track. Keyed by a per-control id;
/// entries are removed on disappear. Main-thread only (engine callbacks and
/// SwiftUI both touch it on main).
enum DeckDragRegions {
    static var dragRects: [UUID: CGRect] = [:]
}

// MARK: - widget tile views

/// Renders one widget; the grid sizes it to its span, so the tile fills its
/// placed frame. In edit mode it shows a gear (per-widget settings), a trash
/// (delete), and a bottom-right resize handle that changes the span in cells.
struct WidgetTile: View {
    @Binding var widget: DeckWidget
    let editing: Bool
    var cell: CGFloat = 80          // one grid cell, in points
    var step: CGFloat = 88          // cell + spacing: pitch between cells
    var maxCols: Int = 8
    var minW: Int = 1               // smallest span (per-kind / manifest)
    var minH: Int = 1
    var onDelete: () -> Void

    @State private var showConfig = false
    // Live resize preview (cells). The model is only updated on release, so the
    // handle never moves mid-drag — that feedback loop was the "jumps all over".
    @State private var previewW: Int?
    @State private var previewH: Int?

    private func ghostSize(_ cells: Int) -> CGFloat {
        cell * CGFloat(cells) + (step - cell) * CGFloat(cells - 1)
    }

    var body: some View {
        content
            // In edit mode the tile is a drag/resize target, so its live controls
            // (volume bar, media keys, timer, emoji, extension chips) go inert —
            // a tap there must not fire an action while you're arranging the deck.
            // The gear/trash/resize overlays are added AFTER this, so they stay live.
            .allowsHitTesting(!editing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: GC.Radius.tile)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: GC.Radius.tile)
                .strokeBorder(Color.primary.opacity(GC.Op.hairline), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: GC.Radius.tile))
            .overlay(alignment: .topLeading) { if previewW != nil { resizeGhost } }
            .overlay(alignment: .topTrailing) { if editing { editControls } }
            .overlay(alignment: .bottomTrailing) { if editing { resizeHandle } }
            .popover(isPresented: $showConfig) {
                WidgetConfigEditor(widget: $widget)
                    .gcPopoverChrome()   // opaque + system appearance: don't inherit the deck's glass/theme
            }
    }

    /// Snapped target outline drawn during a resize drag (anchored top-left,
    /// can extend past the current tile to show the new span).
    private var resizeGhost: some View {
        let w = previewW ?? widget.spanW
        let h = previewH ?? widget.spanH
        return RoundedRectangle(cornerRadius: GC.Radius.tile)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: GC.Radius.tile)
                .fill(Color.accentColor.opacity(0.12)))
            .frame(width: ghostSize(w), height: ghostSize(h), alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                Text("\(w)×\(h)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white).padding(4)
            }
            .allowsHitTesting(false)
    }

    private var editControls: some View {
        HStack(spacing: 4) {
            if WidgetConfigEditor.hasSettings(kind: widget.kind) {
                iconBtn("gearshape.fill", tint: .black, label: "Widget settings") { showConfig = true }
            }
            iconBtn("trash.fill", tint: .red, label: "Delete widget") { onDelete() }
        }
        .padding(4)
    }

    private func iconBtn(_ symbol: String, tint: Color, label: String,
                         _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white).frame(width: 22, height: 22)
                .background(Circle().fill(tint == .red
                    ? Color.red.opacity(0.85) : Color.black.opacity(0.5)))
        }
        .buttonStyle(GCPressStyle())
        .accessibilityLabel(label)
    }

    /// Drag to resize in whole cells. Updates only a PREVIEW during the drag
    /// (the model — and thus the tile size and this handle — stay put, so the
    /// gesture origin is stable and snapping is crisp). Commits on release.
    /// `highPriorityGesture` so the ScrollView doesn't steal the drag.
    private var resizeHandle: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.95))
            Image(systemName: "arrow.down.right")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle().size(width: 44, height: 44))   // forgiving hit area
        .padding(3)
        .highPriorityGesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                previewW = Swift.max(minW, Swift.min(maxCols,
                            widget.spanW + Int((g.translation.width / step).rounded())))
                previewH = Swift.max(minH, Swift.min(6,
                            widget.spanH + Int((g.translation.height / step).rounded())))
            }
            .onEnded { _ in
                if let w = previewW { widget.spanW = w }
                if let h = previewH { widget.spanH = h }
                previewW = nil; previewH = nil
            })
    }

    @ViewBuilder private var content: some View {
        switch widget.kind {
        case "clock":
            ClockWidget(h24: widget.config["h24"] == "1",
                        zones: (widget.config["zones"] ?? "")
                            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty })
        case "media": MediaWidget()
        case "volume": VolumeWidget(id: widget.id)
        case "claude": ClaudeUsageWidget(config: $widget.config)
        case "battery": BatteryWidget()
        case "cpu": CPUWidget()
        case "ram": RamWidget()
        case "emoji": EmojiWidget()
        case "timer": TimerWidget(config: $widget.config)
        default:
            if let id = widget.extensionId,
               let m = WidgetRegistry.shared.manifest(id: id) {
                ExtensionWidget(manifest: m, instance: widget.id, config: $widget.config)
            } else {
                MissingWidget(id: widget.extensionId ?? widget.kind)
            }
        }
    }
}

/// Per-widget settings popover (the gear). Options vary by widget kind.
struct WidgetConfigEditor: View {
    @Binding var widget: DeckWidget

    /// Kinds that actually have options — the gear is hidden for the rest
    /// (a popover saying "No settings" reads as broken, not informative).
    static func hasSettings(kind: String) -> Bool {
        kind == "claude" || kind == "clock"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Widget Settings").font(.system(size: 14, weight: .bold))
            switch widget.kind {
            case "claude":
                Text("Show").font(.system(size: 12, weight: .medium))
                Picker("", selection: cfg("display", "both")) {
                    Text("Tokens").tag("tokens")
                    Text("Percent").tag("percent")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented).labelsHidden()
                TextField("5-hour token limit", text: cfgText("limit5h"))
                    .textFieldStyle(.roundedBorder)
                TextField("Weekly token limit", text: cfgText("limitWeek"))
                    .textFieldStyle(.roundedBorder)
                Text("Percent needs a limit. Usage is summed from local Claude Code logs on this Mac only — not Claude.ai or the official plan limit.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case "clock":
                Toggle("24-hour clock", isOn: cfgBool("h24"))
                TextField("Time zones (comma-separated)", text: cfgText("zones"))
                    .textFieldStyle(.roundedBorder)
                Text("e.g. America/Los_Angeles, Europe/Zurich, Asia/Tokyo. Leave empty for local time. Tip: use IANA names.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text("No settings for this widget.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Text("Size \(widget.spanW)×\(widget.spanH)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(14).frame(width: 280)
    }

    private func cfgText(_ k: String) -> Binding<String> {
        Binding(get: { widget.config[k] ?? "" },
                set: { widget.config[k] = $0.isEmpty ? nil : $0 })
    }
    private func cfg(_ k: String, _ d: String) -> Binding<String> {
        Binding(get: { widget.config[k] ?? d }, set: { widget.config[k] = $0 })
    }
    private func cfgBool(_ k: String) -> Binding<Bool> {
        Binding(get: { widget.config[k] == "1" }, set: { widget.config[k] = $0 ? "1" : nil })
    }
}

/// Built-in: live time + date. Uses a DateFormatter (with en_US_POSIX) so the
/// 24-hour setting is honored reliably, and supports multiple time zones.
private struct ClockWidget: View {
    var h24 = false
    var zones: [String] = []          // IANA ids; empty = local single clock
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if zones.isEmpty {
                VStack(spacing: 2) {
                    Text(timeString(nil)).font(.system(size: 30, weight: .semibold).monospacedDigit())
                    Text(dateString(nil)).font(.system(size: 12)).foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(zones, id: \.self) { z in
                        HStack {
                            Text(zoneLabel(z)).font(.system(size: 12)).foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(timeString(TimeZone(identifier: z)))
                                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(tick) { now = $0 }
    }

    private func fmt(_ tz: TimeZone?) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let tz { f.timeZone = tz }
        return f
    }
    private func timeString(_ tz: TimeZone?) -> String {
        let f = fmt(tz); f.dateFormat = h24 ? "HH:mm:ss" : "h:mm:ss a"; return f.string(from: now)
    }
    private func dateString(_ tz: TimeZone?) -> String {
        let f = fmt(tz); f.dateFormat = "EEEE, MMM d"; return f.string(from: now)
    }
    private func zoneLabel(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }
}

/// Built-in: output volume. Drag or tap anywhere on the bar to set; tap-to-set
/// works even with click-only synthetic touches. Throttled to ~10 Hz.
private struct VolumeWidget: View {
    let id: UUID
    @State private var volume = 50.0
    @State private var lastSent = Date.distantPast

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13)).foregroundColor(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.8))
                        .frame(height: max(8, h * volume / 100))
                }
                .contentShape(Rectangle())
                // Publish the bar's screen-global frame (.global) so the engine excludes it
                // from deck scroll routing and instead sends a real mouse drag —
                // without this, a touch-drag here scrolls (the bar never updates).
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { DeckDragRegions.dragRects[id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { f in
                            DeckDragRegions.dragRects[id] = f
                        }
                })
                // highPriorityGesture: non-activating panel gesture disambiguation
                // drops plain .gesture() — this ensures the volume bar always wins.
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard h > 0 else { return }   // avoid NaN → Int(NaN) crash
                        volume = max(0, min(100, 100 * (1 - g.location.y / h)))
                        if Date().timeIntervalSince(lastSent) > 0.1 {
                            lastSent = Date(); DeckRunner.setVolume(Int(volume))
                        }
                    }
                    .onEnded { _ in DeckRunner.setVolume(Int(volume)) })
            }
            Text("\(Int(volume))").font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(8)
        .onDisappear { DeckDragRegions.dragRects[id] = nil }
    }
}

/// Built-in: now-playing-ish media controls via media keys.
private struct MediaWidget: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Media").font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 14) {
                btn("backward.fill") { DeckRunner.mediaKey(18) }
                btn("playpause.fill") { DeckRunner.mediaKey(16) }
                btn("forward.fill") { DeckRunner.mediaKey(17) }
            }
        }
    }
    private func btn(_ symbol: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// Third-party: declarative tile driven by a manifest + optional refresh poll.
private struct ExtensionWidget: View {
    let manifest: WidgetManifest
    let instance: UUID                           // stable tile-instance id (provider keying)
    @Binding var config: [String: String]       // persists toggle/multi-state across redraws
    @StateObject private var data = WidgetDataSource()

    private func isOn(_ i: Int) -> Bool { config["on.\(i)"] == "1" }
    private func setOn(_ i: Int, _ v: Bool) { config["on.\(i)"] = v ? "1" : nil }
    private func stateIndex(_ i: Int) -> Int { Int(config["st.\(i)"] ?? "") ?? 0 }
    private func setStateIndex(_ i: Int, _ v: Int) { config["st.\(i)"] = v == 0 ? nil : String(v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: manifest.symbol ?? "puzzlepiece.extension.fill")
                    .foregroundColor(Color(hex: manifest.colorHex ?? "#8E8E93"))
                Text(manifest.name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            ForEach(manifest.fields ?? [], id: \.label) { f in
                if f.type == "slider" || f.type == "dial" {
                    // Interactive set-value control (§5.9). Publishes its frame to
                    // DeckDragRegions so the engine routes a real mouse drag here
                    // (not deck scroll), and fires the field's action with $value.
                    InteractiveFieldView(
                        field: f,
                        liveValue: numericValue(for: f),
                        onSet: { fireField(f, $0) })
                } else {
                    HStack {
                        Text(f.label).font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Text(value(for: f)).font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
            if let buttons = manifest.buttons, !buttons.isEmpty {
                // Native ScrollView; the engine drives it with scroll-wheel
                // events so a tall pack (e.g. Figma's shortcuts) scrolls.
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                              spacing: 6) {
                        ForEach(buttons.indices, id: \.self) { i in
                            chip(buttons[i], index: i)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Data axis (§5.4): a tile is push (provider) OR poll (refresh) OR static.
        // Provider wins when present; the host ref-counts spawn/reap by instance.
        .onAppear {
            if manifest.hasProvider {
                data.startProvider(manifest, instance: instance, config: config)
            } else if let r = manifest.refresh {
                data.start(r)
            }
        }
        .onDisappear { data.stop() }
    }

    private func chip(_ b: WidgetManifest.ManifestButton, index: Int) -> some View {
        // Resolve current appearance + highlight across the three button kinds:
        // multi-state (states[]), toggle (on/off), or plain.
        let symbol: String?
        let label: String?
        let highlighted: Bool
        if let states = b.states, !states.isEmpty {
            let i = min(stateIndex(index), states.count - 1)
            symbol = states[i].symbol ?? b.symbol
            label = states[i].label ?? b.label
            highlighted = i != 0
        } else {
            let on = isOn(index)
            symbol = (on ? b.altSymbol : nil) ?? b.symbol
            label = (on ? b.altLabel : nil) ?? b.label
            highlighted = on
        }
        return Button {
            if let states = b.states, !states.isEmpty {
                let i = min(stateIndex(index), states.count - 1)
                DeckRunner.run(states[i].action)
                setStateIndex(index, (i + 1) % states.count)
            } else if b.toggle == true {
                if isOn(index) { setOn(index, false); fire(b.actionAlt ?? b.action) }
                else { setOn(index, true); fire(b.action) }
            } else if let ref = b.run {
                fireNamed(ref)                       // §5.3 — named action (params + then)
            } else {
                fire(b.action)
            }
        } label: {
            VStack(spacing: 3) {
                if let s = symbol { Image(systemName: s).font(.system(size: 16)) }
                if let l = label {
                    Text(l).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .foregroundColor(highlighted ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    private func value(for f: WidgetManifest.ManifestField) -> String {
        if let key = f.refreshKey, let v = data.values[key] { return v }
        return f.value ?? "—"
    }

    /// The field's current value as a number for slider/dial seeding — from live
    /// refresh data (refreshKey) or the static `value`, tolerating a trailing unit
    /// like "40%". nil ⇒ the control starts at `min` and is purely user-driven.
    private func numericValue(for f: WidgetManifest.ManifestField) -> Double? {
        let raw = (f.refreshKey.flatMap { data.values[$0] }) ?? f.value
        guard let raw else { return nil }
        let num = raw.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(num)
    }

    // MARK: - action firing (inline + named, §5.3/§5.7)

    /// Fire an inline `action`, substituting `$config.<key>` in its value first.
    private func fire(_ a: DeckAction) {
        DeckRunner.run(DeckAction(kind: a.kind, value: substitute(a.value)))
    }

    /// Fire a named action referenced by a button's `run` (§5.3).
    private func fireNamed(_ ref: String) {
        guard let act = manifest.actions?[ref] else { return }
        runManifest(act, label: ref)
    }

    /// Fire a slider/dial field's set-value action (§5.9): `run` (named) wins over
    /// inline `action`; the dragged int is injected as `$value`. No-op if neither.
    private func fireField(_ f: WidgetManifest.ManifestField, _ value: Double) {
        let token = String(Int(value.rounded()))
        if let ref = f.run, let act = manifest.actions?[ref] {
            runManifest(act, label: ref, value: token)
        } else if let act = f.action {
            runManifest(act, label: f.label, value: token)
        }
    }

    /// Core action runner shared by named-button `run` and slider/dial fields.
    /// Resolves the action shape, enforces the capability ceiling (§8/§9.3 L4),
    /// handles the `provider`/`interpreter` forms the declarative `DeckAction`
    /// can't express, substitutes `$value` (when set) then `$config`, and runs
    /// `then:"refresh"` to close the input→state loop.
    private func runManifest(_ act: WidgetManifest.ManifestAction, label: String, value: String? = nil) {
        let caps = PluginCapabilities(manifest)
        let sub: (String) -> String = { substitute($0, value: value) }

        if let kind = act.kind {
            // Capability gate: a privileged kind runs only if declared (§9.3 L4).
            guard caps.allows(kind: kind) else {
                data.providerError = "Action “\(label)” needs the `\(kind)` capability"
                return
            }
            if kind == "provider" {
                // Forward to this tile's running provider over its stdin (§10.3).
                data.sendToProvider(action: sub(act.value ?? ""),
                                    params: resolveParams(act.params))
            } else if let mapped = DeckActionKind(rawValue: kind) {
                DeckRunner.run(DeckAction(kind: mapped, value: sub(act.value ?? "")))
            }
        } else if let interp = act.interpreter, let script = act.script {
            // Multi-line osascript/zsh (§5.7) — gated by `shell`.
            guard caps.canRunShell else {
                data.providerError = "Action “\(label)” needs the `shell` capability"
                return
            }
            let exe = interp == "osascript" ? "/usr/bin/osascript" : "/bin/zsh"
            let args = interp == "osascript" ? ["-e", sub(script)]
                                             : ["-lc", sub(script)]
            DeckRunner.runProcess(exe, args)
        }

        if act.wantsRefresh { data.repoll() }   // then:"refresh"
    }

    /// Replace `$value` (when set) then `$config.<key>` tokens. `$value` is the
    /// live slider/dial position; substituted first so a config value can't shadow
    /// it. (§5.8/§5.9/§6).
    private func substitute(_ s: String, value: String? = nil) -> String {
        var out = s
        if let v = value { out = out.replacingOccurrences(of: "$value", with: v) }
        for (k, v) in config where k.hasPrefix("$") == false {
            out = out.replacingOccurrences(of: "$config.\(k)", with: v)
        }
        return out
    }

    /// Resolve a named action's `params` to a {name: value} dict from `$config`.
    private func resolveParams(_ names: [String]?) -> [String: String] {
        var out: [String: String] = [:]
        for n in names ?? [] { out[n] = config[n] ?? "" }
        return out
    }
}

/// Publishes a view's screen frame into `DeckDragRegions` so the engine routes a
/// one-finger touch over it as a real mouse DRAG (not deck scroll), and clears the
/// entry on disappear. The single-param `onChange` matches the rest of the file
/// (deprecation warning is intentional parity, not an oversight).
private struct DragRegion: ViewModifier {
    let id: UUID
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { DeckDragRegions.dragRects[id] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { DeckDragRegions.dragRects[id] = $0 }
        })
    }
}

/// Interactive `slider`/`dial` field (§5.9). Once touched it OWNS its value
/// locally (live refresh data only seeds the initial position — same model as the
/// built-in VolumeWidget, which avoids a refresh-vs-drag feedback fight), publishes
/// its frame so a touch becomes a real mouse drag, throttles firing to ~10 Hz, and
/// always fires once more on release so the final position lands.
private struct InteractiveFieldView: View {
    let field: WidgetManifest.ManifestField
    let liveValue: Double?
    let onSet: (Double) -> Void

    @State private var dragValue: Double? = nil   // owns the value once the user drags
    @State private var lastSent = Date.distantPast
    @State private var rectID = UUID()
    // Dial only: previous touch angle for RELATIVE turning, and whether the finger
    // actually moved this gesture — so a tap doesn't jump or fire (a knob changes
    // by rotation, not by where you land).
    @State private var lastAngle: Double? = nil
    @State private var turned = false

    private var lo: Double { field.min ?? 0 }
    // Guard hi > lo so the (hi-lo) divisor can't be 0/negative (→ NaN → Int crash).
    private var hi: Double { Swift.max((field.min ?? 0) + 1, field.max ?? 100) }
    private var current: Double { Swift.min(hi, Swift.max(lo, dragValue ?? liveValue ?? lo)) }
    private var frac: CGFloat { CGFloat((current - lo) / (hi - lo)) }
    private var isHorizontal: Bool { field.orientation == "horizontal" }

    var body: some View {
        VStack(spacing: 4) {
            if !field.label.isEmpty {
                Text(field.label).font(.system(size: 10)).foregroundColor(.secondary)
            }
            if field.type == "dial" { dial } else { slider }
            Text("\(Int(current))").font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .onDisappear { DeckDragRegions.dragRects[rectID] = nil }
    }

    // Commit an absolute value (clamped), throttled while dragging.
    private func commitValue(_ v: Double, throttled: Bool) {
        let clamped = Swift.min(hi, Swift.max(lo, v))
        dragValue = clamped
        if !throttled || Date().timeIntervalSince(lastSent) > 0.1 {
            lastSent = Date(); onSet(clamped)
        }
    }

    // Slider: a 0..1 fraction → absolute value (tap-to-position is fine for a bar).
    private func commit(frac f: CGFloat, throttled: Bool) {
        commitValue(lo + Double(Swift.min(1, Swift.max(0, f))) * (hi - lo), throttled: throttled)
    }

    private var slider: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: isHorizontal ? .leading : .bottom) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.85))
                    .frame(width: isHorizontal ? Swift.max(6, w * frac) : nil,
                           height: isHorizontal ? nil : Swift.max(6, h * frac))
            }
            .contentShape(Rectangle())
            .modifier(DragRegion(id: rectID))
            // highPriorityGesture: panel gesture disambiguation drops plain
            // .gesture() — this makes the control always win the drag.
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard w > 0, h > 0 else { return }       // avoid NaN
                    let f = isHorizontal ? (g.location.x / w) : (1 - g.location.y / h)
                    commit(frac: f, throttled: true)
                }
                .onEnded { _ in onSet(current) })
        }
        .frame(height: isHorizontal ? 18 : 60)
    }

    /// Skeuomorphic rotary knob. A 270° value sweep (lo at 7:30 → hi at 4:30, gap
    /// at the bottom) drawn as: a tick-marked dished bezel, a metallic domed cap
    /// (radial gradient + top sheen + drop shadow), and a pointer notch that turns
    /// with the value. The pointer rotation `-135 + frac·270` is the exact inverse
    /// of the drag's `atan2`-from-top math, so the cap points where the finger is.
    private var dial: some View {
        GeometryReader { geo in
            let s = Swift.min(geo.size.width, geo.size.height)
            let pointerAngle = -135.0 + Double(frac) * 270.0   // 0° = straight up
            ZStack {
                // Value arc on the bezel: dim track + bright fill, gap at bottom.
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.secondary.opacity(0.20),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * frac)
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))

                // Tick marks around the active sweep (skeuomorphic gauge dashes).
                ForEach(0..<11, id: \.self) { i in
                    Capsule().fill(Color.secondary.opacity(0.35))
                        .frame(width: 1.5, height: s * 0.05)
                        .offset(y: -s * 0.43)
                        .rotationEffect(.degrees(-135 + Double(i) / 10 * 270))
                }

                // Metallic domed cap: radial gradient (light top-left → dark) for
                // the dome, a soft top sheen, a rim stroke, and a contact shadow.
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(white: 0.46), Color(white: 0.20), Color(white: 0.12)],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: 1, endRadius: s * 0.42))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
                    .overlay(
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(0.28), .clear],
                                startPoint: .top, endPoint: .center))
                            .padding(s * 0.06).blur(radius: 1))
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                    .padding(s * 0.18)

                // Pointer notch on the cap — turns with the value.
                Capsule().fill(Color.white.opacity(0.92))
                    .frame(width: 3, height: s * 0.17)
                    .offset(y: -s * 0.16)
                    .rotationEffect(.degrees(pointerAngle))
                    .shadow(color: .black.opacity(0.5), radius: 1)

                Text("\(Int(current))")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.9))
                    .offset(y: s * 0.04)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            .modifier(DragRegion(id: rectID))
            // RELATIVE turn: the knob changes by how far you ROTATE, not where you
            // tap. The first touch only records a reference angle (no jump); each
            // move adds its angular delta (over the 270° sweep) to the value. A
            // pure tap never moves, so it neither changes nor fires.
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let cx = geo.size.width / 2, cy = geo.size.height / 2
                    // atan2(dx, -dy): 0 at top (12 o'clock), positive clockwise.
                    let a = atan2(g.location.x - cx, cy - g.location.y) * 180 / .pi
                    guard let prev = lastAngle else { lastAngle = a; return }
                    var d = a - prev
                    if d > 180 { d -= 360 } else if d < -180 { d += 360 }  // shortest arc
                    lastAngle = a
                    turned = true
                    commitValue(current + Double(d) / 270 * (hi - lo), throttled: true)
                }
                .onEnded { _ in
                    if turned { onSet(current) }   // skip a no-move tap
                    lastAngle = nil; turned = false
                })
        }
        .frame(height: 86)
    }
}

/// Shown when a widget references an extension that isn't installed — never a
/// mystery "?" (the Stream Deck complaint); keeps its config, badges clearly.
private struct MissingWidget: View {
    let id: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Missing extension").font(.system(size: 11, weight: .semibold))
            Text(id).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - built-in: Claude usage

/// Reads Claude Code's local session logs (~/.claude/projects/**/*.jsonl) and
/// reconstructs usage the way ccusage does:
///  - de-duplicates entries by message id + request id (logs repeat across
///    resumed sessions / multiple files);
///  - groups entries into 5-hour SESSION BLOCKS — a block starts at the first
///    message (floored to the hour, UTC) and ends 5h later or after a >5h gap,
///    matching Claude's own window, not a naive "last 5 hours";
///  - reports the ACTIVE block's tokens (the 5-hour number), the rolling
///    7-day total (weekly), and the largest historical block (used as an
///    auto limit so % is meaningful without knowing your plan cap).
/// Purely local; no network. Off-thread on a 60s timer.
final class ClaudeUsage: ObservableObject {
    @Published var window5h = 0          // tokens in the currently-active 5h block
    @Published var week = 0              // rolling 7-day total
    @Published var maxBlock = 0          // largest block ever (auto-limit denominator)
    @Published var available = true
    private var timer: Timer?

    func start() {
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = Self.scan()
            DispatchQueue.main.async {
                self?.window5h = r.active; self?.week = r.week
                self?.maxBlock = r.maxBlock; self?.available = r.ok
            }
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? iso.date(from: s)
    }
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private static func floorHour(_ d: Date) -> Date {
        utcCal.date(from: utcCal.dateComponents([.year, .month, .day, .hour], from: d)) ?? d
    }

    static func scan() -> (active: Int, week: Int, maxBlock: Int, ok: Bool) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { return (0, 0, 0, false) }

        // 1) collect + de-dup entries (date, tokens)
        var seen = Set<String>()
        var entries: [(date: Date, tokens: Int)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = parseDate(tsStr) else { continue }
                let tok = tokens(in: obj)
                if tok == 0 { continue }
                if let key = dedupKey(obj) {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                entries.append((ts, tok))
            }
        }
        if entries.isEmpty { return (0, 0, 0, false) }
        entries.sort { $0.date < $1.date }

        // 2) 7-day rolling total
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let week = entries.filter { $0.date >= weekAgo }.reduce(0) { $0 + $1.tokens }

        // 3) 5-hour session blocks (ccusage algorithm)
        let blockSecs: TimeInterval = 5 * 3600
        var blocks: [(start: Date, tokens: Int)] = []
        var start: Date?, last: Date?, sum = 0
        for e in entries {
            if let s = start, let l = last,
               e.date.timeIntervalSince(s) < blockSecs,
               e.date.timeIntervalSince(l) < blockSecs {
                sum += e.tokens; last = e.date
            } else {
                if let s = start { blocks.append((s, sum)) }
                start = floorHour(e.date); last = e.date; sum = e.tokens
            }
        }
        if let s = start { blocks.append((s, sum)) }

        let maxBlock = blocks.map(\.tokens).max() ?? 0
        // active = the last block if it's still within its 5h window
        var active = 0
        if let lastBlock = blocks.last,
           now.timeIntervalSince(lastBlock.start) < blockSecs {
            active = lastBlock.tokens
        }
        return (active, week, maxBlock, true)
    }

    /// ccusage-style de-dup key: message id + request id when present.
    private static func dedupKey(_ obj: [String: Any]) -> String? {
        let mid = (obj["message"] as? [String: Any])?["id"] as? String
        let rid = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
        if mid == nil && rid == nil { return nil }
        return "\(mid ?? "")|\(rid ?? "")"
    }

    private static func tokens(in obj: [String: Any]) -> Int {
        if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
            return sumUsage(u)
        }
        if let u = obj["usage"] as? [String: Any] { return sumUsage(u) }
        return 0
    }
    private static func sumUsage(_ u: [String: Any]) -> Int {
        ["input_tokens", "output_tokens",
         "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
    }
}

/// Compact token formatter: 1234 → "1.2k", 1_200_000 → "1.2M".
func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

/// Built-in Claude usage tile: two rolling-window bars (5-hour, weekly). If the
/// widget config carries `limit5h` / `limitWeek` token caps, the bars show a
/// percentage of that cap; otherwise the 5-hour bar is shown relative to the
/// weekly total as a rough at-a-glance fill.
struct ClaudeUsageWidget: View {
    @Binding var config: [String: String]
    @StateObject private var usage = ClaudeUsage()

    private var limit5h: Int? { config["limit5h"].flatMap { Int($0) } }
    private var limitWeek: Int? { config["limitWeek"].flatMap { Int($0) } }
    private var display: String { config["display"] ?? "both" }  // tokens | percent | both

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(Color(hex: "#D97757"))
                Text("Claude Usage").font(.system(size: 12, weight: .semibold))
            }
            if usage.available {
                // 5h bar: explicit limit, else auto-calibrate to the largest
                // block seen so far (ccusage's "-t max" trick).
                meter(title: "5-hour", value: usage.window5h, limit: limit5h,
                      fallbackMax: max(usage.maxBlock, 1), tint: Color(hex: "#D97757"))
                meter(title: "Week", value: usage.week, limit: limitWeek,
                      fallbackMax: max(usage.week, 1), tint: Color(hex: "#3478F6"))
            } else {
                Text("No Claude logs found")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { usage.start() }
        .onDisappear { usage.stop() }
    }

    /// Readout respects the display mode: tokens, percent (needs a limit), or both.
    private func readout(_ value: Int, _ limit: Int?) -> String {
        let total = formatTokens(value)
        guard let lim = limit, lim > 0 else {
            return display == "percent" ? "— set limit" : total
        }
        let pct = Int(Swift.min(1.0, Double(value) / Double(lim)) * 100)
        switch display {
        case "tokens":  return "\(total) / \(formatTokens(lim))"
        case "percent": return "\(pct)%"
        default:        return "\(pct)%  ·  \(total)"
        }
    }

    @ViewBuilder
    private func meter(title: String, value: Int, limit: Int?,
                       fallbackMax: Int, tint: Color) -> some View {
        let cap = Double(limit ?? fallbackMax)
        let frac = cap > 0 ? Swift.min(1.0, Double(value) / cap) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(readout(value, limit))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: Swift.max(4, geo.size.width * frac))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - built-in: Battery

/// Battery level + charging state via `pmset -g batt` (no extra entitlements).
private struct BatteryWidget: View {
    @State private var percent = 0
    @State private var charging = false
    @State private var present = true
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 80 || geo.size.width < 120
            if compact {
                StatCompact(symbol: icon, tint: tint,
                            value: present ? "\(percent)%" : "—")
            } else {
                StatFull(title: "Battery", symbol: icon, tint: tint,
                         value: present ? "\(percent)%" : "No battery",
                         percent: present ? percent : nil)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }
    private var tint: Color {
        if charging { return .green }
        return percent <= 20 ? .red : .accentColor
    }
    private var icon: String {
        charging ? "battery.100.bolt"
            : percent <= 20 ? "battery.25" : "battery.100"
    }
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let out = shell("/usr/bin/pmset", ["-g", "batt"])
            var pct = 0, chg = false, has = false
            if let m = out.range(of: #"(\d+)%"#, options: .regularExpression) {
                pct = Int(out[m].dropLast()) ?? 0; has = true
            }
            let low = out.lowercased()
            chg = low.contains("charging") || low.contains("charged") || low.contains("ac power")
            if low.contains("discharging") { chg = false }
            DispatchQueue.main.async { percent = pct; charging = chg; present = has }
        }
    }
}

// MARK: - built-in: CPU load

/// System-wide CPU usage (%), sampled from host_processor_info deltas.
private struct CPUWidget: View {
    @State private var usage = 0
    @State private var prevTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 80 || geo.size.width < 120
            let tint: Color = usage > 80 ? .red : .accentColor
            if compact {
                StatCompact(symbol: "cpu", tint: tint, value: "\(usage)%")
            } else {
                StatFull(title: "CPU", symbol: "cpu", tint: tint,
                         value: "\(usage)%", percent: usage)
            }
        }
        .onAppear(perform: sample)
        .onReceive(tick) { _ in sample() }
    }

    private func sample() {
        // Compute the count from the struct size (HOST_CPU_LOAD_INFO_COUNT isn't
        // reliably imported into Swift); host_cpu_load_info_data_t is the value type.
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let u = info.cpu_ticks.0, s = info.cpu_ticks.1, i = info.cpu_ticks.2, n = info.cpu_ticks.3
        if let p = prevTicks {
            let du = Double(u &- p.user), ds = Double(s &- p.sys)
            let di = Double(i &- p.idle), dn = Double(n &- p.nice)
            let busy = du + ds + dn, total = busy + di
            if total > 0 { usage = Int((busy / total) * 100) }
        }
        prevTicks = (u, s, i, n)
    }
}

// MARK: - shared stat tile layouts

/// Compact single-cell stat: centered icon + value (e.g. "62%").
private struct StatCompact: View {
    let symbol: String
    let tint: Color
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundColor(tint)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full stat tile: header (icon + title), big value, progress bar.
private struct StatFull: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var percent: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundColor(tint)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            Text(value).font(.system(size: 26, weight: .semibold).monospacedDigit())
            if let percent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(tint)
                            .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - built-in: RAM

/// Memory usage via host_statistics64 + total from ProcessInfo; swap from sysctl.
private struct RamWidget: View {
    @State private var percent = 0
    @State private var usedGB = 0.0
    @State private var freeGB = 0.0
    @State private var swapGB = 0.0
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 80 || geo.size.width < 120
            let tint: Color = percent > 85 ? .red : (percent > 70 ? .orange : .accentColor)
            if compact {
                StatCompact(symbol: "memorychip", tint: tint, value: "\(percent)%")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip").foregroundColor(tint)
                        Text("RAM").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(percent)%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule().fill(tint)
                                .frame(width: max(4, g.size.width * CGFloat(percent) / 100))
                        }
                    }
                    .frame(height: 6)
                    row("Used", String(format: "%.1f GB", usedGB))
                    row("Free", String(format: "%.1f GB", freeGB))
                    if swapGB > 0.05 { row("Swap", String(format: "%.1f GB", swapGB)) }
                }
                .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: sample)
        .onReceive(tick) { _ in sample() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    private func sample() {
        DispatchQueue.global(qos: .utility).async {
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            var stats = vm_statistics64_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
            let kr = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            let page = Double(vm_kernel_page_size)
            var usedBytes = 0.0
            if kr == KERN_SUCCESS {
                let active = Double(stats.active_count)
                let wired = Double(stats.wire_count)
                let compressed = Double(stats.compressor_page_count)
                usedBytes = (active + wired + compressed) * page
            }
            // swap
            var swap = xsw_usage()
            var sz = MemoryLayout<xsw_usage>.size
            var swapUsed = 0.0
            if sysctlbyname("vm.swapusage", &swap, &sz, nil, 0) == 0 {
                swapUsed = Double(swap.xsu_used)
            }
            let gb = 1024.0 * 1024.0 * 1024.0
            let pct = total > 0 ? Int(usedBytes / total * 100) : 0
            DispatchQueue.main.async {
                percent = pct
                usedGB = usedBytes / gb
                freeGB = max(0, (total - usedBytes) / gb)
                swapGB = swapUsed / gb
            }
        }
    }
}

/// Run a process and return its stdout as a string (utility queue caller).
private func shell(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - built-in: Countdown timer

/// A countdown timer styled after the iOS dial. The iOS clock sets the time by
/// dragging a knob around the ring — but on the deck a one-finger drag is routed
/// to engine scrolling, so dragging a knob would fight the scroll engine. Instead
/// this uses **tap controls**: preset chips, ±1:00 / ±0:10 steppers, and a
/// start/pause + reset pair. The ring is a live progress indicator, not a drag
/// target. The configured duration persists in the widget config; the running
/// state is transient (resets when the deck reloads), which matches how a kitchen
/// timer behaves and keeps state simple.
private struct TimerWidget: View {
    @Binding var config: [String: String]

    // Total configured duration (seconds) and remaining time while running.
    @State private var total: Int = 300
    @State private var remaining: Int = 300
    @State private var running = false
    @State private var endDate: Date?       // wall-clock target, so it stays
                                            // accurate even if ticks are missed
    @State private var firedAt: Date?       // de-dupes the completion chime

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let presets: [(label: String, secs: Int)] =
        [("1m", 60), ("3m", 180), ("5m", 300), ("10m", 600), ("25m", 1500)]

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 150 || geo.size.width < 150
            VStack(spacing: compact ? 6 : 10) {
                dial(compact: compact)
                if !compact { presetRow }
                controlRow(compact: compact)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(compact ? 6 : 10)
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in step() }
    }

    // MARK: ring + readout

    private func dial(compact: Bool) -> some View {
        let frac = total > 0 ? Double(remaining) / Double(total) : 0
        let ring: CGFloat = compact ? 64 : 104
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.12),
                            style: StrokeStyle(lineWidth: compact ? 6 : 9))
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, frac))))
                .stroke(ringTint,
                        style: StrokeStyle(lineWidth: compact ? 6 : 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: remaining)
            Text(clock(remaining))
                .font(.system(size: compact ? 18 : 30, weight: .semibold).monospacedDigit())
                .foregroundColor(remaining == 0 ? .red : .primary)
        }
        .frame(width: ring, height: ring)
        .frame(maxWidth: .infinity)
    }

    private var ringTint: Color {
        if remaining == 0 { return .red }
        return remaining <= 10 && running ? .orange : .accentColor
    }

    // MARK: controls

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.secs) { p in
                Button { setTotal(p.secs) } label: {
                    Text(p.label)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(total == p.secs
                            ? Color.accentColor.opacity(0.25)
                            : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            if !running && remaining == total {
                stepBtn("minus", compact) { adjust(-60) }
                stepBtn("plus", compact) { adjust(+60) }
            }
            Button(action: toggle) {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 14 : 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                    .background(Circle().fill(running ? Color.orange : Color.green))
            }
            .buttonStyle(.plain)
            .disabled(remaining == 0)
            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: compact ? 13 : 16, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
    }

    private func stepBtn(_ symbol: String, _ compact: Bool,
                         _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                .background(Circle().fill(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    // MARK: logic

    private func clock(_ s: Int) -> String {
        let m = s / 60, sec = s % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func load() {
        if let t = Int(config["seconds"] ?? ""), t > 0 { total = t }
        remaining = total
    }

    private func setTotal(_ s: Int) {
        total = s; remaining = s; running = false; endDate = nil; firedAt = nil
        config["seconds"] = String(s)
    }

    private func adjust(_ delta: Int) {
        let s = max(10, min(24 * 3600, total + delta))
        setTotal(s)
    }

    private func toggle() {
        if running {
            running = false; endDate = nil
            remaining = max(0, remaining)        // freeze where we are
        } else {
            guard remaining > 0 else { return }
            running = true
            endDate = Date().addingTimeInterval(Double(remaining))
        }
    }

    private func reset() {
        running = false; endDate = nil; firedAt = nil; remaining = total
    }

    private func step() {
        guard running, let end = endDate else { return }
        let left = Int(ceil(end.timeIntervalSinceNow))
        if left <= 0 {
            remaining = 0; running = false; endDate = nil
            if firedAt == nil { firedAt = Date(); chime() }
        } else {
            remaining = left
        }
    }

    /// Completion alert: the system "complete" sound + a screen flash via the
    /// shared media-free path (just NSSound here to avoid stealing focus).
    private func chime() {
        NSSound(named: "Glass")?.play()
    }
}

// MARK: - built-in: Emoji picker

/// A scrollable emoji grid (macOS-style). Tapping types the emoji into the
/// focused app via a synthesized Unicode keystroke. Recently-used row on top.
private struct EmojiWidget: View {
    @State private var recent: [String] = []
    @State private var category = 0

    private static let categories: [(name: String, symbol: String, emoji: [String])] = [
        ("Smileys", "face.smiling",
         "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤗 🤭 🤫 🤔 🤐 😐 😑 😶 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐".split(separator: " ").map(String.init)),
        ("Gestures", "hand.raised",
         "👍 👎 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👋 🤚 🖐️ ✋ 🖖 👏 🙌 🤝 🙏 💪 🫶 ❤️ 🔥 ⭐️ ✨ 🎉 ✅ ❌ ⚠️ 💯".split(separator: " ").map(String.init)),
        ("Objects", "lightbulb",
         "💻 ⌨️ 🖥️ 🖱️ 📱 ⏰ 📅 📌 📎 ✏️ 📝 📚 💡 🔋 🔌 🎧 🎵 📷 🎥 🔍 🔒 🔑 🛠️ ⚙️ 🚀 ☕️ 🍕 🍔 🎮 🏆".split(separator: " ").map(String.init)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Segmented control (icons).
            HStack(spacing: 0) {
                ForEach(Self.categories.indices, id: \.self) { i in
                    let sel = i == category
                    Image(systemName: Self.categories[i].symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(sel ? Color.accentColor : Color.clear))
                        .foregroundColor(sel ? .white : .secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { category = i }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
            .padding(.horizontal, 8).padding(.top, 6)

            // Native ScrollView — the engine drives it with synthesized
            // scroll-wheel events (see Engine.deckScrollAt). Indicators hidden
            // for a clean, iOS-like touch look.
            ScrollView { grid }.id(category)
                .scrollIndicators(.hidden)
        }
    }

    private var grid: some View {
        let cols = [GridItem(.adaptive(minimum: 46), spacing: 6)]
        return VStack(alignment: .leading, spacing: 6) {
            if !recent.isEmpty {
                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(recent, id: \.self) { e in cell(e) }
                }
                Divider()
            }
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(Self.categories[category].emoji, id: \.self) { e in cell(e) }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func cell(_ e: String) -> some View {
        Text(e).font(.system(size: 30))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                DeckRunner.typeText(e)
                recent.removeAll { $0 == e }
                recent.insert(e, at: 0)
                if recent.count > 12 { recent.removeLast() }
            }
    }
}

