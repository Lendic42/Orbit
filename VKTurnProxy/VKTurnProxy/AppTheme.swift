import SwiftUI

/// Visual system for Orbit — calm, high-contrast, readable at a glance.
enum AppTheme {
    static let accent = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let accentDeep = Color(red: 0.18, green: 0.32, blue: 0.78)
    static let success = Color(red: 0.22, green: 0.82, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.38)
    static let muted = Color.secondary

    static var connectedGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.18, blue: 0.28),
                Color(red: 0.04, green: 0.12, blue: 0.20),
                Color(red: 0.05, green: 0.22, blue: 0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var idleGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.08, blue: 0.14),
                Color(red: 0.05, green: 0.06, blue: 0.12),
                Color(red: 0.09, green: 0.08, blue: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var connectingGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.14, green: 0.12, blue: 0.06),
                Color(red: 0.10, green: 0.08, blue: 0.05),
                Color(red: 0.12, green: 0.10, blue: 0.06)
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
