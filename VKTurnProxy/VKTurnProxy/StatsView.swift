import SwiftUI

struct StatsView: View {
    @ObservedObject var tunnel: TunnelManager

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(
                    title: "Отправка",
                    value: formatBytes(tunnel.stats.txBytes),
                    sub: formatRate(tunnel.txRate),
                    icon: "arrow.up.circle.fill",
                    tint: AppTheme.accent
                )
                StatCard(
                    title: "Приём",
                    value: formatBytes(tunnel.stats.rxBytes),
                    sub: formatRate(tunnel.rxRate),
                    icon: "arrow.down.circle.fill",
                    tint: AppTheme.success
                )
            }

            HStack(spacing: 10) {
                MiniStat(title: "TURN RTT", value: String(format: "%.0f ms", tunnel.stats.turnRTTms))
                MiniStat(title: "DTLS", value: String(format: "%.0f ms", tunnel.stats.dtlsHandshakeMs))
                MiniStat(
                    title: "Интернет",
                    value: tunnel.internetRTTms > 0
                        ? String(format: "%.0f ms", tunnel.internetRTTms)
                        : "—"
                )
            }

            HStack(spacing: 10) {
                MiniStat(title: "Каналы", value: "\(tunnel.stats.activeConns)/\(tunnel.stats.totalConns)")
                MiniStat(title: "Реконнекты", value: "\(tunnel.stats.reconnects)")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    MiniStat(
                        title: "Аптайм",
                        value: formatUptime(tunnel.connectedAt.map { context.date.timeIntervalSince($0) })
                    )
                }
            }

            MiniStat(
                title: "Пул кредов",
                value: "\(tunnel.stats.credPoolFilled)/\(tunnel.stats.credPoolWithCreds)/\(tunnel.stats.credPoolSize) · \(tunnel.stats.credPoolDistinctRelays) relay",
                wide: true
            )
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
        return "\(bytes) B"
    }

    private func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%.1f KB/s", bytesPerSec / 1024) }
        if bytesPerSec > 0 { return String(format: "%.0f B/s", bytesPerSec) }
        return "0 B/s"
    }

    private func formatUptime(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s >= 0 else { return "—" }
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let sub: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.subheadline)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text(sub)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct MiniStat: View {
    let title: String
    let value: String
    var wide: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(wide ? .footnote : .subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
