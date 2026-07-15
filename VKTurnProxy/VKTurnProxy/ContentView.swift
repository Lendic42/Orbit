import SwiftUI
import UIKit
import NetworkExtension
import WebKit
import UniformTypeIdentifiers
import os.log

extension Notification.Name {
    static let orbitProfilesDidChange = Notification.Name("orbitProfilesDidChange")
}

// MARK: - Root navigation

/// qWDTT-style top-level navigation. TunnelManager lives here so switching
/// tabs never creates a second VPN controller or loses the active session.
struct OrbitRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tunnel = TunnelManager()
    @StateObject private var inbox = ConnectionLinkInbox.shared
    @State private var selectedTab = 0
    @State private var refreshingSubscriptions = false
    @AppStorage("orbitSubscriptionsLastAutoRefresh") private var lastSubscriptionRefresh: Double = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(tunnel: tunnel, onOpenServers: { selectedTab = 1 })
                .tabItem { Label("Подключение", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(0)

            ProfileLibraryView(onActivate: { selectedTab = 0 })
                .tabItem { Label("Серверы", systemImage: "server.rack") }
                .tag(1)

            NavigationView { SettingsView() }
                .tabItem { Label("Настройки", systemImage: "slider.horizontal.3") }
                .tag(2)

        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: inbox.pendingURL) { url in
            if url != nil { selectedTab = 0 }
        }
        .onChange(of: inbox.pendingAction) { action in
            if action != nil { selectedTab = 0 }
        }
        .task { await refreshSubscriptionsIfNeeded() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await refreshSubscriptionsIfNeeded() }
            }
        }
    }

    /// Refresh saved subscriptions on launch/foreground at most once per
    /// hour. There is deliberately no background timer: iOS can suspend the
    /// app freely and Orbit consumes no battery while its UI is closed.
    private func refreshSubscriptionsIfNeeded() async {
        guard !refreshingSubscriptions else { return }
        let subscriptions = OrbitProfileStore.loadSubscriptions()
        guard !subscriptions.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastSubscriptionRefresh >= 3600 else { return }
        refreshingSubscriptions = true
        defer {
            refreshingSubscriptions = false
            lastSubscriptionRefresh = now
        }

        var profiles = OrbitProfileStore.load()
        var refreshedSubscriptions = subscriptions
        var changed = false
        for subscription in subscriptions {
            guard let url = URL(string: subscription.url) else { continue }
            do {
                let (updated, imported) = try await OrbitProfileStore.importSubscription(from: url)
                let providerID = subscription.subscriptionID ?? subscription.url
                profiles.removeAll {
                    $0.subscriptionID == providerID
                        || $0.sourceSubscriptionURL == subscription.url
                        || ($0.subscriptionID == nil && $0.folder == subscription.name)
                }
                imported.forEach { OrbitProfileStore.upsert($0, into: &profiles) }
                OrbitProfileStore.upsertSubscription(updated, into: &refreshedSubscriptions)
                changed = true
            } catch {
                SharedLogger.shared.log("[Subscription] auto-refresh failed for \(subscription.name): \(error.localizedDescription)")
            }
        }
        if changed {
            OrbitProfileStore.save(profiles)
            NotificationCenter.default.post(name: .orbitProfilesDidChange, object: nil)
        }
    }
}

// MARK: - Profile library

struct ProfileLibraryView: View {
    var onActivate: () -> Void = {}
    @State private var profiles: [OrbitProfile] = OrbitProfileStore.load()
    @State private var showSaveDialog = false
    @State private var profileName = ""
    @State private var profileFolder = "Личные"
    @State private var showFileImporter = false
    @State private var showQRScanner = false
    @State private var exportURL: IdentifiableURL?
    @State private var alertTitle = ""
    @State private var alertMessage: String?
    @State private var probingProfile: UUID?
    @State private var probeResults: [UUID: Int] = [:]
    @State private var selectedProviderID: String?
    @AppStorage("orbitSubscriptionURL") private var subscriptionURL = ""
    @AppStorage("activeProfileName") private var activeProfileName = ""
    @AppStorage("activeProfileID") private var activeProfileID = ""
    @State private var subscriptionLoading = false

    private var subscriptions: [OrbitSubscription] {
        OrbitProfileStore.loadSubscriptions().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var visibleProfiles: [OrbitProfile] {
        guard let selectedProviderID else { return profiles }
        return profiles.filter { profile in
            profile.subscriptionID == selectedProviderID
                || (profile.subscriptionID == nil && profile.folder == selectedProviderID)
        }
    }

    private var folders: [String] {
        Array(Set(visibleProfiles.map { $0.folder.isEmpty ? "Без папки" : $0.folder }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            List {
                if !subscriptions.isEmpty {
                    Section {
                        Button {
                            selectedProviderID = nil
                        } label: {
                            HStack {
                                Label("Все подключения", systemImage: selectedProviderID == nil ? "checkmark.circle.fill" : "circle")
                                Spacer()
                                Text("\(profiles.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        ForEach(subscriptions) { subscription in
                            subscriptionCard(subscription)
                        }
                    } header: {
                        Text("Мои подписки")
                    } footer: {
                        Text("Подписка — это провайдер: один URL может обновлять несколько региональных серверов, срок и лимит трафика.")
                    }
                }

                Section {
                    Button {
                        profileName = "Профиль \(profiles.count + 1)"
                        profileFolder = "Личные"
                        showSaveDialog = true
                    } label: {
                        Label("Сохранить текущую конфигурацию", systemImage: "plus.circle.fill")
                    }

                    Button { importClipboard(scheme: "wdtt") } label: {
                        Label("Импортировать ссылку wdtt://", systemImage: "link.badge.plus")
                    }

                    Button { importClipboard(scheme: "qwdtt") } label: {
                        Label("Импортировать ссылку qwdtt://", systemImage: "square.and.arrow.down")
                    }

                    Button { showFileImporter = true } label: {
                        Label("Импортировать qWDTT JSON", systemImage: "doc.badge.plus")
                    }

                    Button { showQRScanner = true } label: {
                        Label("Сканировать QR-код", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("Добавление")
                } footer: {
                    Text("wdtt:// применяет параметры сразу. qwdtt:// и JSON добавляют отдельный профиль.")
                }

                Section {
                    TextField("https://сервер/подписка.json", text: $subscriptionURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Button {
                        Task { await refreshSubscription() }
                    } label: {
                        Label(subscriptionLoading ? "Загрузка…" : "Обновить подписку", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(subscriptionLoading || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Подписка")
                }

                if profiles.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up.slash")
                                .font(.system(size: 38))
                                .foregroundStyle(.secondary)
                            Text("Профилей пока нет")
                                .font(.headline)
                            Text("Импортируйте ссылку из Telegram-бота или сохраните текущие настройки.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    ForEach(folders, id: \.self) { folder in
                        Section(folder) {
                            ForEach(profiles(in: folder)) { profile in
                                profileRow(profile)
                            }
                            .onDelete { offsets in delete(offsets, in: folder) }
                        }
                    }
                }
            }
            .navigationTitle("Серверы")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { EditButton() }
            .onAppear { profiles = OrbitProfileStore.load() }
            .onReceive(NotificationCenter.default.publisher(for: .orbitProfilesDidChange)) { _ in
                profiles = OrbitProfileStore.load()
            }
            .alert("Сохранить профиль", isPresented: $showSaveDialog) {
                TextField("Название", text: $profileName)
                TextField("Папка", text: $profileFolder)
                Button("Сохранить", action: saveCurrentProfile)
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будут сохранены текущие параметры подключения без временного TURN-кэша.")
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(item: $exportURL) { item in ShareSheet(activityItems: [item.url]) }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .data, .item]) { result in
                importFile(result)
            }
            .sheet(isPresented: $showQRScanner) {
                NavigationView {
                    QRCodeScannerView(
                        onResult: { raw in
                            showQRScanner = false
                            importScannedCode(raw)
                        },
                        onError: { message in
                            showQRScanner = false
                            show(message: message, title: "Сканер недоступен")
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Сканирование QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { showQRScanner = false }
                        }
                    }
                }
            }
        }
    }

    private func subscriptionCard(_ subscription: OrbitSubscription) -> some View {
        let providerID = subscription.subscriptionID ?? subscription.url
        let selected = selectedProviderID == providerID
        return Button {
            selectedProviderID = selected ? nil : providerID
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "server.rack")
                        .foregroundStyle(selected ? AppTheme.accent : .secondary)
                    Text(subscription.name).font(.headline)
                    Spacer()
                    Text(subscriptionStatusText(subscription))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(subscriptionStatusColor(subscription))
                }
                HStack(spacing: 12) {
                    Label("\(subscription.serverCount ?? profiles.filter { $0.subscriptionID == providerID }.count) серверов", systemImage: "square.stack.3d.up")
                    if let expiresAt = subscription.expiresAt {
                        Label(subscriptionExpiryText(expiresAt), systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let limit = subscription.trafficLimitBytes, limit > 0 {
                    let used = subscription.trafficUsedBytes ?? 0
                    ProgressView(value: min(Double(used), Double(limit)), total: Double(limit))
                        .tint(subscription.status == "quota_exceeded" ? AppTheme.danger : AppTheme.accent)
                    Text("Трафик: \(formatBytes(used)) из \(formatBytes(limit))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Трафик без ограничения")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(subscription.statusMessage ?? "Обновлено \(subscription.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button(role: .destructive) {
                            removeSubscription(subscription)
                        } label: {
                            Label("Удалить подписку", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func subscriptionStatusText(_ subscription: OrbitSubscription) -> String {
        switch subscription.status {
        case "expired": return "Истекла"
        case "quota_exceeded": return "Лимит исчерпан"
        case "disabled": return "Отключена"
        default: return "Активна"
        }
    }

    private func subscriptionStatusColor(_ subscription: OrbitSubscription) -> Color {
        switch subscription.status {
        case "expired", "quota_exceeded", "disabled": return AppTheme.danger
        default: return AppTheme.success
        }
    }

    private func subscriptionExpiryText(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 0 { return "Срок истёк" }
        if days == 0 { return "Истекает сегодня" }
        return "Осталось \(days) дн."
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func removeSubscription(_ subscription: OrbitSubscription) {
        let providerID = subscription.subscriptionID ?? subscription.url
        var stored = OrbitProfileStore.loadSubscriptions()
        stored.removeAll { $0.url == subscription.url }
        OrbitProfileStore.saveSubscriptions(stored)
        profiles.removeAll {
            $0.subscriptionID == providerID || $0.sourceSubscriptionURL == subscription.url
        }
        OrbitProfileStore.save(profiles)
        if selectedProviderID == providerID { selectedProviderID = nil }
    }

    private func profileRow(_ profile: OrbitProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.headline)
                    Text(profile.peerAddress.isEmpty ? "Сервер не указан" : profile.peerAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let latency = probeResults[profile.id] {
                    Text("\(latency) мс")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.success)
                }
            }

            HStack(spacing: 10) {
                Button("Подключить") { activate(profile) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button {
                    Task { await probe(profile) }
                } label: {
                    Label(probingProfile == profile.id ? "Проверка" : "Проверить", systemImage: "gauge.with.dots.needle.33percent")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(probingProfile != nil)

                Menu {
                    Button { export(profile) } label: { Label("Экспорт JSON", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { delete(profile) } label: { Label("Удалить", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
    }

    private func saveCurrentProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = profileFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = OrbitProfile.capture(name: name.isEmpty ? "Профиль \(profiles.count + 1)" : name,
                                           folder: folder.isEmpty ? "Личные" : folder)
        OrbitProfileStore.upsert(profile, into: &profiles)
        profiles = OrbitProfileStore.load()
        show(message: "Профиль «\(profile.name)» сохранён.", title: "Готово")
    }

    private func profiles(in folder: String) -> [OrbitProfile] {
        visibleProfiles.filter { profile in
            let profileFolder = profile.folder.isEmpty ? "Без папки" : profile.folder
            return profileFolder == folder
        }
    }

    private func importClipboard(scheme: String) {
        let raw = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("\(scheme):") else {
            show(message: "Скопируйте ссылку \(scheme):// в буфер обмена.", title: "Неверная ссылка")
            return
        }
        do {
            if scheme == "qwdtt" {
                let profile = try OrbitProfileStore.importQWDTT(raw: raw)
                OrbitProfileStore.upsert(profile, into: &profiles)
                profiles = OrbitProfileStore.load()
                show(message: "Профиль «\(profile.name)» добавлен.", title: "qWDTT импортирован")
            } else {
                let link = try BackupManager.parseConnectionLinkString(raw)
                BackupManager.applyConnectionLink(link)
                show(message: "Параметры wdtt:// применены. Вернитесь в «Туннель» и подключитесь.", title: "WDTT импортирован")
            }
        } catch {
            show(message: error.localizedDescription, title: "Ошибка импорта")
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let profile = try OrbitProfileStore.importQWDTT(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
            OrbitProfileStore.upsert(profile, into: &profiles)
            profiles = OrbitProfileStore.load()
            show(message: "Профиль «\(profile.name)» добавлен.", title: "qWDTT импортирован")
        } catch {
            show(message: error.localizedDescription, title: "Ошибка файла")
        }
    }

    private func importScannedCode(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.lowercased().hasPrefix("qwdtt:") {
                let profile = try OrbitProfileStore.importQWDTT(raw: trimmed)
                OrbitProfileStore.upsert(profile, into: &profiles)
                profiles = OrbitProfileStore.load()
                show(message: "Профиль «\(profile.name)» добавлен.", title: "QR импортирован")
            } else if trimmed.lowercased().hasPrefix("wdtt://") {
                BackupManager.applyConnectionLink(try BackupManager.parseConnectionLinkString(trimmed))
                show(message: "Параметры wdtt:// применены.", title: "QR импортирован")
            } else {
                let profile = try OrbitProfileStore.importQWDTT(data: Data(trimmed.utf8), name: "Профиль из QR")
                OrbitProfileStore.upsert(profile, into: &profiles)
                profiles = OrbitProfileStore.load()
                show(message: "Профиль «\(profile.name)» добавлен.", title: "QR импортирован")
            }
        } catch {
            show(message: error.localizedDescription, title: "Неверный QR-код")
        }
    }

    private func refreshSubscription() async {
        subscriptionLoading = true
        defer { subscriptionLoading = false }
        do {
            let url = try OrbitProfileStore.normalizedSubscriptionURL(from: subscriptionURL)
            let (subscription, imported) = try await OrbitProfileStore.importSubscription(from: url)
            let providerID = subscription.subscriptionID ?? subscription.url
            profiles.removeAll {
                $0.subscriptionID == providerID
                    || $0.sourceSubscriptionURL == subscription.url
                    || ($0.subscriptionID == nil && $0.folder == subscription.name)
            }
            imported.forEach { OrbitProfileStore.upsert($0, into: &profiles) }
            var subscriptions = OrbitProfileStore.loadSubscriptions()
            OrbitProfileStore.upsertSubscription(subscription, into: &subscriptions)
            profiles = OrbitProfileStore.load()
            show(message: "Загружено профилей: \(imported.count).", title: subscription.name)
        } catch {
            show(message: error.localizedDescription, title: "Ошибка подписки")
        }
    }

    private func activate(_ profile: OrbitProfile) {
        guard !profile.peerAddress.isEmpty, !profile.vkLink.isEmpty else {
            show(message: "В профиле не хватает сервера или VK-ссылки.", title: "Профиль неполный")
            return
        }
        profile.apply()
        activeProfileName = profile.name
        activeProfileID = profile.id.uuidString
        onActivate()
    }

    private func probe(_ profile: OrbitProfile) async {
        probingProfile = profile.id
        defer { probingProfile = nil }
        if let latency = await OrbitProfileStore.probePeer(profile.peerAddress) {
            probeResults[profile.id] = latency
        } else {
            show(message: "TCP-порт \(profile.peerAddress) недоступен. Для UDP-only серверов это не всегда означает неисправность.", title: "Нет ответа")
        }
    }

    private func export(_ profile: OrbitProfile) {
        do {
            let safeName = profile.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName).appendingPathExtension("qwdtt")
            try OrbitProfileStore.qwdttData(for: profile).write(to: url, options: .atomic)
            exportURL = IdentifiableURL(url: url)
        } catch {
            show(message: error.localizedDescription, title: "Ошибка экспорта")
        }
    }

    private func delete(_ profile: OrbitProfile) {
        profiles.removeAll { $0.id == profile.id }
        OrbitProfileStore.save(profiles)
    }

    private func delete(_ offsets: IndexSet, in folder: String) {
        let visible = profiles.filter { ($0.folder.isEmpty ? "Без папки" : $0.folder) == folder }
        let ids = Set(offsets.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
        profiles.removeAll { ids.contains($0.id) }
        OrbitProfileStore.save(profiles)
    }

    private func show(message: String, title: String) {
        alertTitle = title
        alertMessage = message
    }
}

struct ContentView: View {
    @ObservedObject var tunnel: TunnelManager
    var onOpenServers: () -> Void = {}
    @StateObject private var actionInbox = ConnectionLinkInbox.shared

    @AppStorage("privateKey") private var privateKey = ""
    @AppStorage("peerPublicKey") private var peerPublicKey = ""
    @AppStorage("presharedKey") private var presharedKey = ""
    @AppStorage("tunnelAddress") private var tunnelAddress = "192.168.102.3/24"
    @AppStorage("dnsServers") private var dnsServers = "1.1.1.1"
    @AppStorage("vkLink") private var vkLink = ""
    @AppStorage("peerAddress") private var peerAddress = ""
    @AppStorage("turnServerOverride") private var turnServerOverride = ""
    @AppStorage("useDTLS") private var useDTLS = true
    @AppStorage("useWrap") private var useWrap = false
    @AppStorage("wrapKeyHex") private var wrapKeyHex = ""
    @AppStorage("useSrtp") private var useSrtp = true
    @AppStorage("useWrapA") private var useWrapA = false
    @AppStorage("wrapAPassword") private var wrapAPassword = ""
    @AppStorage("useWrapS") private var useWrapS = false
    @AppStorage("obfProfile") private var obfProfile = "rtpopus"
    @AppStorage("clientID") private var clientID = ""
    @AppStorage("useUDP") private var useUDP = false
    @AppStorage("numConnections") private var numConnections = 30
    @AppStorage("credPoolCooldownSeconds") private var credPoolCooldownSeconds = 150
    @AppStorage("energySaver") private var energySaver = true
    @AppStorage("activeProfileName") private var activeProfileName = ""
    @AppStorage("activeProfileID") private var activeProfileID = ""
    @AppStorage("proxyAPNs") private var proxyAPNs = false

    @State private var showQuickQRScanner = false
    @State private var quickImportBusy = false
    @State private var importAlertTitle = "Ошибка импорта"
    @State private var importAlertMessage: String?
    @State private var noticeText: String?
    @State private var apnsReconnecting = false
    @State private var profileStoreRevision = 0
    @State private var providerLatencies: [UUID: Int] = [:]
    @State private var providerProbeInProgress = false

    private enum QuickImportKind {
        case subscription
        case qwdtt
        case wdtt
    }

    private let quickActionColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var configValidationError: String? {
        var issues: [ConfigValidation.Issue?] = [
            ConfigValidation.vkLink(vkLink),
            ConfigValidation.peerAddress(peerAddress),
            ConfigValidation.turnOverride(turnServerOverride),
        ]
        if useWrapA {
            issues.append(ConfigValidation.wrapAPassword(wrapAPassword))
        } else {
            issues.append(ConfigValidation.wgKey(privateKey, label: "Приватный ключ", required: true))
            issues.append(ConfigValidation.wgKey(peerPublicKey, label: "Публичный ключ сервера", required: true))
            issues.append(ConfigValidation.wgKey(presharedKey, label: "Предварительный общий ключ", required: false))
            issues.append(ConfigValidation.tunnelAddress(tunnelAddress))
            if (!useSrtp && useWrap) || useWrapS {
                issues.append(ConfigValidation.wrapKeyHex(wrapKeyHex))
            }
        }
        return issues.compactMap { $0 }.first { $0.severity == .error }?.message
    }

    private var isActive: Bool {
        tunnel.preBootstrapInProgress
            || tunnel.status == .connected
            || tunnel.status == .connecting
            || tunnel.status == .reasserting
    }

    private var isBusy: Bool {
        tunnel.preBootstrapInProgress
            || tunnel.status == .connecting
            || tunnel.status == .reasserting
            || tunnel.status == .disconnecting
    }

    private var statusColor: Color {
        if tunnel.preBootstrapInProgress { return AppTheme.warning }
        switch tunnel.status {
        case .connected: return AppTheme.success
        case .connecting, .reasserting, .disconnecting: return AppTheme.warning
        default: return Color.white.opacity(0.42)
        }
    }

    private var statusTitle: String {
        if tunnel.preBootstrapInProgress { return "Подготовка…" }
        switch tunnel.status {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        case .disconnected: return "Нажмите, чтобы подключиться"
        case .invalid: return "Ошибка конфигурации"
        @unknown default: return "Состояние неизвестно"
        }
    }

    private var statusSubtitle: String {
        if let error = tunnel.errorMessage, !error.isEmpty { return error }
        if !tunnel.connectPhase.isEmpty { return tunnel.connectPhase }
        if !isActive, let error = configValidationError { return error }
        if tunnel.status == .connected { return "\(currentModeLabel) · весь трафик защищён" }
        return peerAddress.isEmpty
            ? "Импортируйте подключение ниже — Orbit всё настроит сам"
            : "Сервер готов к подключению"
    }

    private var currentModeLabel: String {
        if useWrapS { return ServerMode.srtpWrapS.label }
        if useWrapA { return ServerMode.srtpWrapA.label }
        if useSrtp { return ServerMode.srtp.label }
        if useWrap { return ServerMode.srtpWrap.label }
        return ServerMode.legacy.label
    }

    private var displayServerName: String {
        if !activeProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return activeProfileName
        }
        return peerAddress.isEmpty ? "Сервер не выбран" : "Текущая конфигурация"
    }

    private var storedProfiles: [OrbitProfile] {
        _ = profileStoreRevision
        return OrbitProfileStore.load()
    }

    private var activeOrbitProfile: OrbitProfile? {
        if let id = UUID(uuidString: activeProfileID),
           let profile = storedProfiles.first(where: { $0.id == id }) {
            return profile
        }
        return storedProfiles.first {
            $0.name == activeProfileName && !$0.peerAddress.isEmpty && $0.peerAddress == peerAddress
        }
    }

    private var activeSubscription: OrbitSubscription? {
        guard let profile = activeOrbitProfile else { return nil }
        let subscriptions = OrbitProfileStore.loadSubscriptions()
        if let providerID = profile.subscriptionID,
           let subscription = subscriptions.first(where: {
               $0.subscriptionID == providerID || $0.url == profile.sourceSubscriptionURL
           }) {
            return subscription
        }
        return subscriptions.first { profile.sourceSubscriptionURL == $0.url || profile.folder == $0.name }
    }

    private var activeSubscriptionProfiles: [OrbitProfile] {
        guard let subscription = activeSubscription else { return [] }
        let providerID = subscription.subscriptionID ?? subscription.url
        return storedProfiles
            .filter {
                $0.subscriptionID == providerID
                    || $0.sourceSubscriptionURL == subscription.url
                    || ($0.subscriptionID == nil && $0.folder == subscription.name)
            }
            .sorted {
                let lhs = ($0.region?.isEmpty == false ? $0.region! : $0.name)
                let rhs = ($1.region?.isEmpty == false ? $1.region! : $1.name)
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    private var activeSubscriptionCanConnect: Bool {
        guard let status = activeSubscription?.status, !status.isEmpty else { return true }
        return status == "active"
    }

    private var backgroundGradient: LinearGradient {
        if tunnel.status == .connected { return AppTheme.connectedGradient }
        if isBusy { return AppTheme.connectingGradient }
        return AppTheme.idleGradient
    }

    private var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.35), value: tunnel.status)

                Circle()
                    .fill(AppTheme.accent.opacity(tunnel.status == .connected ? 0.10 : 0.05))
                    .frame(width: 390, height: 390)
                    .offset(x: -150, y: -310)
                    .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        headerBar
                        connectControl
                        statusBlock
                        activeConnectionCard

                        if tunnel.status == .connected {
                            StatsView(tunnel: tunnel)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if let noticeText {
                            HStack(spacing: 9) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                                Text(noticeText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.82))
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        quickImportCard
                        apnsCard
                        bottomInfo
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                }
            }
            .navigationBarHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $tunnel.captchaPending) {
                if let urlString = tunnel.captchaImageURL, let url = URL(string: urlString) {
                    CaptchaWebView(
                        url: url,
                        captchaSID: tunnel.captchaSID ?? "",
                        onSolved: { token in tunnel.solveCaptcha(answer: token) },
                        onDismiss: {
                            tunnel.onCaptchaSheetDismissed()
                            tunnel.captchaPending = false
                            tunnel.captchaImageURL = nil
                        },
                        onLimitDetected: { tunnel.onCaptchaLimitDetected() },
                        onCaptchaReady: { tunnel.onCaptchaReady() },
                        onLog: { tunnel.logFromCaptchaView($0) },
                        tunnel: tunnel
                    )
                }
            }
            .sheet(isPresented: $tunnel.vkLoginPending) {
                VKAuthWebView { result in tunnel.onVKLoginResult(result) }
            }
            .sheet(isPresented: $showQuickQRScanner) {
                NavigationView {
                    QRCodeScannerView(
                        onResult: { raw in
                            showQuickQRScanner = false
                            Task { @MainActor in await importRaw(raw, forcedKind: nil) }
                        },
                        onError: { message in
                            showQuickQRScanner = false
                            showImportError(message, title: "Сканер недоступен")
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Сканирование QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { showQuickQRScanner = false }
                        }
                    }
                }
            }
            .alert(importAlertTitle, isPresented: Binding(
                get: { importAlertMessage != nil },
                set: { if !$0 { importAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { importAlertMessage = nil }
            } message: {
                Text(importAlertMessage ?? "")
            }
        }
        .onAppear {
            performPendingAction()
            performPendingURL()
        }
        .onChange(of: actionInbox.pendingAction) { _ in performPendingAction() }
        .onChange(of: actionInbox.pendingURL) { _ in performPendingURL() }
        .onChange(of: proxyAPNs) { _ in reconnectForAPNsIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .orbitProfilesDidChange)) { _ in
            profileStoreRevision &+= 1
        }
    }

    private var headerBar: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ORBIT")
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.accent)
                Text("v\(appVersionString)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            Spacer()
            NavigationLink { LogsView(tunnel: tunnel) } label: { headerIcon("doc.text") }
            NavigationLink { SettingsView() } label: { headerIcon("gearshape.fill") }
        }
        .padding(.top, 4)
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white.opacity(0.78))
            .frame(width: 40, height: 40)
            .background(AppTheme.surface, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var connectControl: some View {
        Button(action: toggleConnection) {
            ZStack {
                Circle()
                    .fill(AppTheme.surfaceRaised)
                    .frame(width: 212, height: 212)
                    .overlay(Circle().strokeBorder(statusColor.opacity(0.26), lineWidth: 16))
                    .overlay(
                        Circle()
                            .strokeBorder(statusColor.opacity(isActive ? 0.72 : 0.28), lineWidth: 2)
                            .padding(7)
                    )
                    .shadow(color: statusColor.opacity(isActive ? 0.22 : 0.08), radius: 26)

                if isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(statusColor)
                        .scaleEffect(2.2)
                } else {
                    Image(systemName: isActive ? "stop.fill" : "power")
                        .font(.system(size: 62, weight: .light))
                        .foregroundStyle(isActive ? statusColor : .white.opacity(0.66))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isActive && configValidationError != nil)
        .opacity(!isActive && configValidationError != nil ? 0.58 : 1)
        .padding(.top, 14)
        .accessibilityLabel(isActive ? "Отключить VPN" : "Подключить VPN")
    }

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(statusTitle)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.53))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 340)
    }

    @ViewBuilder
    private var activeConnectionCard: some View {
        if let subscription = activeSubscription, let selectedProfile = activeOrbitProfile {
            currentProviderCard(subscription: subscription, selectedProfile: selectedProfile)
        } else {
            currentServerCard
        }
    }

    private func currentProviderCard(subscription: OrbitSubscription, selectedProfile: OrbitProfile) -> some View {
        let regions = activeSubscriptionProfiles
        let active = activeSubscriptionCanConnect
        let used = subscription.trafficUsedBytes ?? Int64((subscription.trafficUsedMb ?? 0) * 1024 * 1024)
        let limit = subscription.trafficLimitBytes ?? subscription.trafficLimitMb.map { Int64($0 * 1024 * 1024) }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("ТЕКУЩИЙ ПРОВАЙДЕР")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.38))
                Spacer()
                Button {
                    Task { await probeProviderRegions(regions) }
                } label: {
                    Image(systemName: providerProbeInProgress ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(AppTheme.accent.opacity(0.11), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(providerProbeInProgress || regions.isEmpty)
                Text(providerStatusText(subscription))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(providerStatusColor(subscription))
            }

            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subscription.description ?? "Региональные серверы Orbit")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                providerMetric(title: "СРОК", value: subscriptionExpiryText(subscription.expiresAt))
                providerMetric(title: "СЕРВЕРЫ", value: "\(max(subscription.serverCount ?? 0, regions.count))")
            }

            if let limit, limit > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("ТРАФИК")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.38))
                        Spacer()
                        Text("\(formatTraffic(used)) / \(formatTraffic(limit))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.64))
                    }
                    ProgressView(value: min(Double(used), Double(limit)), total: Double(limit))
                        .tint(active ? AppTheme.accent : AppTheme.danger)
                }
            } else {
                HStack {
                    Text("ТРАФИК")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer()
                    Text("\(formatTraffic(used)) / ∞")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.64))
                }
            }

            if let message = subscription.statusMessage, !message.isEmpty, !active {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.danger)
            }

            if !regions.isEmpty {
                Divider().overlay(Color.white.opacity(0.10))
                Text("РЕГИОНЫ")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.38))
                ForEach(regions) { profile in
                    providerRegionRow(profile, isSelected: isSelectedProviderProfile(profile, selectedProfile: selectedProfile), isEnabled: active)
                }
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(active ? AppTheme.accent.opacity(0.22) : AppTheme.danger.opacity(0.30), lineWidth: 1)
        )
    }

    private func providerMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func providerRegionRow(_ profile: OrbitProfile, isSelected: Bool, isEnabled: Bool) -> some View {
        Button {
            guard isEnabled else {
                showImportError(activeSubscription?.statusMessage ?? "Подписка сейчас недоступна.", title: "Подключение недоступно")
                return
            }
            activateProfile(profile, notice: "Выбран регион «\(providerRegionName(profile))». Подключаемся…")
        } label: {
            HStack(spacing: 11) {
                Text(flagEmoji(profile.countryCode))
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerRegionName(profile))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(isEnabled ? 0.90 : 0.42))
                    Text(profile.peerAddress)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let latency = providerLatencies[profile.id] {
                    Text("\(latency) мс")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.accent)
                } else if providerProbeInProgress {
                    ProgressView().tint(AppTheme.accent).scaleEffect(0.7)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(isSelected ? .body.weight(.semibold) : .caption.weight(.bold))
                    .foregroundStyle(isSelected ? AppTheme.accent : .white.opacity(0.34))
            }
            .padding(10)
            .background(
                isSelected ? AppTheme.accent.opacity(0.11) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? AppTheme.accent.opacity(0.58) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func providerRegionName(_ profile: OrbitProfile) -> String {
        let region = profile.region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return region.isEmpty ? profile.name : profile.name + " · " + region
    }

    private func isSelectedProviderProfile(_ profile: OrbitProfile, selectedProfile: OrbitProfile) -> Bool {
        profile.id == selectedProfile.id
            || (!activeProfileID.isEmpty && profile.id.uuidString == activeProfileID)
            || (profile.name == selectedProfile.name && profile.peerAddress == selectedProfile.peerAddress)
    }

    private func providerStatusText(_ subscription: OrbitSubscription) -> String {
        switch subscription.status {
        case "expired": return "ИСТЕКЛА"
        case "quota_exceeded": return "ЛИМИТ"
        case "disabled": return "ОТКЛЮЧЕНА"
        default: return tunnel.status == .connected ? "АКТИВНА" : "ГОТОВА"
        }
    }

    private func providerStatusColor(_ subscription: OrbitSubscription) -> Color {
        activeSubscriptionCanConnect ? AppTheme.accent : AppTheme.danger
    }

    private func subscriptionExpiryText(_ date: Date?) -> String {
        guard let date else { return "Бессрочно" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 0 { return "Истёк" }
        if days == 0 { return "Сегодня" }
        return "\(days) дн."
    }

    private func formatTraffic(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func flagEmoji(_ countryCode: String?) -> String {
        guard let countryCode, countryCode.count == 2 else { return "🌐" }
        return countryCode.uppercased().unicodeScalars.compactMap { scalar in
            UnicodeScalar(127397 + scalar.value)
        }.map(String.init).joined()
    }

    private func probeProviderRegions(_ profiles: [OrbitProfile]) async {
        guard !providerProbeInProgress else { return }
        providerProbeInProgress = true
        defer { providerProbeInProgress = false }
        for profile in profiles {
            if let latency = await OrbitProfileStore.probePeer(profile.peerAddress) {
                providerLatencies[profile.id] = latency
            }
        }
    }

    private var currentServerCard: some View {
        Button(action: onOpenServers) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ТЕКУЩИЙ СЕРВЕР")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer()
                    Text(tunnel.status == .connected ? "АКТИВЕН" : "ГОТОВ")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tunnel.status == .connected ? AppTheme.accent : .white.opacity(0.38))
                }

                HStack(spacing: 12) {
                    Image(systemName: peerAddress.isEmpty ? "server.rack" : "bolt.shield.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayServerName)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(peerAddress.isEmpty ? "Импортируйте подключение ниже" : peerAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.34))
                }

                if !peerAddress.isEmpty {
                    HStack(spacing: 8) {
                        Label(currentModeLabel, systemImage: "wave.3.right")
                        Spacer()
                        Label(useUDP ? "UDP" : "TCP", systemImage: useUDP ? "wifi" : "network")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.48))
                }
            }
            .padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var quickImportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Добавить подключение")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Скопируйте ссылку из бота или отсканируйте QR")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.46))
                }
                Spacer()
                if quickImportBusy { ProgressView().tint(AppTheme.accent) }
            }

            LazyVGrid(columns: quickActionColumns, spacing: 12) {
                quickAction(title: "Подписка", subtitle: "HTTPS-ссылка", icon: "cloud.fill") {
                    startClipboardImport(.subscription)
                }
                quickAction(title: "qWDTT", subtitle: "Профиль из бота", icon: "arrow.down.doc.fill") {
                    startClipboardImport(.qwdtt)
                }
                quickAction(title: "WDTT", subtitle: "Ссылка подключения", icon: "link") {
                    startClipboardImport(.wdtt)
                }
                quickAction(title: "QR-код", subtitle: "Сканировать", icon: "qrcode.viewfinder") {
                    showQuickQRScanner = true
                }
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .disabled(quickImportBusy)
    }

    private func quickAction(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(AppTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var apnsCard: some View {
        Toggle(isOn: $proxyAPNs) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.title3)
                    .foregroundStyle(proxyAPNs ? AppTheme.accent : .white.opacity(0.45))
                    .frame(width: 42, height: 42)
                    .background(
                        proxyAPNs ? AppTheme.accent.opacity(0.11) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проксировать APNs через Orbit")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Включите, если уведомления не приходят")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                    Text(proxyAPNs ? "Сейчас: через VPN" : "Сейчас: в обход VPN")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(proxyAPNs ? AppTheme.accent : .white.opacity(0.36))
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: AppTheme.accent))
        .disabled(apnsReconnecting)
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if apnsReconnecting {
                ProgressView().tint(AppTheme.accent).padding(10)
            }
        }
    }

    private var bottomInfo: some View {
        HStack(spacing: 10) {
            infoChip(icon: "link", text: "\(energySaver ? min(numConnections, 8) : numConnections) каналов")
            infoChip(icon: "leaf.fill", text: energySaver ? "Экономия вкл." : "Макс. скорость")
        }
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.48))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.04), in: Capsule())
    }

    private func startClipboardImport(_ kind: QuickImportKind) {
        let raw = UIPasteboard.general.string ?? ""
        Task { @MainActor in await importRaw(raw, forcedKind: kind) }
    }

    @MainActor
    private func importRaw(_ rawValue: String, forcedKind: QuickImportKind?) async {
        guard !quickImportBusy else { return }
        quickImportBusy = true
        defer { quickImportBusy = false }

        do {
            let raw = sanitizeImportedText(rawValue)
            guard !raw.isEmpty else {
                throw importFailure("Буфер обмена пуст. Сначала скопируйте ссылку из Telegram-бота.")
            }

            let kind: QuickImportKind
            if let forcedKind {
                kind = forcedKind
            } else if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                kind = .subscription
            } else if raw.lowercased().hasPrefix("qwdtt:") || raw.first == "{" {
                kind = .qwdtt
            } else {
                kind = .wdtt
            }

            switch kind {
            case .subscription:
                let url = try OrbitProfileStore.normalizedSubscriptionURL(from: raw)
                let (subscription, imported) = try await OrbitProfileStore.importSubscription(from: url)
                guard let first = imported.first else { throw ProfileError.missingProfiles }

                var profiles = OrbitProfileStore.load()
                let providerID = subscription.subscriptionID ?? subscription.url
                profiles.removeAll {
                    $0.subscriptionID == providerID
                        || $0.sourceSubscriptionURL == subscription.url
                        || ($0.subscriptionID == nil && $0.folder == subscription.name)
                }
                profiles.append(contentsOf: imported)
                OrbitProfileStore.save(profiles)

                var subscriptions = OrbitProfileStore.loadSubscriptions()
                OrbitProfileStore.upsertSubscription(subscription, into: &subscriptions)
                UserDefaults.standard.set(subscription.url, forKey: "orbitSubscriptionURL")
                activateProfile(
                    first,
                    notice: imported.count == 1
                        ? "Подписка «\(subscription.name)» загружена. Подключаемся…"
                        : "Подписка «\(subscription.name)» загружена. Подключаемся к основному региону; остальные доступны ниже."
                )

            case .qwdtt:
                let profile: OrbitProfile
                if raw.lowercased().hasPrefix("qwdtt:") {
                    profile = try OrbitProfileStore.importQWDTT(raw: raw)
                } else {
                    profile = try OrbitProfileStore.importQWDTT(data: Data(raw.utf8))
                }
                rememberProfile(profile)
                activateProfile(profile, notice: "qWDTT «\(profile.name)» импортирован. Подключаемся…")

            case .wdtt:
                let lowercased = raw.lowercased()
                guard lowercased.hasPrefix("wdtt://")
                    || lowercased.hasPrefix("vkturnproxy://")
                    || lowercased.hasPrefix("freeturn://") else {
                    throw importFailure("Ожидалась ссылка wdtt://. Проверьте, что ссылка скопирована целиком.")
                }
                let link = try BackupManager.parseConnectionLinkString(raw)
                BackupManager.applyConnectionLink(link)
                let profile = OrbitProfile.capture(name: "WDTT", folder: "Импортированные")
                rememberProfile(profile)
                activateProfile(profile, notice: "WDTT импортирован. Подключаемся…")
            }
        } catch {
            showImportError(error.localizedDescription)
        }
    }

    private func sanitizeImportedText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0060}<>\u{0022}'"))
    }

    private func rememberProfile(_ profile: OrbitProfile) {
        var profiles = OrbitProfileStore.load()
        profiles.removeAll {
            !$0.peerAddress.isEmpty && $0.peerAddress == profile.peerAddress && $0.vkLink == profile.vkLink
        }
        profiles.append(profile)
        OrbitProfileStore.save(profiles)
        NotificationCenter.default.post(name: .orbitProfilesDidChange, object: nil)
    }

    private func activateProfile(_ profile: OrbitProfile, notice: String) {
        profile.apply()
        activeProfileName = profile.name
        activeProfileID = profile.id.uuidString
        noticeText = notice
        NotificationCenter.default.post(name: .orbitProfilesDidChange, object: nil)
        connectAfterImport()
    }

    private func connectAfterImport() {
        Task { @MainActor in
            if isActive || tunnel.status == .disconnecting {
                tunnel.disconnect()
                for _ in 0..<50 {
                    if tunnel.status == .disconnected || tunnel.status == .invalid { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let error = configValidationError {
                showImportError(error, title: "Подключение не запущено")
                return
            }
            if !isActive { toggleConnection() }
        }
    }

    private func reconnectForAPNsIfNeeded() {
        guard isActive || tunnel.status == .disconnecting, !apnsReconnecting else {
            noticeText = proxyAPNs
                ? "APNs будет идти через Orbit при следующем подключении."
                : "APNs будет обходить Orbit при следующем подключении."
            return
        }

        apnsReconnecting = true
        noticeText = proxyAPNs
            ? "Переподключаем VPN: APNs пойдёт через Orbit…"
            : "Переподключаем VPN: APNs будет обходить Orbit…"

        Task { @MainActor in
            tunnel.disconnect()
            for _ in 0..<50 {
                if tunnel.status == .disconnected || tunnel.status == .invalid { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !isActive, configValidationError == nil { toggleConnection() }
            apnsReconnecting = false
        }
    }

    private func showImportError(_ message: String, title: String = "Ошибка импорта") {
        importAlertTitle = title
        importAlertMessage = message
    }

    private func importFailure(_ message: String) -> NSError {
        NSError(domain: "OrbitImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func parseTurnOverride(_ value: String) -> (host: String, port: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let port = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber), Int(port) != nil else { return nil }
        return (host, port)
    }

    private func toggleConnection() {
        if isActive {
            SharedLogger.shared.log("[UI] user pressed Disconnect button (status=\(tunnel.status.rawValue))")
            tunnel.disconnect()
            return
        }

        SharedLogger.shared.log("[UI] user pressed Connect button (status=\(tunnel.status.rawValue), proxyAPNs=\(proxyAPNs))")
        let turnOverride = parseTurnOverride(turnServerOverride)
        let vkLines = vkLink.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let vkAuthOn = UserDefaults.standard.bool(forKey: "VKAuth")
        let requestedConnections = energySaver ? min(numConnections, 8) : numConnections
        let effectiveConnections = vkAuthOn
            ? min(requestedConnections, min(50, max(2, vkLines.count * 20)))
            : requestedConnections

        let config = TunnelConfig(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            presharedKey: presharedKey.isEmpty ? nil : presharedKey,
            tunnelAddress: tunnelAddress,
            dnsServers: dnsServers,
            allowedIPs: "0.0.0.0/0",
            vkLink: vkLines.first ?? vkLink,
            cookieLinks: vkLines,
            peerAddress: peerAddress,
            useDTLS: useDTLS,
            useWrap: useWrap,
            wrapKeyHex: wrapKeyHex,
            useSrtp: useSrtp,
            useWrapA: useWrapA,
            wrapAPassword: wrapAPassword,
            useWrapS: useWrapS,
            obfProfile: obfProfile,
            clientID: clientID,
            useUDP: useUDP,
            forceLegacyCaptcha: UserDefaults.standard.bool(forKey: "forceLegacyCaptcha"),
            useCookieAuth: vkAuthOn,
            proxyAPNs: proxyAPNs,
            numConnections: effectiveConnections,
            credPoolCooldownSeconds: credPoolCooldownSeconds,
            turnServerOverride: turnOverride?.host,
            turnPortOverride: turnOverride?.port
        )
        Task { await tunnel.connect(config: config) }
    }

    private func performPendingURL() {
        guard let url = actionInbox.pendingURL else { return }
        actionInbox.pendingURL = nil
        Task { @MainActor in await importRaw(url.absoluteString, forcedKind: nil) }
    }

    private func performPendingAction() {
        guard let action = actionInbox.pendingAction else { return }
        actionInbox.pendingAction = nil
        switch action {
        case "connect":
            if !isActive { toggleConnection() }
        case "disconnect":
            if isActive { toggleConnection() }
        case "toggle":
            toggleConnection()
        default:
            SharedLogger.shared.log("[UI] unknown shortcut action: \(action)")
        }
    }
}
#Preview {
    OrbitRootView()
}
