// AppConfig.swift
//
// Codable representation of the entire app's persisted state, used by
// BackupManager for the user-facing Export/Import flow in Settings.
//
// Two scopes of "state" the user might want to preserve:
//   1. UserDefaults-backed @AppStorage values (connection params,
//      WireGuard keys, tuning knobs).
//   2. The TURN credential cache the extension writes to the App Group
//      container (creds-pool.json). Including this in the backup means
//      a restore can skip the VK PoW + captcha round on first connect
//      after import — directly relevant when migrating to a fresh install
//      after `xcrun devicectl install` left the previous cache behind.
//
// Schema version is independent of the on-disk creds-pool.json schema —
// they bump for different reasons. This file's `version` increments when
// the AppConfig wrapper itself changes; CredCacheFile's `version` (which
// we embed verbatim) increments when the TURN-cache shape changes. A
// future v2 of AppConfig might wrap a v3 CredCacheFile, etc.
//
// Sensitive content: WireGuard private key, preshared key, and TURN
// credentials are all in plaintext here. The app warns the user before
// share — no encryption in this iteration. Friend-shareable subsets
// (without TURN cache) are a separate "connection link" feature planned
// for a follow-up.

import Foundation
import Network

private final class PeerProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Int?, Never>

    init(_ continuation: CheckedContinuation<Int?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Int?, cancelling connection: NWConnection) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: value)
    }
}

/// Top-level wrapper. `type` is reserved for the future when we add a
/// `connection-only` shareable form alongside `full`.
struct AppConfig: Codable {
    let version: Int
    let type: String
    let exportedAt: Int64
    let settings: AppSettings
    /// Optional because exporters may produce backups before the
    /// extension has ever populated the cache (fresh install with no
    /// prior connect), and importers must tolerate that.
    let turnPool: CredCacheFile?
    /// Captured-from-real-browser PoW solver profile. Optional for the
    /// same reason as turnPool — fresh install + never-solved-captcha
    /// state has nothing to back up. Also Optional so backups exported
    /// before this field shipped still decode (Codable synthesised init
    /// treats absent Optional keys as nil).
    let vkProfile: VKProfileEntry?

    enum CodingKeys: String, CodingKey {
        case version
        case type
        case exportedAt = "exported_at"
        case settings
        case turnPool = "turn_pool"
        case vkProfile = "vk_profile"
    }
}

/// Mirrors every @AppStorage in ContentView.swift / SettingsView. Keep
/// JSON keys identical to the AppStorage keys so a future "edit the
/// backup file in a text editor" workflow has obvious field names.
///
/// Newer fields (added after the v1 schema shipped) are declared
/// Optional so loading an older backup that doesn't contain them
/// still decodes — Codable's synthesised init treats absent Optional
/// keys as nil. The corresponding apply step in BackupManager uses
/// the AppStorage default when nil. Each addition documents which
/// build introduced it for traceability.
struct AppSettings: Codable {
    let privateKey: String
    let peerPublicKey: String
    let presharedKey: String
    let tunnelAddress: String
    let dnsServers: String
    let allowedIPs: String
    let vkLink: String
    let peerAddress: String
    let useDTLS: Bool
    let numConnections: Int
    let credPoolCooldownSeconds: Int
    /// WRAP layer (ChaCha20-XOR ChannelData payload obfuscation, see
    /// vk-turn-proxy-ios commit 1c1edc1 / branch add-client-wrap-layer).
    /// Optional for back-compat with backups exported before WRAP shipped.
    /// NOTE 2026-05-20: WRAP no longer bypasses VK's content classifier
    /// — use useSrtp below instead. WRAP fields retained for backward-
    /// compat with legacy backups.
    let useWrap: Bool?
    /// 64-character hex encoding of the 32-byte WRAP shared key. Must
    /// match the server's -wrap-key. Optional for back-compat.
    let wrapKeyHex: String?
    /// SRTP transport (DTLS+SRTP+RTP framing, see pkg/proxy/srtpwrap
    /// and add-server-srtp-layer server branch, added 2026-05-20 build
    /// 115+). Bypasses VK's per-allocation shape policy. Optional for
    /// back-compat with backups exported before SRTP shipped.
    let useSrtp: Bool?
    /// TURN control-transport: UDP (true) vs TCP (false, default).
    /// Surfaced as a Settings toggle in build 128. TCP-control bypasses
    /// VK's per-cred allocation-rate throttle (introduced 2026-05-18);
    /// UDP-control is the historical default and can be re-enabled if
    /// the user is on a network where TCP-to-relay is blocked or much
    /// slower. Optional for back-compat with backups exported before
    /// this build — nil leaves the AppStorage default (false / TCP).
    let useUDP: Bool?
    /// WRAP-A (amurcanov-compatible 4th transport mode, added 2026-06-03).
    /// Optional for back-compat with backups exported before WRAP-A shipped —
    /// nil leaves the AppStorage default (false). The per-install deviceID is
    /// deliberately NOT backed up (device identity, regenerated on fresh
    /// install so two devices never collide on the server's WG-peer pool).
    let useWrapA: Bool?
    /// WRAP-A shared secret (obfuscation key + GETCONF auth). Optional for
    /// back-compat. Plaintext like the WG private key above.
    let wrapAPassword: String?
    /// turnServerOverride: optional "IP:port" (added 2026-06-08). When set,
    /// fresh VK fetches are forced onto this TURN relay; disk-cached creds keep
    /// their stored address. Optional for back-compat; nil = no override.
    let turnServerOverride: String?
    /// UNDOCUMENTED on-device captcha-test toggle (build 149): when true the
    /// extension skips the captcha-free VK Calls path so the legacy
    /// captchaNotRobot.* solver runs — lets a tester exercise the captcha fix
    /// (the free path is captcha-free, so the solver never runs otherwise).
    /// Optional + default nil so normal backups omit it; a tester adds
    /// `"forceLegacyCaptcha": true` to the backup JSON by hand. No Settings UI.
    /// `var` (not `let`) so the synthesised Decodable actually decodes it — an
    /// immutable property with an initial value is never decoded by Codable.
    var forceLegacyCaptcha: Bool? = nil
    /// VKAuth (non-anonymous cookie cred path) toggle. Round-trips in full
    /// backups so the preference is preserved. The cookies themselves are NEVER
    /// in the backup — they live in the Keychain (VKCookieStore). Optional +
    /// `var` so Codable decodes it (nil-preserve on import). Default nil.
    var vkAuth: Bool? = nil
    // SRTP-WRAP-S (samosvalishe/free-turn-proxy). `var ... = nil` like vkAuth so
    // old backups/links decode and importers don't force the mode when absent.
    var useWrapS: Bool? = nil
    var obfProfile: String? = nil
    var clientID: String? = nil
    /// Energy-saving profile. Optional so older backups remain importable.
    var energySaver: Bool? = nil
    /// Routes Apple Push Notification service traffic through Orbit when true.
    /// Global connection preference; optional for backup compatibility.
    var proxyAPNs: Bool? = nil
}

// MARK: - 1-Click Connection Link
//
// Lightweight payload sibling to AppConfig used for the 1-Click import
// feature. Encoded as base64 inside `vkturnproxy://import?data=…` URLs
// (or raw on the clipboard) so a server admin can hand a fresh device
// the entire deployment definition in one tap.
//
// Deliberately a SEPARATE struct from AppConfig/AppSettings — does NOT
// reuse them — so that:
//   • Connection links don't accidentally leak the TURN credential cache
//     or the captured browser profile (those belong to the device, not
//     the deployment).
//   • Field requirements differ from full backups: dnsServers and
//     numConnections are optional in a link (the receiving device keeps
//     its current value if absent), whereas in a full backup they're
//     always present. credPoolCooldownSeconds is excluded entirely from
//     links — it's an internal tuning knob nobody should override at
//     onboarding time.
//
// Schema version is shared with AppConfig (BackupManager.supportedConfigVersion)
// so a new schema version invalidates BOTH backup files and connection
// links uniformly.

struct ConnectionLink: Codable {
    let version: Int
    /// Always "connection" for link payloads. Distinguishes from
    /// AppConfig's "full" so the parser can early-reject mismatched
    /// inputs (e.g. user accidentally pastes a full-backup base64 here).
    let type: String
    let settings: ConnectionSettings
}

/// Subset of AppSettings that defines a deployment. WG keys + server
/// address + vkLink + WRAP key are all required; per-device tunables
/// (dnsServers, numConnections) are optional.
struct ConnectionSettings: Codable {
    /// privateKey / peerPublicKey / tunnelAddress / allowedIPs made Optional
    /// 2026-06-03 so a WRAP-A link can omit them entirely — amurcanov's server
    /// provisions WireGuard via GETCONF, so a WRAP-A deployment has no client-
    /// chosen WG keys. Nil-preserves-default on import (absent → keep the
    /// device's current value, so switching modes later doesn't lose keys).
    /// Non-WRAP-A links still include them; quick_link.py requires them unless
    /// useWrapA is set.
    let privateKey: String?
    let peerPublicKey: String?
    /// presharedKey made Optional in build 134 — WireGuard PSK is
    /// optional in the protocol (RFC 4193 §5.2: "If a PSK is not
    /// configured, then it is assumed to be all zeros"), so deployments
    /// that don't use one shouldn't be forced to provide a value in the
    /// link payload. Nil-preserves-default on import: absent → keep
    /// whatever the receiving device already had. Older quick_link.py-
    /// generated links that still carry the field continue to apply it
    /// through unchanged. AppSettings.presharedKey (full-backup path)
    /// remains required because currentConfig() always populates it from
    /// UserDefaults.
    let presharedKey: String?
    let tunnelAddress: String?
    let allowedIPs: String?
    let vkLink: String
    let peerAddress: String
    /// useDTLS / useWrap / wrapKeyHex made Optional in build 129. UI
    /// toggles for both are gone (useDTLS removed build 127, useWrap
    /// removed build 115), so admins generating links should typically
    /// omit them and let the importer keep whatever the device already
    /// has — useDTLS defaults to true so the legacy DTLS+WG path stays
    /// the safe fallback; useWrap defaults to false so the importer
    /// doesn't unintentionally turn on WRAP against a non-WRAP server.
    /// Older quick_link.py-generated links that still set these fields
    /// continue to apply them on import — nil semantics is purely an
    /// additive relaxation for new link generators.
    let useDTLS: Bool?
    let useWrap: Bool?
    let wrapKeyHex: String?
    /// SRTP transport (added 2026-05-20). Optional for back-compat with
    /// connection links exported before SRTP shipped — receiving device
    /// keeps its current useSrtp value (default false) if absent.
    let useSrtp: Bool?
    /// TURN control-transport UDP vs TCP (added build 128). Optional
    /// for back-compat — receiving device keeps its current useUDP
    /// value (default false / TCP) if absent in the link payload.
    let useUDP: Bool?
    /// WRAP-A (amurcanov interop) mode + password (added 2026-06-03). This is
    /// the 1-click payload the "how do I reach amurcanov's server from iOS"
    /// askers need: a link of {peerAddress, useWrapA:true, wrapAPassword}
    /// auto-provisions WireGuard via GETCONF — NO WG keys in the link.
    /// Optional for back-compat; nil keeps the device's current value.
    let useWrapA: Bool?
    let wrapAPassword: String?
    /// turnServerOverride: optional "IP:port" TURN-relay override (added
    /// 2026-06-08). nil keeps the device's current value.
    let turnServerOverride: String?
    /// Optional: if absent, the importing device keeps its current
    /// dnsServers value (or the AppStorage default of "1.1.1.1" if
    /// never set). Always set on apply when present.
    let dnsServers: String?
    /// Optional: if absent, the importing device keeps its current
    /// numConnections (default 30). Useful for an admin to ship a
    /// "recommended for this deployment" hint while still letting
    /// users tune later.
    let numConnections: Int?
    // VKAuth (cookie auth) toggle. Optional, nil-preserve. Lets a connection link
    // provision a device for the non-anonymous cookie path; cookies are NEVER in
    // links (device Keychain only), so the device still logs in via WKWebView on
    // first connect. A multiline vkLink above carries the call links. `var ... =
    // nil` (like AppSettings.forceLegacyCaptcha) so Codable decodes it AND the
    // synthesised memberwise init defaults it (existing construction sites — e.g.
    // parseWdttLink — stay unchanged).
    var vkAuth: Bool? = nil
    // SRTP-WRAP-S (samosvalishe/free-turn-proxy). `var ... = nil` like vkAuth so
    // old backups/links decode and importers don't force the mode when absent.
    var useWrapS: Bool? = nil
    var obfProfile: String? = nil
    var clientID: String? = nil
}

// MARK: - qWDTT-compatible local profiles

/// A local profile is deliberately a small UserDefaults snapshot rather than
/// a copy of AppConfig: TURN credentials and the captured browser profile are
/// device state, while a qWDTT profile is a reusable deployment definition.
struct OrbitProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var folder: String
    /// Stable provider link. A subscription may rename a server or reorder its
    /// nodes without turning the imported profiles into unrelated local ones.
    var subscriptionID: String? = nil
    var sourceSubscriptionURL: String? = nil
    var providerNodeID: String? = nil
    var region: String? = nil
    var countryCode: String? = nil
    var order: Int = 0
    var updatedAt: Date
    var strings: [String: String]
    var flags: [String: Bool]
    var numbers: [String: Int]

    var peerAddress: String { strings["peerAddress"] ?? "" }
    var vkLink: String { strings["vkLink"] ?? "" }

    static func capture(name: String, folder: String = "Личные") -> OrbitProfile {
        let d = UserDefaults.standard
        let stringKeys = [
            "privateKey", "peerPublicKey", "presharedKey", "tunnelAddress",
            "dnsServers", "vkLink", "peerAddress", "turnServerOverride",
            "wrapKeyHex", "wrapAPassword", "obfProfile", "clientID"
        ]
        let flagKeys = ["useDTLS", "useWrap", "useSrtp", "useWrapA", "useWrapS", "useUDP", "energySaver", "VKAuth"]
        let numberKeys = ["numConnections", "credPoolCooldownSeconds"]
        return OrbitProfile(
            id: UUID(), name: name, folder: folder, order: Int(Date().timeIntervalSince1970), updatedAt: Date(),
            strings: Dictionary(uniqueKeysWithValues: stringKeys.map { ($0, d.string(forKey: $0) ?? "") }),
            flags: Dictionary(uniqueKeysWithValues: flagKeys.map { ($0, (d.object(forKey: $0) as? Bool) ?? false) }),
            numbers: Dictionary(uniqueKeysWithValues: numberKeys.map { ($0, (d.object(forKey: $0) as? Int) ?? ($0 == "numConnections" ? 30 : 150)) })
        )
    }

    func apply() {
        let d = UserDefaults.standard
        strings.forEach { d.set($0.value, forKey: $0.key) }
        flags.forEach { d.set($0.value, forKey: $0.key) }
        numbers.forEach { d.set($0.value, forKey: $0.key) }
    }
}

struct OrbitSubscription: Codable, Identifiable {
    var id: UUID
    var name: String
    var url: String
    var description: String?
    var trafficUsedMb: Double?
    var trafficLimitMb: Double?
    var subscriptionID: String? = nil
    var status: String? = nil
    var statusMessage: String? = nil
    var expiresAt: Date? = nil
    var trafficUsedBytes: Int64? = nil
    var trafficLimitBytes: Int64? = nil
    var trafficResetAt: Date? = nil
    var maxDevices: Int? = nil
    var serverCount: Int? = nil
    var updatedAt: Date
}

enum OrbitProfileStore {
    private static let key = "orbitProfiles.v1"
    private static let subscriptionsKey = "orbitSubscriptions.v1"

    static func load() -> [OrbitProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profiles = try? JSONDecoder().decode([OrbitProfile].self, from: data) else { return [] }
        return profiles.sorted {
            if $0.folder != $1.folder { return $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func save(_ profiles: [OrbitProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func loadSubscriptions() -> [OrbitSubscription] {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsKey),
              let subscriptions = try? JSONDecoder().decode([OrbitSubscription].self, from: data) else { return [] }
        return subscriptions
    }

    static func saveSubscriptions(_ subscriptions: [OrbitSubscription]) {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        UserDefaults.standard.set(data, forKey: subscriptionsKey)
    }

    static func upsertSubscription(_ subscription: OrbitSubscription, into subscriptions: inout [OrbitSubscription]) {
        var subscription = subscription
        if let index = subscriptions.firstIndex(where: { $0.url == subscription.url }) {
            // Keep the local identity stable so views, selection state and
            // future provider-specific settings survive a refresh.
            subscription.id = subscriptions[index].id
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
        saveSubscriptions(subscriptions)
    }

    static func upsert(_ profile: OrbitProfile, into profiles: inout [OrbitProfile]) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save(profiles)
    }

    static func delete(at offsets: IndexSet, from profiles: inout [OrbitProfile]) {
        for index in offsets.sorted(by: >) {
            profiles.remove(at: index)
        }
        save(profiles)
    }

    static func move(from offsets: IndexSet, to destination: Int, in profiles: inout [OrbitProfile]) {
        profiles.move(fromOffsets: offsets, toOffset: destination)
        for index in profiles.indices { profiles[index].order = index }
        save(profiles)
    }

    /// Measures TCP connection setup to the configured peer. qWDTT peers are
    /// usually UDP-only, so this is explicitly a port reachability probe, not
    /// a fake ICMP ping. A future server health endpoint can replace it.
    static func probePeer(_ peer: String) async -> Int? {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":"),
              let port = UInt16(trimmed[trimmed.index(after: colon)...]),
              !trimmed[..<colon].isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let host = String(trimmed[..<colon])
        let started = Date()
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let completion = PeerProbeCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(max(0, Int(Date().timeIntervalSince(started) * 1000)), cancelling: connection)
                case .failed, .cancelled:
                    completion.finish(nil, cancelling: connection)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                completion.finish(nil, cancelling: connection)
            }
        }
    }

    static func importQWDTT(data: Data, name fallbackName: String = "Импортированный qWDTT") throws -> OrbitProfile {
        let objectData: Data
        if let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] {
            objectData = data
        } else if let decoded = Data(base64Encoded: data, options: [.ignoreUnknownCharacters]) {
            objectData = decoded
        } else {
            throw ProfileError.invalidFormat
        }
        guard let object = try JSONSerialization.jsonObject(with: objectData) as? [String: Any] else {
            throw ProfileError.invalidFormat
        }
        return try importQWDTT(object: object, name: fallbackName)
    }

    /// Imports the share format used by qWDTT Android clients. URL query
    /// parameters arrive as strings, while downloaded JSON may contain actual
    /// numbers, so both representations are deliberately accepted here.
    static func importQWDTT(raw rawValue: String, name fallbackName: String = "Импортированный qWDTT") throws -> OrbitProfile {
        let wrappers = CharacterSet(charactersIn: "`<>\"'")
        let raw = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: wrappers)
        guard raw.lowercased().hasPrefix("qwdtt:") else { throw ProfileError.invalidFormat }

        // Some generators omit the two slashes after the scheme. URLComponents
        // accepts both forms after normalisation, while preserving every query
        // parameter exactly as a string.
        let normalized: String
        if raw.lowercased().hasPrefix("qwdtt://") {
            normalized = raw
        } else {
            normalized = "qwdtt://" + String(raw.dropFirst("qwdtt:".count))
        }
        guard let components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "qwdtt" else {
            throw ProfileError.invalidFormat
        }
        var object: [String: Any] = [:]
        for item in components.queryItems ?? [] {
            object[item.name] = item.value ?? ""
        }
        return try importQWDTT(object: object, name: fallbackName)
    }

    private static func importQWDTT(object: [String: Any], name fallbackName: String) throws -> OrbitProfile {
        let name = stringValue(in: object, keys: ["name"])
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? fallbackName
        let rawPeer = stringValue(in: object, keys: ["peer", "server", "host"]) ?? ""
        let hashes = stringValue(in: object, keys: ["hashes", "vkHashes", "hash"]) ?? ""
        let password = stringValue(in: object, keys: ["password", "pass"]) ?? ""
        let serverPort = intValue(in: object, keys: ["dtls_port", "server_port", "dtlsPort", "serverPort"])
            .flatMap { (1...65535).contains($0) ? $0 : nil }
            ?? 56_000
        let peer = normalizedPeerAddress(rawPeer, defaultPort: serverPort)
        guard !peer.isEmpty, !hashes.isEmpty, !password.isEmpty else { throw ProfileError.missingFields }
        var profile = OrbitProfile.capture(name: name)
        profile.strings["peerAddress"] = peer
        profile.strings["vkLink"] = hashes
        profile.strings["wrapAPassword"] = password
        profile.flags["useWrapA"] = true
        profile.flags["useSrtp"] = false
        if let workers = intValue(in: object, keys: ["workers", "workersPerHash"]) {
            profile.numbers["numConnections"] = max(1, min(workers, 50))
        }
        return profile
    }

    /// qWDTT's `port` query item is the local UDP listener (usually 9000), not
    /// the remote TURN/DTLS port. The latter is carried by peer or optionally
    /// by `dtls_port` / `server_port`; default it to the WDTT server standard.
    private static func normalizedPeerAddress(_ rawValue: String, defaultPort: Int) -> String {
        let peer = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { return "" }

        if peer.hasPrefix("[") {
            guard let closing = peer.firstIndex(of: "]") else { return peer }
            let suffix = peer[peer.index(after: closing)...]
            if suffix.isEmpty { return "\(peer):\(defaultPort)" }
            if suffix.hasPrefix(":"),
               let port = Int(suffix.dropFirst()),
               (1...65535).contains(port) {
                return peer
            }
            return peer
        }

        let colonCount = peer.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 0 {
            return "\(peer):\(defaultPort)"
        }
        if colonCount == 1,
           let colon = peer.lastIndex(of: ":"),
           let port = Int(peer[peer.index(after: colon)...]),
           (1...65535).contains(port),
           !peer[..<colon].isEmpty {
            return peer
        }

        // More than one colon is an unbracketed IPv6 literal. Bracket it so
        // ConfigValidation and Network.framework can treat the appended port
        // unambiguously. A malformed host:port is intentionally left visible
        // to the normal configuration validation instead of being guessed.
        if colonCount > 1 {
            return "[\(peer)]:\(defaultPort)"
        }
        return peer
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = object[key] as? String { return string }
            if let number = object[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func intValue(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let number = object[key] as? NSNumber { return number.intValue }
            if let string = object[key] as? String,
               let value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    static func qwdttData(for profile: OrbitProfile) throws -> Data {
        let object: [String: Any] = [
            "name": profile.name,
            "peer": profile.peerAddress,
            "hashes": profile.vkLink,
            "workers": profile.numbers["numConnections"] ?? 16,
            "password": profile.strings["wrapAPassword"] ?? ""
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Accepts the HTTPS link emitted by the bot and transparently migrates
    /// links from the first HTTP-only deployment. Trimming Telegram's backticks
    /// here avoids a surprisingly common "invalid URL" onboarding failure.
    static func normalizedSubscriptionURL(from rawValue: String) throws -> URL {
        let wrapperCharacters = CharacterSet(charactersIn: "`<>\"'")
        let raw = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: wrapperCharacters)
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ProfileError.invalidSubscriptionURL
        }

        // Bot links issued before build 216 pointed directly to the VPS over
        // HTTP, which iOS App Transport Security correctly rejects. Preserve
        // those already-sent links by moving only our known endpoint to the
        // certificate-backed nginx route.
        if scheme == "http", host == "2.27.23.176",
           components.path.hasPrefix("/api/subscription/") {
            let fileName = URL(fileURLWithPath: components.path).lastPathComponent
            guard !fileName.isEmpty,
                  let migrated = URL(string: "https://lendicsq.duckdns.org/wdtt/subscription/\(fileName)") else {
                throw ProfileError.invalidSubscriptionURL
            }
            return migrated
        }

        // The domain already redirects HTTP to HTTPS in nginx. Upgrade before
        // URLSession so the app never relies on an ATS-sensitive redirect.
        if scheme == "http", host == "lendicsq.duckdns.org" {
            components.scheme = "https"
            components.port = nil
        }

        guard components.scheme?.lowercased() == "https",
              let url = components.url else {
            throw ProfileError.insecureSubscriptionURL
        }
        return url
    }

    static func importSubscription(from url: URL) async throws -> (OrbitSubscription, [OrbitProfile]) {
        let resolvedURL = try normalizedSubscriptionURL(from: url.absoluteString)
        var request = URLRequest(url: resolvedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProfileError.subscriptionHTTP(http.statusCode)
        }
        let root: [String: Any]
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        } else {
            guard let decoded = Data(base64Encoded: data, options: [.ignoreUnknownCharacters]),
                  let decodedRoot = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
                throw ProfileError.invalidFormat
            }
            root = decodedRoot
        }
        let name = (root["subscriptionName"] as? String)
            ?? (root["groupName"] as? String)
            ?? resolvedURL.host
            ?? "Подписка"
        let rawProfiles = (root["profiles"] as? [[String: Any]])
            ?? (root["servers"] as? [[String: Any]])
            ?? []
        guard !rawProfiles.isEmpty else { throw ProfileError.missingProfiles }
        let advertisedProviderID = (root["subscriptionId"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = advertisedProviderID.isEmpty ? resolvedURL.absoluteString : advertisedProviderID

        func unixDate(_ value: Any?) -> Date? {
            if let number = value as? NSNumber, number.doubleValue > 0 {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            if let string = value as? String {
                if let unix = Double(string), unix > 0 {
                    return Date(timeIntervalSince1970: unix)
                }
                return ISO8601DateFormatter().date(from: string)
            }
            return nil
        }

        let trafficUsedBytes = (root["trafficUsedBytes"] as? NSNumber)?.int64Value
        let trafficLimitBytes = (root["trafficLimitBytes"] as? NSNumber)?.int64Value
        var profiles: [OrbitProfile] = []
        for raw in rawProfiles {
            let profileData = try JSONSerialization.data(withJSONObject: raw)
            var profile = try importQWDTT(data: profileData, name: (raw["name"] as? String) ?? name)
            profile.folder = name
            profile.subscriptionID = providerID
            profile.sourceSubscriptionURL = resolvedURL.absoluteString
            profile.providerNodeID = raw["id"] as? String
            profile.region = raw["region"] as? String
            profile.countryCode = raw["countryCode"] as? String
            profiles.append(profile)
        }
        let subscription = OrbitSubscription(
            id: UUID(), name: name, url: resolvedURL.absoluteString,
            description: root["description"] as? String,
            trafficUsedMb: (root["trafficUsedMb"] as? NSNumber)?.doubleValue,
            trafficLimitMb: (root["trafficLimitMb"] as? NSNumber)?.doubleValue,
            subscriptionID: providerID,
            status: root["status"] as? String,
            statusMessage: root["statusMessage"] as? String,
            expiresAt: unixDate(root["expiresAt"]),
            trafficUsedBytes: trafficUsedBytes,
            trafficLimitBytes: trafficLimitBytes,
            trafficResetAt: unixDate(root["trafficResetAt"]),
            maxDevices: (root["maxDevices"] as? NSNumber)?.intValue,
            serverCount: (root["serverCount"] as? NSNumber)?.intValue,
            updatedAt: Date()
        )
        return (subscription, profiles)
    }

    static func importQWDTT(url: URL) throws -> OrbitProfile {
        return try importQWDTT(raw: url.absoluteString)
    }
}

enum ProfileError: LocalizedError {
    case invalidFormat
    case missingFields
    case invalidSubscriptionURL
    case insecureSubscriptionURL
    case subscriptionHTTP(Int)
    case missingProfiles

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Файл не похож на qWDTT JSON или Base64-JSON."
        case .missingFields: return "В профиле нужны peer, hashes и password."
        case .invalidSubscriptionURL: return "Не удалось распознать адрес подписки. Скопируйте ссылку целиком."
        case .insecureSubscriptionURL: return "Подписка должна использовать HTTPS. Получите новую ссылку в Telegram-боте."
        case .subscriptionHTTP(let code): return "Сервер подписки вернул HTTP \(code)."
        case .missingProfiles: return "В подписке не найден массив profiles или servers."
        }
    }
}
