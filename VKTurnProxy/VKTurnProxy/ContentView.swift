import SwiftUI
import UIKit
import NetworkExtension
import WebKit
import UniformTypeIdentifiers
import os.log

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()

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

    @State private var pulse = false

    private var configValidationError: String? {
        var issues: [ConfigValidation.Issue?] = [
            ConfigValidation.vkLink(vkLink),
            ConfigValidation.peerAddress(peerAddress),
            ConfigValidation.turnOverride(turnServerOverride),
        ]
        if useWrapA {
            issues.append(ConfigValidation.wrapAPassword(wrapAPassword))
        } else {
            issues.append(ConfigValidation.wgKey(privateKey, label: "Private key", required: true))
            issues.append(ConfigValidation.wgKey(peerPublicKey, label: "Peer public key", required: true))
            issues.append(ConfigValidation.wgKey(presharedKey, label: "Preshared key", required: false))
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
        case .connecting, .reasserting: return AppTheme.warning
        case .disconnecting: return AppTheme.warning.opacity(0.8)
        default: return Color.white.opacity(0.35)
        }
    }

    private var statusTitle: String {
        if tunnel.preBootstrapInProgress { return "Подготовка…" }
        switch tunnel.status {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        case .disconnected: return "Не подключено"
        case .invalid: return "Ошибка конфигурации"
        @unknown default: return "Неизвестно"
        }
    }

    private var statusSubtitle: String {
        if let err = tunnel.errorMessage, !err.isEmpty { return err }
        if !isActive, let v = configValidationError {
            return v
        }
        if tunnel.status == .connected {
            return "Туннель активен · \(currentModeLabel)"
        }
        if isBusy {
            return "Устанавливаем соединения через TURN…"
        }
        if configValidationError == nil {
            return "Нажмите, чтобы подключиться"
        }
        return "Заполните настройки, чтобы подключиться"
    }

    private var currentModeLabel: String {
        if useWrapS { return ServerMode.srtpWrapS.label }
        if useWrapA { return ServerMode.srtpWrapA.label }
        if useSrtp { return ServerMode.srtp.label }
        if useWrap { return ServerMode.srtpWrap.label }
        return ServerMode.legacy.label
    }

    private var backgroundGradient: LinearGradient {
        if tunnel.status == .connected { return AppTheme.connectedGradient }
        if isBusy { return AppTheme.connectingGradient }
        return AppTheme.idleGradient
    }

    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: tunnel.status)

                // Soft glow blobs
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .frame(width: 320, height: 320)
                    .blur(radius: 60)
                    .offset(y: -40)
                    .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {
                        headerBar
                        statusBlock
                        connectControl
                        if tunnel.status == .connected {
                            StatsView(tunnel: tunnel)
                                .padding(.horizontal, 4)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            setupHints
                        }
                        bottomActions
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $tunnel.captchaPending) {
                if let urlStr = tunnel.captchaImageURL, let url = URL(string: urlStr) {
                    CaptchaWebView(
                        url: url,
                        captchaSID: tunnel.captchaSID ?? "",
                        onSolved: { token in
                            NSLog("[Captcha] Token received (%d chars), sending to tunnel", token.count)
                            tunnel.solveCaptcha(answer: token)
                        },
                        onDismiss: {
                            NSLog("[Captcha] Sheet dismissed without token")
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
                VKAuthWebView { result in
                    tunnel.onVKLoginResult(result)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Orbit")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text("TURN · WireGuard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            HStack(spacing: 10) {
                NavigationLink {
                    LogsView(tunnel: tunnel)
                } label: {
                    Image(systemName: "doc.text")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.08), in: Circle())
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Status

    private var statusBlock: some View {
        VStack(spacing: 10) {
            Text(statusTitle)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .animation(.easeInOut(duration: 0.25), value: statusTitle)

            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - Connect button

    private var connectControl: some View {
        Button(action: toggleConnection) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(statusColor.opacity(0.25), lineWidth: 14)
                    .frame(width: 196, height: 196)
                    .scaleEffect(pulse && isBusy ? 1.06 : 1.0)

                Circle()
                    .trim(from: 0, to: isBusy ? 0.72 : 1)
                    .stroke(
                        AngularGradient(
                            colors: [statusColor.opacity(0.2), statusColor, statusColor.opacity(0.2)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 196, height: 196)
                    .rotationEffect(.degrees(isBusy ? 360 : 0))
                    .animation(
                        isBusy
                            ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                            : .default,
                        value: isBusy
                    )

                // Core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                statusColor.opacity(isActive ? 0.55 : 0.28),
                                Color.white.opacity(0.06)
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 90
                        )
                    )
                    .frame(width: 168, height: 168)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: statusColor.opacity(0.45), radius: isActive ? 28 : 12)

                VStack(spacing: 8) {
                    Image(systemName: isActive ? "stop.fill" : "power")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(isActive ? "Отключить" : "Подключить")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isActive && configValidationError != nil)
        .opacity(!isActive && configValidationError != nil ? 0.45 : 1)
        .padding(.vertical, 8)
        .accessibilityLabel(isActive ? "Отключить" : "Подключить")
    }

    // MARK: - Setup hints

    private var setupHints: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Быстрый старт")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 4)

            hintRow(
                done: !vkLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                title: "Ссылка VK‑звонка",
                detail: "https://vk.ru/call/join/…"
            )
            hintRow(
                done: !peerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                title: "Адрес прокси‑сервера",
                detail: "IP:порт (параметр -listen на сервере)"
            )
            if !useWrapA {
                hintRow(
                    done: !privateKey.isEmpty && !peerPublicKey.isEmpty,
                    title: "Ключи WireGuard",
                    detail: "Приватный ключ клиента и публичный ключ сервера"
                )
            } else {
                hintRow(
                    done: !wrapAPassword.isEmpty,
                    title: "Пароль сервера (WRAP‑A)",
                    detail: "Главный пароль туннеля WDTT"
                )
            }

            NavigationLink {
                SettingsView()
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Открыть настройки")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [AppTheme.accent.opacity(0.35), AppTheme.accentDeep.opacity(0.45)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .padding(.top, 4)
        }
    }

    private func hintRow(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AppTheme.success : .white.opacity(0.35))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Bottom

    private var bottomActions: some View {
        HStack(spacing: 12) {
            infoChip(icon: "antenna.radiowaves.left.and.right", text: currentModeLabel)
            infoChip(icon: "link", text: "\(numConnections) соед.")
            infoChip(icon: useUDP ? "wifi" : "network", text: useUDP ? "UDP" : "TCP")
        }
        .padding(.top, 4)
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.06), in: Capsule())
    }

    // MARK: - Actions

    private func parseTurnOverride(_ s: String) -> (host: String, port: String)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let colon = t.lastIndex(of: ":") else { return nil }
        let host = String(t[..<colon])
        let port = String(t[t.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber), Int(port) != nil else {
            return nil
        }
        return (host, port)
    }

    private func toggleConnection() {
        if isActive {
            NSLog("[UI] user pressed Disconnect button (status=\(tunnel.status.rawValue))")
            SharedLogger.shared.log("[UI] user pressed Disconnect button (status=\(tunnel.status.rawValue))")
            tunnel.disconnect()
            return
        }

        NSLog("[UI] user pressed Connect button (status=\(tunnel.status.rawValue))")
        SharedLogger.shared.log("[UI] user pressed Connect button (status=\(tunnel.status.rawValue))")
        let turnOv = parseTurnOverride(turnServerOverride)
        let vkLines = vkLink.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let vkAuthOn = UserDefaults.standard.bool(forKey: "VKAuth")
        let effectiveConns = vkAuthOn
            ? min(numConnections, min(50, max(2, vkLines.count * 20)))
            : numConnections
        let config = TunnelConfig(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            presharedKey: presharedKey.isEmpty ? nil : presharedKey,
            tunnelAddress: tunnelAddress,
            dnsServers: dnsServers,
            allowedIPs: allowedIPs,
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
            useCookieAuth: UserDefaults.standard.bool(forKey: "VKAuth"),
            numConnections: effectiveConns,
            credPoolCooldownSeconds: credPoolCooldownSeconds,
            turnServerOverride: turnOv?.host,
            turnPortOverride: turnOv?.port
        )
        Task {
            await tunnel.connect(config: config)
        }
    }
}

#Preview {
    ContentView()
}
