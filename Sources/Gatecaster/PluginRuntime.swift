//  PluginRuntime.swift
//  Gatecaster — Deck extension platform, schema v2 runtime (PLATFORM_SPEC §7/§8/§10).
//
//  This file holds the *out-of-tile* machinery a v2 plugin can use:
//    • SecretStore        — keychain-backed tokens, env-injected, never on disk (§7)
//    • PluginCapabilities — the declared `capabilities` set = the runtime ceiling (§8)
//    • ProviderProcess    — the long-lived `monitor` child: NDJSON over stdio (§10)
//    • ProviderHost       — ref-counted spawn-on-demand / reap-on-idle manager (§10.4)
//
//  Hard boundary (PLATFORM_SPEC §10 isolation blockquote): the provider is its own
//  stdio pipe. It NEVER connects to the Touch API socket (api.sock), never reads
//  fingers/gestures, and there is deliberately NO `suppress` path here — muting
//  system input is reserved for first-party Touch API clients only. We resemble the
//  Touch API transport (NDJSON, `v` on every line, lease-by-close) without coupling
//  to it. A `shell`/`process` plugin could of course open api.sock itself at user
//  privilege; that leak closes only with the P2 sandbox (§14 P2-1). The rule we can
//  enforce is "no plugin path *offers* suppress," not a containment claim.

import Foundation
import Security

// MARK: - Secret store (§7)

/// Keychain-backed secret storage, keyed per `(extension id, secret key)`.
/// Secrets are NEVER written to the manifest or `~/v17ut-settings.json`; they live
/// only in the login keychain and are injected into child processes as env vars
/// (`GATECASTER_SECRET_<KEY>`). This is the §7 "host holds the token, the plugin
/// only ever sees it via env" contract — a plugin ships zero credential-handling
/// code and never touches the user's actual login.
enum SecretStore {
    private static let service = "com.gatecaster.secret"

    /// Account string namespaces a secret to its owning extension so two packs
    /// can both declare a `token` key without colliding.
    private static func account(_ ext: String, _ key: String) -> String { "\(ext)/\(key)" }

    static func get(ext: String, key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(ext, key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    @discardableResult
    static func set(ext: String, key: String, value: String) -> Bool {
        let acct = account(ext, key)
        // Update-or-insert: try to update an existing item first, fall back to add.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(ext: String, key: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(ext, key),
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }

    /// Build the `GATECASTER_SECRET_<KEY>` env slice for a manifest's declared
    /// secrets that actually exist in the keychain. Missing secrets are simply
    /// absent (the child decides whether it can run without them).
    static func env(for manifest: WidgetManifest) -> [String: String] {
        var out: [String: String] = [:]
        for s in manifest.secrets ?? [] where !s.key.isEmpty {
            if let v = get(ext: manifest.id, key: s.key) {
                out["GATECASTER_SECRET_\(s.key.uppercased())"] = v
            }
        }
        return out
    }
}

// MARK: - Capability model (§8)

/// The declared `capabilities` set, treated as the runtime ceiling (§8/§9.3 L4).
/// Disclosure without enforcement is theater, so the cheap, *real* gates live
/// here: a provider may spawn only with `process`; a shell/interpreter action
/// runs only with `shell`. `network` is modeled and disclosed but NOT contained
/// before the P2 sandbox (§9.3 "disclosed, not contained", §14 P2-1) — we never
/// pretend otherwise.
struct PluginCapabilities {
    let granted: Set<String>
    init(_ manifest: WidgetManifest) { granted = Set(manifest.capabilities ?? []) }

    var canSpawnProvider: Bool { granted.contains("process") }
    var canRunShell: Bool { granted.contains("shell") }
    var hasNetwork: Bool { granted.contains("network") }
    var hasSecrets: Bool { granted.contains("secrets") }
    var shipsNativeBinary: Bool { granted.contains("native-binary") }

    /// Whether a given v2 action kind is permitted by the declared ceiling.
    /// Pure declarative kinds (app/url/keystroke/…) need nothing; the privileged
    /// ones gate on a declared capability. Unknown kinds default-deny the
    /// privileged path but are harmless for declarative tiles.
    func allows(kind: String) -> Bool {
        switch kind {
        case "shell": return canRunShell
        case "provider": return canSpawnProvider
        default: return true   // app/url/keystroke/shortcut/volume/media/page/activate
        }
    }
}

// MARK: - Provider process (§10) — the push `monitor`

/// One long-lived headless child process for a provider-backed tile instance.
/// Mirrors the Touch API transport: NDJSON, one object per line, `v` on every
/// message, additive-compatible, lease-by-close. Push, not poll — the tile
/// updates the instant the provider emits a `patch`.
///
/// Safety is in the lifecycle (§10.4): spawned on demand, reaped on idle by
/// `ProviderHost`, restarted with backoff on crash, and — because a dead provider
/// simply stops pushing — its state goes *stale, not wedged*. No heartbeat/TTL.
final class ProviderProcess {
    let manifest: WidgetManifest
    let caps: PluginCapabilities
    private let env: [String: String]        // secrets + $config, computed at construction

    // Callbacks (set by the consumer, fired on the main queue):
    var onState: (([String: String]) -> Void)?     // shallow-merged tile state (§10.2 patch)
    var onImage: ((String, Data) -> Void)?          // (field, png) dynamic tile image (§9/§10.2)
    var onOptions: ((String, [String]) -> Void)?    // device-picker feed (§6)
    var onError: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var lineBuffer = Data()
    private var stopped = false              // true ⇒ a deliberate stop, suppress restart
    private var restartDelay: TimeInterval = 0.5   // backoff, doubles to a cap
    private let queue = DispatchQueue(label: "com.gatecaster.provider")

    init?(manifest: WidgetManifest, config: [String: String]) {
        guard manifest.hasProvider else { return nil }
        self.manifest = manifest
        let caps = PluginCapabilities(manifest)
        self.caps = caps
        // Capability gate (§9.3 L4): a provider may spawn only if `process` is
        // declared. Without it we construct nothing — the tile shows an error,
        // not a silently-running child.
        guard caps.canSpawnProvider else { return nil }
        // Env = inherited PATH/etc + secrets (§7) + $config (§10.1). Both slices
        // are namespaced so a child reads `GATECASTER_SECRET_TOKEN` /
        // `GATECASTER_CONFIG_DEVICEID` without parsing argv.
        var e = ProcessInfo.processInfo.environment
        for (k, v) in SecretStore.env(for: manifest) { e[k] = v }
        for (k, v) in config { e["GATECASTER_CONFIG_\(k.uppercased())"] = v }
        self.env = e
    }

    /// Pack directory the provider command/cwd resolves against.
    private var packDir: URL { WidgetRegistry.folder.appendingPathComponent(manifest.id) }

    func start() {
        queue.async { [weak self] in self?.spawn() }
    }

    private func spawn() {
        guard !stopped, let prov = manifest.provider, !prov.command.isEmpty else { return }
        let p = Process()
        // Run through `/bin/zsh -lc` like the refresh poll does, so a command such
        // as "node provider.js" resolves PATH and the user's tool versions. cwd =
        // the pack dir, so relative script paths in the command just work.
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let argv = ([prov.command] + (prov.args ?? [])).joined(separator: " ")
        p.arguments = ["-lc", argv]
        p.currentDirectoryURL = packDir
        p.environment = env

        let outPipe = Pipe(); p.standardOutput = outPipe
        let inPipe = Pipe();  p.standardInput = inPipe
        p.standardError = FileHandle.nullDevice
        stdin = inPipe.fileHandleForWriting

        // NDJSON reader: accumulate bytes, split on \n, decode each complete line.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.ingest(chunk) }
        }

        // Crash recovery (§10.4): on unexpected exit, restart with backoff and
        // surface a stale-state error to the tile. A deliberate stop() sets
        // `stopped` first, so a clean teardown does not trigger a respawn.
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            self.queue.asyncAfter(deadline: .now() + self.restartDelay) {
                guard !self.stopped else { return }
                self.restartDelay = min(self.restartDelay * 2, 30)   // cap backoff at 30s
                self.emitError("provider exited — restarting")
                self.spawn()
            }
        }

        do {
            try p.run()
            process = p
            restartDelay = 0.5    // a clean start resets the backoff ladder
        } catch {
            emitError("provider failed to launch: \(error.localizedDescription)")
        }
    }

    /// Host → provider command (§10.3): write one NDJSON line to the child's stdin.
    /// Used by `then:"refresh"` and by `provider`-kind buttons.
    func send(action: String, params: [String: String] = [:]) {
        queue.async { [weak self] in
            guard let self, let stdin = self.stdin else { return }
            var msg: [String: Any] = ["v": 1, "action": action]
            if !params.isEmpty { msg["params"] = params }
            guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
            try? stdin.write(contentsOf: data + Data([0x0A]))
        }
    }

    func requestRefresh() { send(action: "refresh") }

    /// Deliberate teardown (reap-on-idle, §10.4). Marks `stopped` BEFORE killing so
    /// the termination handler does not respawn, then tears down pipes.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
            try? self.stdin?.close()
            self.stdin = nil
        }
    }

    // Parse accumulated stdout into whole NDJSON lines.
    private func ingest(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return }   // tolerate junk lines (a provider's stray stdout debug print)
        switch type {
        case "hello":
            break   // caps are advisory (§5.5); the host enforces the real ceiling
        case "patch":
            if let state = obj["state"] as? [String: Any] {
                let strings = state.mapValues { "\($0)" }
                main { self.onState?(strings) }
            }
        case "image":
            if let field = obj["field"] as? String,
               let b64 = obj["png"] as? String,
               let data = Data(base64Encoded: b64) {
                main { self.onImage?(field, data) }
            }
        case "options":
            if let key = obj["key"] as? String, let items = obj["items"] as? [Any] {
                main { self.onOptions?(key, items.map { "\($0)" }) }
            }
        case "error":
            emitError(obj["message"] as? String ?? "provider error")
        default:
            break   // unknown type ⇒ ignore (forward-compat, §5)
        }
    }

    private func emitError(_ msg: String) { main { self.onError?(msg) } }
    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
}

// MARK: - Provider host (§10.4) — spawn-on-demand / reap-on-idle, ref-counted

/// Owns the live provider processes and their lifecycle. Keyed by tile *instance*
/// (a deck can hold two copies of one plugin with different config), the host
/// ref-counts consumers: the first visible tile spawns the process, the last one
/// to disappear reaps it — no orphan token-holders, no heartbeat. This is the
/// §10.4 "spawn on demand / reap on idle" contract made concrete.
final class ProviderHost {
    static let shared = ProviderHost()
    private init() {}

    private struct Entry { let process: ProviderProcess; var refcount: Int }
    private var entries: [UUID: Entry] = [:]   // keyed by tile instance id
    private let lock = NSLock()

    /// Acquire (and lazily spawn) the provider for a tile instance, returning it
    /// so the caller can wire callbacks and send commands. Returns nil if the
    /// manifest declares no provider or lacks the `process` capability.
    func acquire(manifest: WidgetManifest, instance: UUID,
                 config: [String: String]) -> ProviderProcess? {
        lock.lock(); defer { lock.unlock() }
        if var e = entries[instance] {
            e.refcount += 1
            entries[instance] = e
            return e.process
        }
        guard let proc = ProviderProcess(manifest: manifest, config: config) else { return nil }
        entries[instance] = Entry(process: proc, refcount: 1)
        proc.start()
        return proc
    }

    /// Release one consumer; when the count hits zero, reap the process.
    func release(instance: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[instance] else { return }
        e.refcount -= 1
        if e.refcount <= 0 {
            e.process.stop()
            entries[instance] = nil
        } else {
            entries[instance] = e
        }
    }
}
