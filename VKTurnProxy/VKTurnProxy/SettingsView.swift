import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreImage

struct SettingsView: View {
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
    @AppStorage("VKAuth") private var vkAuthEnabled = false
    @State private var exportURL: IdentifiableURL? = nil
    @State private var showImportPicker = false
    @State private var showProfileImportPicker = false
    @State private var profiles: [OrbitProfile] = OrbitProfileStore.load()
    @State private var subscriptions: [OrbitSubscription] = OrbitProfileStore.loadSubscriptions()
    @State private var showProfileName = false
    @State private var profileName = ""
    @State private var profileFolder = "Личные"
    @AppStorage("orbitSubscriptionURL") private var subscriptionURL = ""
    @State private var subscriptionMessage: String?
    @State private var subscriptionLoading = false
    @State private var probingProfile: UUID?
    @State private var probeResults: [UUID: Int] = [:]
    @State private var pendingImportConfig: AppConfig? = nil
    @State private var showImportConfirm = false
    @State private var showResetConfirm = false
    @State private var showResetProfileConfirm = false
    @State private var showVKAuthLogin = false
    @State private var showDeleteCookiesConfirm = false
    @State private var vkCookieInfo: VKCookieStore.Stored? = nil
    @State private var alertMessage: String? = nil
    @State private var alertTitle: String = ""
    @State private var pendingConnectionLink: ConnectionLink? = nil
    @State private var showConnectionLinkConfirm = false

    private var serverModeBinding: Binding<ServerMode> {
        Binding(
            get: {
                if useWrapS { return .srtpWrapS }
                if useWrapA { return .srtpWrapA }
                if useSrtp { return .srtp }
                if useWrap { return .srtpWrap }
                return .legacy
            },
            set: { newMode in
                switch newMode {
                case .legacy:
                    useWrapS = false; useWrapA = false; useSrtp = false; useWrap = false
                case .srtp:
                    useWrapS = false; useWrapA = false; useSrtp = true; useWrap = false
                case .srtpWrap:
                    useWrapS = false; useWrapA = false; useSrtp = false; useWrap = true
                case .srtpWrapA:
                    useWrapS = false; useWrapA = true; useSrtp = false; useWrap = false
                case .srtpWrapS:
                    useWrapA = false; useSrtp = false; useWrap = false; useWrapS = true
                    if clientID.isEmpty { clientID = UUID().uuidString }
                }
            }
        )
    }

    @ViewBuilder
    private func hint(_ issue: ConfigValidation.Issue?) -> some View {
        if let issue {
            Text(issue.message)
                .font(.caption)
                .foregroundColor(issue.severity == .error ? AppTheme.danger : AppTheme.warning)
        }
    }

    private var vkLinkLines: [String] {
        vkLink.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    private var vkLinkPrimary: String { vkLinkLines.first ?? "" }
    private var cookieConnCap: Int { min(50, max(2, vkLinkLines.count * 20)) }
    private var connectionsUpperBound: Int {
        vkAuthEnabled ? max(cookieConnCap, numConnections) : max(50, numConnections)
    }
    private var connectionsLabel: String {
        if vkAuthEnabled && numConnections > cookieConnCap {
            return "Соединения: \(numConnections) → \(cookieConnCap) (добавьте ссылки)"
        }
        if vkAuthEnabled {
            return "Соединения: \(numConnections) (макс. \(cookieConnCap))"
        }
        return "Соединения: \(numConnections)"
    }

    var body: some View {
        Form {
            // MARK: Connection
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vkAuthEnabled
                         ? "Ссылки VK‑звонка — по одной на строку (\(vkLinkLines.count))"
                         : "Ссылка VK‑звонка")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $vkLink)
                        .frame(minHeight: vkAuthEnabled ? 110 : 44)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                }
                if vkAuthEnabled {
                    let n = vkLinkLines.count
                    Text(n == 0
                         ? "Добавьте хотя бы одну ссылку. Каждая даёт 2 TURN‑relay (~20 соединений)."
                         : "\(n) ссылк\(n == 1 ? "а" : "и") → до \(cookieConnCap) соединений.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                hint(ConfigValidation.vkLink(vkLinkPrimary))

                labeledField("Прокси‑сервер", placeholder: "IP:порт", text: $peerAddress)
                hint(ConfigValidation.peerAddress(peerAddress))

                labeledField("Переопределение TURN", placeholder: "IP:порт (необязательно)", text: $turnServerOverride)
                    .keyboardType(.numbersAndPunctuation)
                hint(ConfigValidation.turnOverride(turnServerOverride))
            } header: {
                Label("Подключение", systemImage: "network")
            } footer: {
                Text("Ссылку звонка создайте во ВКонтакте и вставьте сюда. Прокси — адрес вашего сервера vk-turn-proxy (-listen).")
            }

            // MARK: Mode
            Section {
                Picker("Режим сервера", selection: serverModeBinding) {
                    ForEach(ServerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(serverModeBinding.wrappedValue.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if serverModeBinding.wrappedValue == .srtpWrap {
                    SecureField("WRAP‑ключ (64 hex)", text: $wrapKeyHex)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wrapKeyHex(wrapKeyHex))
                }

                if serverModeBinding.wrappedValue == .srtpWrapA {
                    SecureField("Пароль сервера", text: $wrapAPassword)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    hint(ConfigValidation.wrapAPassword(wrapAPassword))
                }

                if serverModeBinding.wrappedValue == .srtpWrapS {
                    SecureField("WRAP‑ключ (64 hex)", text: $wrapKeyHex)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wrapKeyHex(wrapKeyHex))
                    Picker("Профиль обфускации", selection: $obfProfile) {
                        Text("rtpopus").tag("rtpopus")
                        Text("rtpopus2").tag("rtpopus2")
                        Text("rtpopus3").tag("rtpopus3")
                    }
                    TextField("ID клиента", text: $clientID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                }

                Toggle(isOn: $useUDP) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UDP к TURN")
                        Text("По умолчанию TCP — устойчивее. UDP может быть быстрее, но чаще ловит лимиты VK.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $energySaver) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Экономия энергии")
                        Text("Ограничивает фоновые каналы и уменьшает нагрузку на CPU. Для обычного VPN рекомендуется включить.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(energySaver ? "Каналы: \(min(numConnections, 8)) (экономичный режим)" : connectionsLabel,
                        value: $numConnections, in: 1...connectionsUpperBound)
                Stepper("Кулдаун пула: \(credPoolCooldownSeconds) с", value: $credPoolCooldownSeconds, in: 30...600, step: 30)
            } header: {
                Label("Режим и скорость", systemImage: "bolt.fill")
            } footer: {
                Text("Больше соединений — выше скорость (до ~50 Мбит/с на 30). Рекомендуется режим SRTP.")
            }

            // MARK: WireGuard
            if serverModeBinding.wrappedValue != .srtpWrapA {
                Section {
                    SecureField("Приватный ключ (base64)", text: $privateKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wgKey(privateKey, label: "Приватный ключ", required: true))

                    TextField("Публичный ключ сервера (base64)", text: $peerPublicKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wgKey(peerPublicKey, label: "Публичный ключ сервера", required: true))

                    SecureField("Предварительный общий ключ (необязательно)", text: $presharedKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wgKey(presharedKey, label: "Предварительный общий ключ", required: false))

                    labeledField("Адрес туннеля", placeholder: "192.168.x.x/24", text: $tunnelAddress)
                    hint(ConfigValidation.tunnelAddress(tunnelAddress))

                    labeledField("DNS", placeholder: "1.1.1.1", text: $dnsServers)
                    hint(ConfigValidation.dnsServers(dnsServers))
                } header: {
                    Label("WireGuard", systemImage: "lock.shield.fill")
                } footer: {
                    Text("Ключи должны совпадать с [Peer] на сервере WireGuard. В режиме WRAP‑A ключи выдаёт сервер сам.")
                }
            }

            // MARK: VK Auth
            Section {
                Toggle("Авторизация через аккаунт VK", isOn: $vkAuthEnabled)

                if vkAuthEnabled {
                    HStack {
                        Text("Сессия")
                        Spacer()
                        Text(vkCookieStatusText)
                            .foregroundColor(vkCookieStatusColor)
                    }
                    .font(.subheadline)

                    Button {
                        showVKAuthLogin = true
                    } label: {
                        Label(vkCookieInfo == nil ? "Войти во VK…" : "Перелогиниться…",
                              systemImage: "person.crop.circle.badge.checkmark")
                    }

                    if vkCookieInfo != nil {
                        Button(role: .destructive) { showDeleteCookiesConfirm = true } label: {
                            Label("Удалить cookies", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Label("Аккаунт VK", systemImage: "person.crop.circle")
            } footer: {
                Text("Нужен, если анонимный join отключён. Cookies хранятся в Keychain и не попадают в бэкап. Лучше отдельный аккаунт.")
            }

            // MARK: Backup
            Section {
                if profiles.isEmpty {
                    Text("Профилей пока нет. Сохраните текущую конфигурацию или импортируйте qWDTT JSON.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        HStack(spacing: 10) {
                            Button { activateProfile(profile) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .foregroundStyle(.primary)
                        Text("\(profile.folder) · \(profile.peerAddress.isEmpty ? "Сервер не задан" : profile.peerAddress)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button { exportProfile(profile) } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppTheme.accent)
                            Button { exportProfileQRCode(profile) } label: {
                                Image(systemName: "qrcode")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppTheme.accent)
                            Button { Task { await probeProfile(profile) } } label: {
                                Image(systemName: probingProfile == profile.id ? "hourglass" : "gauge.with.dots.needle.33percent")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppTheme.accent)
                            if let latency = probeResults[profile.id] {
                                Text("\(latency) мс")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        OrbitProfileStore.delete(at: offsets, from: &profiles)
                    }
                    .onMove { offsets, destination in
                        OrbitProfileStore.move(from: offsets, to: destination, in: &profiles)
                    }

                    EditButton()
                }

                Button {
                    profileName = "Профиль \(profiles.count + 1)"
                    showProfileName = true
                } label: {
                    Label("Сохранить текущую конфигурацию", systemImage: "plus.circle")
                }

                Button { showProfileImportPicker = true } label: {
                    Label("Импортировать qWDTT JSON…", systemImage: "arrow.down.doc")
                }

                TextField("https://example.com/subscription.json", text: $subscriptionURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                Button {
                    Task { await importSubscription() }
                } label: {
                    Label(subscriptionLoading ? "Загрузка подписки…" : "Обновить HTTPS-подписку", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(subscriptionLoading || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let subscriptionMessage {
                    Text(subscriptionMessage)
                        .font(.caption)
                        .foregroundStyle(subscriptionMessage.hasPrefix("Ошибка") ? AppTheme.danger : AppTheme.success)
                }

                if !subscriptions.isEmpty {
                    ForEach(subscriptions) { subscription in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(subscription.name, systemImage: "cloud.fill")
                                Spacer()
                                Text(subscription.updatedAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let description = subscription.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let limit = subscription.trafficLimitMb {
                                let used = subscription.trafficUsedMb ?? 0
                                ProgressView(value: min(max(used / max(limit, 1), 0), 1))
                                Text("Трафик: \(Int(used)) / \(Int(limit)) МБ")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                Task { await refreshSubscription(subscription) }
                            } label: {
                                Label("Обновить", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Label("Профили", systemImage: "square.stack.3d.up")
            } footer: {
                Text("Профиль хранит настройки подключения локально. Кэш TURN и профиль браузера остаются общими для устройства.")
            }

            Section {
                Button(action: handleExport) {
                    Label("Экспорт полного бэкапа…", systemImage: "square.and.arrow.up")
                }

                Button(action: { showImportPicker = true }) {
                    Label("Импорт бэкапа…", systemImage: "square.and.arrow.down")
                }

                Button(action: handleConnectionLinkPaste) {
                    Label("Импорт ссылки (автоопределение)…", systemImage: "link.badge.plus")
                }

                Button { handleProtocolLinkPaste(scheme: "wdtt") } label: {
                    Label("Импорт ссылки wdtt://", systemImage: "arrow.down.to.line.compact")
                }

                Button { handleProtocolLinkPaste(scheme: "qwdtt") } label: {
                    Label("Импорт ссылки qwdtt://", systemImage: "person.2.wave.2")
                }

                Button(role: .destructive, action: { showResetConfirm = true }) {
                    Label("Сбросить кэш TURN", systemImage: "trash")
                }

                Button(role: .destructive, action: { showResetProfileConfirm = true }) {
                    Label("Сбросить профиль браузера", systemImage: "trash")
                }
            } header: {
                Label("Бэкап и кэш", systemImage: "externaldrive.fill")
            } footer: {
                Text("wdtt:// применяет настройки подключения сразу, а qwdtt:// добавляет отдельный профиль. Полный бэкап содержит ключи WireGuard и креды TURN — храните его как секрет.")
            }

            Section {
                HStack {
                    Text("Версия")
                    Spacer()
                    Text(appVersionString)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            } footer: {
                Text("Orbit — форк vk-turn-proxy-ios с новым интерфейсом. Сетевой стек и протоколы совместимы с оригиналом.")
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .sheet(item: $exportURL) { wrapped in
            ShareSheet(activityItems: [wrapped.url])
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPicker(contentTypes: [.json, .text, .data, .item]) { url in
                handleImportPicked(url: url)
            }
        }
        .sheet(isPresented: $showProfileImportPicker) {
            DocumentPicker(contentTypes: [.json, .data, .item]) { url in
                importQWDTT(url: url)
            }
        }
        .alert("Имя профиля", isPresented: $showProfileName) {
            TextField("Например, Дом", text: $profileName)
            TextField("Папка", text: $profileFolder)
            Button("Сохранить") { saveCurrentProfile() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это имя будет отображаться в списке профилей.")
        }
        .alert("Импортировать бэкап?", isPresented: $showImportConfirm, presenting: pendingImportConfig) { config in
            Button("Импорт", role: .destructive) { applyPendingImport(config) }
            Button("Отмена", role: .cancel) { pendingImportConfig = nil }
        } message: { config in
            let date = Date(timeIntervalSince1970: TimeInterval(config.exportedAt))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let credCount = config.turnPool?.creds.count ?? 0
            let profileMark = (config.vkProfile != nil) ? " + профиль браузера" : ""
            return Text("Бэкап от \(formatter.string(from: date)), \(credCount) кред(ов)\(profileMark). Текущие настройки будут заменены.")
        }
        .alert("Импортировать ссылку?", isPresented: $showConnectionLinkConfirm, presenting: pendingConnectionLink) { link in
            Button("Импорт", role: .destructive) { applyPendingConnectionLink(link) }
            Button("Отмена", role: .cancel) { pendingConnectionLink = nil }
        } message: { link in
            let s = link.settings
            let extras = [
                s.numConnections.map { "\($0) соед." },
                s.dnsServers.map { "DNS \($0)" }
            ].compactMap { $0 }.joined(separator: ", ")
            let extrasText = extras.isEmpty ? "" : " (\(extras))"
            if s.useWrapS == true, s.privateKey == nil {
                let prof = s.obfProfile ?? "rtpopus"
                return Text("Переключить на SRTP-WRAP-S для \(s.peerAddress)\(extrasText)? Ключи WireGuard и ссылку VK нужно ввести вручную. Профиль: \(prof).")
            }
            return Text("Применить настройки для \(s.peerAddress)\(extrasText)? Будут перезаписаны ключи, сервер, ссылка и WRAP.")
        }
        .alert("Сбросить кэш TURN?", isPresented: $showResetConfirm) {
            Button("Сбросить", role: .destructive) { handleReset() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Кэшированные креды будут удалены и запрошены заново при следующем подключении.")
        }
        .alert("Сбросить профиль браузера?", isPresented: $showResetProfileConfirm) {
            Button("Сбросить", role: .destructive) { handleResetProfile() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удаляет fingerprint для auto-PoW. До ручной капчи solver будет чаще детектироваться как бот.")
        }
        .sheet(isPresented: $showVKAuthLogin) {
            VKAuthWebView { result in
                showVKAuthLogin = false
                if case let .harvested(cookieHeader, expiry) = result {
                    VKCookieStore.save(cookieHeader: cookieHeader, expiry: expiry)
                    refreshVKCookieInfo()
                }
            }
        }
        .alert("Удалить cookies?", isPresented: $showDeleteCookiesConfirm) {
            Button("Удалить", role: .destructive) { handleDeleteCookies() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сохранённая сессия VK будет удалена. Для cookie‑auth нужно войти снова.")
        }
        .onAppear { refreshVKCookieInfo() }
        .onChange(of: vkAuthEnabled) { enabled in
            if enabled && !VKCookieStore.isValid() {
                showVKAuthLogin = true
            }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = alertMessage { Text(msg) }
        }
    }

    private var appVersionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Backup actions

    private func handleExport() {
        do {
            let url = try BackupManager.exportToTempFile()
            exportURL = IdentifiableURL(url: url)
        } catch {
            alertTitle = "Ошибка экспорта"
            alertMessage = error.localizedDescription
        }
    }

    private func handleImportPicked(url: URL) {
        do {
            let config = try BackupManager.importFromFileURL(url)
            pendingImportConfig = config
            showImportConfirm = true
        } catch {
            alertTitle = "Ошибка импорта"
            alertMessage = error.localizedDescription
        }
    }

    private func saveCurrentProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = profileFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = OrbitProfile.capture(name: name.isEmpty ? "Профиль \(profiles.count + 1)" : name,
                                           folder: folder.isEmpty ? "Личные" : folder)
        OrbitProfileStore.upsert(profile, into: &profiles)
        alertTitle = "Профиль сохранён"
        alertMessage = profile.name
    }

    private func exportProfile(_ profile: OrbitProfile) {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.name.replacingOccurrences(of: "/", with: "-"))
                .appendingPathExtension("qwdtt")
            try OrbitProfileStore.qwdttData(for: profile).write(to: url, options: .atomic)
            exportURL = IdentifiableURL(url: url)
        } catch {
            alertTitle = "Ошибка экспорта"
            alertMessage = error.localizedDescription
        }
    }

    private func exportProfileQRCode(_ profile: OrbitProfile) {
        do {
            let data = try OrbitProfileStore.qwdttData(for: profile)
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ProfileError.invalidFormat }
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage else { throw ProfileError.invalidFormat }
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
            let context = CIContext()
            guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { throw ProfileError.invalidFormat }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.name.replacingOccurrences(of: "/", with: "-"))
                .appendingPathExtension("png")
            guard let png = UIImage(cgImage: cgImage).pngData() else { throw ProfileError.invalidFormat }
            try png.write(to: url, options: Data.WritingOptions.atomic)
            exportURL = IdentifiableURL(url: url)
        } catch {
            alertTitle = "Ошибка QR-экспорта"
            alertMessage = error.localizedDescription
        }
    }

    private func importSubscription() async {
        subscriptionLoading = true
        defer { subscriptionLoading = false }
        do {
            let url = try OrbitProfileStore.normalizedSubscriptionURL(from: subscriptionURL)
            let (subscription, imported) = try await OrbitProfileStore.importSubscription(from: url)
            profiles.removeAll { $0.folder == subscription.name }
            for profile in imported { OrbitProfileStore.upsert(profile, into: &profiles) }
            OrbitProfileStore.upsertSubscription(subscription, into: &subscriptions)
            subscriptionMessage = "Загружено профилей: \(imported.count) · \(subscription.name)"
        } catch {
            subscriptionMessage = "Ошибка: \(error.localizedDescription)"
        }
    }

    private func probeProfile(_ profile: OrbitProfile) async {
        guard probingProfile == nil else { return }
        probingProfile = profile.id
        let latency = await OrbitProfileStore.probePeer(profile.peerAddress)
        probingProfile = nil
        if let latency {
            probeResults[profile.id] = latency
            subscriptionMessage = "Доступность \(profile.name): \(latency) мс"
        } else {
            subscriptionMessage = "Ошибка: peer-порт \(profile.peerAddress) недоступен по TCP"
        }
    }

    private func refreshSubscription(_ subscription: OrbitSubscription) async {
        do {
            let url = try OrbitProfileStore.normalizedSubscriptionURL(from: subscription.url)
            let (updated, imported) = try await OrbitProfileStore.importSubscription(from: url)
            profiles.removeAll { $0.folder == subscription.name }
            for profile in imported { OrbitProfileStore.upsert(profile, into: &profiles) }
            OrbitProfileStore.upsertSubscription(updated, into: &subscriptions)
            subscriptionMessage = "Подписка обновлена: \(imported.count) профилей"
        } catch {
            subscriptionMessage = "Ошибка обновления: \(error.localizedDescription)"
        }
    }

    private func activateProfile(_ profile: OrbitProfile) {
        guard !profile.peerAddress.isEmpty, !profile.vkLink.isEmpty else {
            alertTitle = "Профиль неполный"
            alertMessage = "В профиле не хватает сервера или VK-ссылки."
            return
        }
        profile.apply()
        UserDefaults.standard.set(profile.name, forKey: "activeProfileName")
        alertTitle = "Профиль активирован"
        alertMessage = "\(profile.name). Переподключите VPN, чтобы применить настройки."
    }

    private func importQWDTT(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let profile = try OrbitProfileStore.importQWDTT(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
            OrbitProfileStore.upsert(profile, into: &profiles)
            alertTitle = "qWDTT импортирован"
            alertMessage = "Профиль «\(profile.name)» добавлен."
        } catch {
            alertTitle = "Ошибка qWDTT"
            alertMessage = error.localizedDescription
        }
    }

    private func applyPendingImport(_ config: AppConfig) {
        do {
            try BackupManager.applyConfig(config)
            pendingImportConfig = nil
            alertTitle = "Импорт завершён"
            let credCount = config.turnPool?.creds.count ?? 0
            alertMessage = "Настройки восстановлены. Кэш TURN: \(credCount) слот(ов)."
        } catch {
            alertTitle = "Ошибка импорта"
            alertMessage = error.localizedDescription
        }
    }

    private func handleConnectionLinkPaste() {
        let raw = UIPasteboard.general.string ?? ""
        if raw.isEmpty {
            alertTitle = "Буфер пуст"
            alertMessage = "Скопируйте ссылку vkturnproxy://, wdtt:// или freeturn:// и повторите."
            return
        }
        do {
            let link = try BackupManager.parseConnectionLinkString(raw)
            pendingConnectionLink = link
            showConnectionLinkConfirm = true
        } catch {
            alertTitle = "Неверная ссылка"
            alertMessage = error.localizedDescription
        }
    }

    private func handleProtocolLinkPaste(scheme: String) {
        let raw = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            alertTitle = "Буфер пуст"
            alertMessage = "Скопируйте ссылку (scheme):// и повторите."
            return
        }

        guard raw.lowercased().hasPrefix("\(scheme):") else {
            alertTitle = "Неверная ссылка"
            alertMessage = "Ожидалась ссылка в формате (scheme)://."
            return
        }

        if scheme == "qwdtt" {
            do {
                let profile = try OrbitProfileStore.importQWDTT(raw: raw)
                OrbitProfileStore.upsert(profile, into: &profiles)
                alertTitle = "qWDTT импортирован"
                alertMessage = "Профиль «\(profile.name)» добавлен."
            } catch {
                alertTitle = "Ошибка qWDTT"
                alertMessage = error.localizedDescription
            }
        } else {
            do {
                let link = try BackupManager.parseConnectionLinkString(raw)
                pendingConnectionLink = link
                showConnectionLinkConfirm = true
            } catch {
                alertTitle = "Ошибка wdtt"
                alertMessage = error.localizedDescription
            }
        }
    }

    private func handleConnectionLinkURL(_ url: URL) {
        if url.scheme?.lowercased() == "qwdtt" {
            do {
                let profile = try OrbitProfileStore.importQWDTT(url: url)
                OrbitProfileStore.upsert(profile, into: &profiles)
                alertTitle = "qWDTT импортирован"
            alertMessage = "Профиль «\(profile.name)» добавлен."
            } catch {
                alertTitle = "Ошибка qWDTT"
                alertMessage = error.localizedDescription
            }
            return
        }
        do {
            let link = try BackupManager.parseConnectionLink(from: url)
            pendingConnectionLink = link
            showConnectionLinkConfirm = true
        } catch {
            alertTitle = "Неверная ссылка"
            alertMessage = error.localizedDescription
        }
    }

    private func applyPendingConnectionLink(_ link: ConnectionLink) {
        BackupManager.applyConnectionLink(link)
        pendingConnectionLink = nil
        alertTitle = "Ссылка применена"
        alertMessage = "Настройки обновлены. Переподключитесь, чтобы использовать их."
    }

    private func handleReset() {
        do {
            try BackupManager.resetTurnCache()
            alertTitle = "Кэш очищен"
            alertMessage = "creds-pool.json удалён. Пул пересоберётся при следующем подключении."
        } catch {
            alertTitle = "Ошибка"
            alertMessage = error.localizedDescription
        }
    }

    private func handleResetProfile() {
        do {
            try BackupManager.resetCapturedProfile()
            alertTitle = "Профиль очищен"
            alertMessage = "vk_profile.json удалён."
        } catch {
            alertTitle = "Ошибка"
            alertMessage = error.localizedDescription
        }
    }

    private var vkCookieStatusText: String {
        guard let info = vkCookieInfo else { return "Не вошли" }
        if info.expiry <= Date() { return "Истекла — войдите снова" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "Активна · до \(f.string(from: info.expiry))"
    }

    private var vkCookieStatusColor: Color {
        guard let info = vkCookieInfo else { return AppTheme.warning }
        return info.expiry <= Date() ? AppTheme.warning : AppTheme.success
    }

    private func refreshVKCookieInfo() {
        vkCookieInfo = VKCookieStore.load()
    }

    private func handleDeleteCookies() {
        VKCookieStore.delete()
        refreshVKCookieInfo()
        alertTitle = "Cookies удалены"
        alertMessage = "Сессия VK сброшена."
    }
}
