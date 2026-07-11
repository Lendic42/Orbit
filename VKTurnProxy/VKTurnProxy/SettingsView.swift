import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("privateKey") private var privateKey = ""
    @AppStorage("peerPublicKey") private var peerPublicKey = ""
    @AppStorage("presharedKey") private var presharedKey = ""
    @AppStorage("tunnelAddress") private var tunnelAddress = "192.168.102.3/24"
    @AppStorage("dnsServers") private var dnsServers = "1.1.1.1"
    @AppStorage("allowedIPs") private var allowedIPs = "0.0.0.0/0"
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
    @AppStorage("VKAuth") private var vkAuthEnabled = false

    @State private var exportURL: IdentifiableURL? = nil
    @State private var showImportPicker = false
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
    @StateObject private var connectionLinkInbox = ConnectionLinkInbox.shared

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

                labeledField("TURN override", placeholder: "IP:порт (необязательно)", text: $turnServerOverride)
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
                    TextField("Client ID", text: $clientID)
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

                Stepper(connectionsLabel, value: $numConnections, in: 1...connectionsUpperBound)
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
                    hint(ConfigValidation.wgKey(privateKey, label: "Private key", required: true))

                    TextField("Публичный ключ сервера (base64)", text: $peerPublicKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wgKey(peerPublicKey, label: "Peer public key", required: true))

                    SecureField("Preshared key (необязательно)", text: $presharedKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    hint(ConfigValidation.wgKey(presharedKey, label: "Preshared key", required: false))

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
                Button(action: handleExport) {
                    Label("Экспорт полного бэкапа…", systemImage: "square.and.arrow.up")
                }

                Button(action: { showImportPicker = true }) {
                    Label("Импорт бэкапа…", systemImage: "square.and.arrow.down")
                }

                Button(action: handleConnectionLinkPaste) {
                    Label("Импорт из ссылки…", systemImage: "link.badge.plus")
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
                Text("Бэкап содержит ключи WireGuard и креды TURN — храните файл как секрет. Ссылка vkturnproxy:// / wdtt:// / freeturn:// заполняет настройки в один тап.")
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
        .onAppear {
            if let url = connectionLinkInbox.pendingURL {
                handleConnectionLinkURL(url)
                connectionLinkInbox.pendingURL = nil
            }
        }
        .onChange(of: connectionLinkInbox.pendingURL) { newURL in
            if let url = newURL {
                handleConnectionLinkURL(url)
                connectionLinkInbox.pendingURL = nil
            }
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

    private func handleConnectionLinkURL(_ url: URL) {
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
