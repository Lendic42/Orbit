import SwiftUI

/// Visual system for Orbit — calm, high-contrast, readable at a glance.
enum AppTheme {
    // Fresh near-black + electric-lime palette. It borrows the calm hierarchy
    // of the supplied reference without copying its branding or exact colors.
    static let accent = Color(red: 0.72, green: 0.94, blue: 0.25)
    static let accentDeep = Color(red: 0.27, green: 0.42, blue: 0.14)
    static let success = Color(red: 0.45, green: 0.90, blue: 0.42)
    static let warning = Color(red: 0.96, green: 0.76, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.38)
    static let muted = Color.secondary
    static let surface = Color(red: 0.055, green: 0.095, blue: 0.068)
    static let surfaceRaised = Color(red: 0.075, green: 0.125, blue: 0.087)

    static var connectedGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.035, green: 0.105, blue: 0.060),
                Color(red: 0.018, green: 0.060, blue: 0.034),
                Color(red: 0.050, green: 0.135, blue: 0.070)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var idleGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.025, green: 0.060, blue: 0.039),
                Color(red: 0.012, green: 0.035, blue: 0.022),
                Color(red: 0.030, green: 0.075, blue: 0.044)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var connectingGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.105, green: 0.115, blue: 0.040),
                Color(red: 0.055, green: 0.070, blue: 0.025),
                Color(red: 0.085, green: 0.105, blue: 0.035)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Server Mode

/// Transport mode selector. Persisted as the existing flag pair (useSrtp / useWrap)
/// plus useWrapA / useWrapS for interop modes — same JSON contract as upstream.
enum ServerMode: Int, CaseIterable, Identifiable {
    case legacy = 0
    case srtp = 1
    case srtpWrap = 2
    case srtpWrapA = 3
    case srtpWrapS = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .legacy: return "Legacy"
        case .srtp: return "SRTP"
        case .srtpWrap: return "SRTP+WRAP"
        case .srtpWrapA: return "SRTP-WRAP-A"
        case .srtpWrapS: return "SRTP-WRAP-S"
        }
    }

    var subtitle: String {
        switch self {
        case .legacy: return "Старый режим · медленно из‑за шейпинга"
        case .srtp: return "Рекомендуется · быстрый и стабильный"
        case .srtpWrap: return "Совместимость с серверами -wrap-srtp"
        case .srtpWrapA: return "WDTT · ключи WireGuard с сервера"
        case .srtpWrapS: return "free-turn-proxy · профиль обфускации"
        }
    }

    var systemImage: String {
        switch self {
        case .legacy: return "clock.arrow.circlepath"
        case .srtp: return "bolt.fill"
        case .srtpWrap: return "lock.shield.fill"
        case .srtpWrapA: return "person.badge.key.fill"
        case .srtpWrapS: return "waveform.path"
        }
    }
}
