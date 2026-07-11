import SwiftUI
import UniformTypeIdentifiers

// MARK: - Logs View

struct LogsView: View {
    @ObservedObject var tunnel: TunnelManager
    @State private var logText = ""
    @State private var autoScroll = true
    @State private var showShareSheet = false
    @State private var usingOSLogFallback = false
    // Cached fallback content + last-fetch timestamp + in-flight guard.
    // Without these the fallback path (OSLogReader.readOwnLogs +
    // sendProviderMessage) ran on EVERY 2-second timer tick whenever the
    // file was empty, blocking the main thread on the synchronous
    // OSLogStore query for hundreds of milliseconds-to-seconds depending
    // on ring-buffer size. Symptom: tapping "Clear" emptied the file,
    // then the UI lagged badly because every tick re-ran the heavy
    // fallback query. With caching: query runs at most once per
    // fallbackTTL seconds, off the main thread.
    @State private var fallbackText: String = ""
    @State private var fallbackFetchedAt: Date = .distantPast
    @State private var fallbackInFlight = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let fallbackTTL: TimeInterval = 4.0

    /// Maximum characters to display — keeps UI responsive.
    /// The full file is still available via Share.
    private let maxDisplayChars = 100_000

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(text: logText, autoScroll: autoScroll)

            Divider()

            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .fixedSize()

                Spacer()

                Button(action: {
                    SharedLogger.shared.clearLogs()
                    // Wipe the fallback cache too — otherwise after
                    // clearing the on-disk log the next loadLogs() tick
                    // would still show the stale cached fallback content
                    // until the TTL elapses, which looks like Clear
                    // didn't work.
                    fallbackText = ""
                    fallbackFetchedAt = .distantPast
                    logText = ""
                }) {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }

                Button(action: { showShareSheet = true }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("Логи")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .onAppear { loadLogs() }
        .onReceive(timer) { _ in loadLogs() }
        .sheet(isPresented: $showShareSheet) {
            // Export the COMBINED log (archive .1 + current) as a single
            // temp file so the user gets the full history, not just the
            // tail since the last rotation. If SharedLogger is empty
            // (App Group unavailable), Share the os_log fallback text
            // by writing it to a temp file first so the user can still
            // attach a log file to a bug report.
            if let url = exportShareableLogURL(),
               FileManager.default.fileExists(atPath: url.path) {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func loadLogs() {
        let fileText = SharedLogger.shared.readLogs()
        if !fileText.isEmpty {
            usingOSLogFallback = false
            logText = truncated(fileText)
            return
        }
        // Empty result. Distinguish "intentionally empty" (Clear was
        // pressed, or extension just rotated/started) from "broken"
        // (App Group container unreachable, or the file never existed).
        // The first case is normal user state — Clear is used routinely
        // — and showing a fallback banner there surprises the user with
        // os_log content unrelated to the fresh-start they just asked
        // for. Only fall back when the file storage itself is missing.
        let status = SharedLogger.shared.inspectStorage()
        if status.hasContainer && status.currentExists {
            usingOSLogFallback = false
            // Wipe stale fallback cache so a subsequent failure path
            // doesn't render leftover content.
            fallbackText = ""
            fallbackFetchedAt = .distantPast
            // DIAGNOSTIC (build 154): surface the storage facts inline so we
            // can see WHY the file reads empty — truly 0 bytes vs path skew —
            // and compare the container path with the extension's
            // "wgSetLogFilePath: <path>" line in os_log (USB syslog). A
            // mismatch means the main app and the PacketTunnel extension
            // resolved DIFFERENT App Group containers (provisioning skew), so
            // the extension's writes never reach the file the app reads.
            logText = "(log is empty — waiting for new activity)\n\n" +
                "[logdiag] container = \(status.containerPath)\n" +
                "[logdiag] vpn.log   exists=\(status.currentExists) bytes=\(status.currentBytes)\n" +
                "[logdiag] vpn.log.1 exists=\(status.archivedExists) bytes=\(status.archivedBytes)"
            return
        }

        // Genuine fallback: no container (entitlement / provisioning
        // issue) or file never existed (fresh install before any
        // SharedLogger.log call landed). Read per-process os_log: main
        // app reads its own ring buffer, extension reads its own via
        // providerMessage. Surface a banner explaining the source.
        //
        // Both the OSLogStore query and the providerMessage round-trip
        // can take hundreds of milliseconds each — running them on every
        // 2-second timer tick on the main thread caused noticeable UI
        // lag. So: cache the result for `fallbackTTL` seconds, refresh
        // in a background task, and only one fetch may be in flight at
        // a time.
        usingOSLogFallback = true

        // Show last-cached content immediately if we have any; otherwise
        // a minimal placeholder so the user knows fetching is in progress.
        if !fallbackText.isEmpty {
            logText = truncated(fallbackText)
        } else if logText.isEmpty {
            logText = "Loading os_log fallback…"
        }

        let cacheStale = Date().timeIntervalSince(fallbackFetchedAt) > fallbackTTL
        guard !fallbackInFlight && cacheStale else { return }
        fallbackInFlight = true

        Task.detached(priority: .userInitiated) {
            // OSLogReader.readOwnLogs is the heavy synchronous call —
            // running it on a detached task moves it off the main thread.
            // Subsequent awaits (providerMessage, MainActor.run) come
            // back to MainActor naturally because tunnel is @MainActor.
            let mainAppLogs = OSLogReader.readOwnLogs(maxAge: 1800)
            let extensionLogs = await tunnel.fetchExtensionOSLogs() ?? ""

            // Pick a precise banner reason from SharedLogger storage state
            // instead of conflating "container unavailable" with "file empty"
            // and "file unreadable" — each has a different cause and remedy.
            // Also include container path so the reader can compare with
            // wgSetLogFilePath in the extension's os_log output (mismatching
            // paths would indicate a provisioning/entitlement skew between
            // main app and extension processes).
            let status = SharedLogger.shared.inspectStorage()
            let reason: String
            if !status.hasContainer {
                reason = "App Group container unavailable to main app (entitlement missing or provisioning issue)"
            } else if !status.currentExists && !status.archivedExists {
                reason = "Log file doesn't exist yet at \(status.containerPath)/vpn.log (fresh install or container reset)"
            } else if status.currentBytes == 0 && status.archivedBytes <= 0 {
                reason = "Log file is empty (\(status.containerPath)/vpn.log: 0 bytes; recently cleared, or extension hasn't written since clear)"
            } else if status.currentBytes < 0 {
                reason = "Log file unreadable despite existing (\(status.containerPath)/vpn.log; permissions / corruption?)"
            } else {
                reason = "Log file present but readLogs returned empty (current=\(status.currentBytes)B, archived=\(status.archivedBytes)B at \(status.containerPath))"
            }

            var combined = mainAppLogs + extensionLogs
            if combined.isEmpty {
                combined = "No logs available.\n\nReason: \(reason)\n\n" +
                    "Try reconnecting the tunnel, or — if the issue persists — " +
                    "Reset TURN Cache and reconnect to force a fresh log session."
            } else {
                combined = "⚠️ Showing os_log fallback (recent ~30 min only, " +
                    "may be incomplete and out of order).\n" +
                    "Reason: \(reason)\n\n" +
                    combined
            }

            await MainActor.run {
                fallbackText = combined
                fallbackFetchedAt = Date()
                fallbackInFlight = false
                if usingOSLogFallback {
                    logText = truncated(combined)
                }
            }
        }
    }

    private func truncated(_ text: String) -> String {
        guard text.count > maxDisplayChars else { return text }
        let startIndex = text.index(text.endIndex, offsetBy: -maxDisplayChars)
        return "… (truncated)\n" + String(text[startIndex...])
    }

    /// Decide what URL to hand to the Share sheet. Default path: the
    /// file-backed export (archive + current). Fallback path: write
    /// the current `logText` (which is the os_log fallback view) to
    /// a temp file so the user can still attach a log to a bug report
    /// even when the App Group file is empty.
    private func exportShareableLogURL() -> URL? {
        if let url = SharedLogger.shared.exportSnapshotURL(),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 0 {
            return url
        }
        // SharedLogger empty — write the on-screen fallback text to a
        // temp file so Share has something to attach.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-export-oslog.log")
        try? logText.write(to: tmp, atomically: true, encoding: .utf8)
        return FileManager.default.fileExists(atPath: tmp.path) ? tmp : nil
    }
}

/// UITextView wrapper — handles large text without SwiftUI layout explosion.
struct LogTextView: UIViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textColor = .label
        tv.backgroundColor = .systemBackground
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Only update if text actually changed to avoid unnecessary work
        if tv.text != text {
            tv.text = text
            if autoScroll && !text.isEmpty {
                let bottom = NSRange(location: text.count - 1, length: 1)
                tv.scrollRangeToVisible(bottom)
            }
        }
    }
}

/// UIActivityViewController wrapper for sharing the log file.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

