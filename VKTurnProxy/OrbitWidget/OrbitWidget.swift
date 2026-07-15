import SwiftUI
import WidgetKit

struct OrbitWidgetEntry: TimelineEntry {
    let date: Date
    let status: String
    let detail: String
}

struct OrbitWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> OrbitWidgetEntry {
        OrbitWidgetEntry(date: Date(), status: "Не подключено", detail: "Нажмите для подключения")
    }

    func getSnapshot(in context: Context, completion: @escaping (OrbitWidgetEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OrbitWidgetEntry>) -> Void) {
        let entry = readEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func readEntry() -> OrbitWidgetEntry {
        let defaults = UserDefaults(suiteName: "group.com.vkturnproxy.app")
        let connected = defaults?.bool(forKey: "widgetConnected") ?? false
        let phase = defaults?.string(forKey: "widgetPhase") ?? ""
        return OrbitWidgetEntry(
            date: Date(),
            status: connected ? "Подключено" : "Не подключено",
            detail: phase.isEmpty ? "Orbit · TURN/WireGuard" : phase
        )
    }
}

struct OrbitWidgetEntryView: View {
    let entry: OrbitWidgetEntry

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: entry.status == "Подключено" ? "lock.shield.fill" : "lock.open")
                    .foregroundStyle(entry.status == "Подключено" ? .green : .secondary)
                Text("Orbit")
                    .font(.headline)
                Spacer()
            }
            Text(entry.status)
                .font(.title3.weight(.semibold))
            Text(entry.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Link(destination: URL(string: "vkturnproxy://action/toggle")!) {
                Label(entry.status == "Подключено" ? "Отключить" : "Подключить", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding()
        if #available(iOS 17.0, *) {
            content.containerBackground(.background, for: .widget)
        } else {
            content.background(Color(.systemBackground))
        }
    }
}

@main
struct OrbitWidget: Widget {
    let kind = "OrbitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OrbitWidgetProvider()) { entry in
            OrbitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Orbit")
        .description("Статус и быстрое подключение Orbit.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
