import SwiftUI
import WebKit
import NetworkExtension
import os.log

private let captchaLog = OSLog(subsystem: "com.vkturnproxy.app", category: "Captcha")

// MARK: - Captcha WebView (captures token via JS interception)

struct CaptchaWebView: View {
    let url: URL
    let captchaSID: String
    let onSolved: (String) -> Void
    let onDismiss: () -> Void
    let onLimitDetected: () -> Void
    let onCaptchaReady: () -> Void
    let onLog: (String) -> Void
    @ObservedObject var tunnel: TunnelManager

    // First-content-visible overlay state. Replaces the blank white WebView
    // that the user stares at while the captcha page is parsing <head> and
    // hasn't put any bytes in <body> yet — observed up to 86s on cold cache
    // in 2026-05-07 vpn-export-megafon.log (issue #5). Signal: JS heartbeat
    // posts body=N; transitioning from N==0 to N>0 means DOM has rendered
    // something. We also drop the overlay when didFinish fires, as a
    // fallback in case JS hooks didn't install.
    @State private var pageHasContent: Bool = false
    @State private var loadingStartedAt: Date = .init()
    @State private var elapsedSec: Int = 0
    private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Solve Captcha")
                    .font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
                    .font(.headline)
            }
            .padding()

            ZStack {
                CaptchaWKWebView(
                    url: url,
                    onTokenCaptured: onSolved,
                    onLimitDetected: onLimitDetected,
                    onCaptchaReady: onCaptchaReady,
                    onLog: onLog,
                    onPageLoadStarted: {
                        pageHasContent = false
                        loadingStartedAt = Date()
                        elapsedSec = 0
                    },
                    onPageContentVisible: {
                        pageHasContent = true
                    }
                )

                // Loading overlay: shown while the WebView's body is still
                // empty (cold-cache subresource fetch hangs the parser).
                // Hides as soon as DOM renders any content. Without this
                // the user just sees a blank white square for up to 90s
                // and assumes the app is broken.
                if !pageHasContent {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.3)
                        Text("Loading captcha…")
                            .font(.headline)
                        Text("\(elapsedSec)s")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .padding(32)
                    .background(Color(.systemBackground).opacity(0.97))
                    .cornerRadius(16)
                    .shadow(radius: 12)
                }

                // Overlay shown ONLY while auto-refresh is hunting for a fresh
                // captcha after JS detected "Attempt limit reached". Goes away
                // as soon as the WebView reloads to a working captcha (JS
                // posts state:ready → tunnel.onCaptchaReady → captchaLimitReached=false).
                if tunnel.captchaLimitReached {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.3)
                        Text("VK временно не отдаёт капчу")
                            .font(.headline)
                        Text("Ищем рабочую — попытка \(tunnel.captchaRefreshAttempt) из \(tunnel.maxCaptchaRefreshAttempts)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .background(Color(.systemBackground).opacity(0.97))
                    .cornerRadius(16)
                    .shadow(radius: 12)
                }
            }
            .onReceive(tickTimer) { _ in
                if !pageHasContent {
                    elapsedSec = Int(Date().timeIntervalSince(loadingStartedAt))
                }
            }
        }
    }
}

struct CaptchaWKWebView: UIViewRepresentable {
    let url: URL
    let onTokenCaptured: (String) -> Void
    // Called when JS detector concludes the loaded page is in "Attempt limit
    // reached" state (no interactive element + error text). TunnelManager
    // uses this to start the auto-refresh timer.
    let onLimitDetected: () -> Void
    // Called when JS detector sees a normal interactive captcha. TunnelManager
    // uses this to stop any running auto-refresh timer.
    let onCaptchaReady: () -> Void
    // Routes log lines from the WKWebView coordinator (which lives in the
    // main-app process) into vpn.log — so raw JS bridge messages and
    // state-transition diagnostics land in the same log file as the
    // extension's output instead of only in os_log / Console.app.
    let onLog: (String) -> Void
    // Called when a fresh main-frame navigation starts (didStartProvisional).
    // Parent uses this to reset its loading-overlay state — show the
    // "Loading captcha…" spinner and start counting elapsed time.
    let onPageLoadStarted: () -> Void
    // Called once per navigation, the first moment we observe non-empty body
    // content (heartbeat reports body>0) or didFinish fires. Parent hides
    // the loading overlay on this signal.
    let onPageContentVisible: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTokenCaptured: onTokenCaptured,
            onLimitDetected: onLimitDetected,
            onCaptchaReady: onCaptchaReady,
            onLog: onLog,
            onPageLoadStarted: onPageLoadStarted,
            onPageContentVisible: onPageContentVisible
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        // Use an ephemeral data store so every CaptchaWKWebView instance starts
        // with a clean cookie jar. VK's anti-abuse cookies otherwise persist
        // across WebView recreations and cause the captcha page to return a
        // pre-solved state ("green checkmark on open"), which leaves the user
        // stuck — JS hooks never fire because the solve flow never runs.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "captchaToken")

        // Approach based on https://github.com/cacggghp/vk-turn-proxy/pull/97:
        // Load the captcha page directly (top-level, no iframe needed).
        // Intercept fetch/XHR to captchaNotRobot.check — the response contains
        // success_token which is what VK needs for the retry.
        // No need for postMessage interception or iframe wrapper.
        let js = """
        (function() {
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captchaToken;
            if (!h) return;

            // Helper: extract whichever of device + browser_fp are non-empty
            // from a form-encoded body and post 'profile-capture:' to Swift.
            // Empirically (vpn.wifi.[1-3].log 2026-05-08): VK's
            // captchaNotRobot.componentDone body has device populated but
            // browser_fp EMPTY. browser_fp gets a real value only in the
            // captchaNotRobot.check body — so we have to intercept BOTH
            // requests and accumulate fields across them. Swift side
            // merges via VKProfileCache.update (preserves existing field
            // on empty input).
            function captureProfileFromBody(bodyStr, source) {
                try {
                    if (!bodyStr) {
                        h.postMessage('profile-capture-err:empty body (' + source + ')');
                        return;
                    }
                    var fields = [];
                    var deviceMatch = /(?:^|&)device=([^&]*)/.exec(bodyStr);
                    if (deviceMatch && deviceMatch[1].length > 0) {
                        fields.push('device=' + deviceMatch[1]);
                    }
                    var fpMatch = /(?:^|&)browser_fp=([^&]*)/.exec(bodyStr);
                    if (fpMatch && fpMatch[1].length > 0) {
                        fields.push('browser_fp=' + fpMatch[1]);
                    }
                    if (fields.length === 0) {
                        h.postMessage('profile-capture-err:both fields empty/absent in body len=' + bodyStr.length + ' (' + source + ')');
                        return;
                    }
                    fields.push('ua=' + encodeURIComponent(navigator.userAgent || ''));
                    h.postMessage('profile-capture:' + fields.join('&'));
                } catch (e) {
                    h.postMessage('profile-capture-err:' + e.message + ' (' + source + ')');
                }
            }

            // Hook fetch to intercept:
            //   - captchaNotRobot.check RESPONSE (for success_token)
            //   - captchaNotRobot.check REQUEST body (for browser_fp)
            //   - captchaNotRobot.componentDone REQUEST body (for device)
            // Profile fields accumulate on the Swift side via
            // VKProfileCache.update — componentDone gives device, check
            // gives browser_fp; merging produces a complete saved profile.
            var origFetch = window.fetch;
            window.fetch = function() {
                var url = arguments[0];
                var init = arguments[1];
                if (typeof url === 'object' && url.url) url = url.url;
                var urlStr = String(url);
                var p = origFetch.apply(this, arguments);
                if (urlStr.indexOf('captchaNotRobot.check') !== -1) {
                    captureProfileFromBody(init && init.body ? String(init.body) : '', 'fetch-check');
                    p.then(function(response) {
                        return response.clone().json();
                    }).then(function(data) {
                        h.postMessage('check:' + JSON.stringify(data).substring(0, 1000));
                        if (data.response && data.response.success_token) {
                            h.postMessage('token:' + data.response.success_token);
                        } else if (data.response && data.response.status === 'ERROR_LIMIT') {
                            // VK explicitly said "rate limited". Trigger auto-refresh
                            // immediately — don't wait for the 2.5s DOM heuristic
                            // (which would miss the limit state that only appears
                            // AFTER the user clicks the checkbox and the page
                            // dynamically switches to the error screen).
                            h.postMessage('state:limit:api_error_limit');
                        }
                    }).catch(function(e) {
                        h.postMessage('check-err:' + e.message);
                    });
                }
                if (urlStr.indexOf('captchaNotRobot.componentDone') !== -1) {
                    captureProfileFromBody(init && init.body ? String(init.body) : '', 'fetch-componentDone');
                }
                return p;
            };

            // Hook XMLHttpRequest as fallback (same triple capture as fetch).
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this._url = url;
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var xhr = this;
                var urlStr = this._url ? String(this._url) : '';
                if (urlStr.indexOf('captchaNotRobot.componentDone') !== -1) {
                    captureProfileFromBody(arguments[0] ? String(arguments[0]) : '', 'xhr-componentDone');
                }
                if (urlStr.indexOf('captchaNotRobot.check') !== -1) {
                    captureProfileFromBody(arguments[0] ? String(arguments[0]) : '', 'xhr-check');
                    xhr.addEventListener('load', function() {
                        try {
                            var data = JSON.parse(xhr.responseText);
                            h.postMessage('xhr-check:' + JSON.stringify(data).substring(0, 1000));
                            if (data.response && data.response.success_token) {
                                h.postMessage('token:' + data.response.success_token);
                            } else if (data.response && data.response.status === 'ERROR_LIMIT') {
                                // Same as fetch path: VK hard-rate-limited us,
                                // trigger auto-refresh without waiting for the
                                // DOM heuristic.
                                h.postMessage('state:limit:api_error_limit');
                            }
                        } catch(e) {}
                    });
                }
                return origSend.apply(this, arguments);
            };

            h.postMessage('init:hooks installed');

            // Page-state detector: 2.5s after first render, look at whether
            // VK showed us an interactive captcha or an "Attempt limit reached"
            // (or equivalent) error. Post state:limit / state:ready to Swift —
            // TunnelManager runs the auto-refresh timer only on state:limit.
            function checkCaptchaState(source) {
                try {
                    var text = (document.body && document.body.innerText) || '';
                    var hasLimitText = /limit.*reached|лимит.*исчерп|превышен|try\\s*again\\s*later|attempt\\s*limit/i.test(text);
                    var hasInteractive = !!document.querySelector(
                        '[role="checkbox"], input[type="checkbox"], .VkIdNotRobotButton, [data-test-id*="captcha"], .vkuiCheckbox'
                    );
                    var state;
                    if (hasLimitText) {
                        state = 'limit';
                    } else if (hasInteractive) {
                        state = 'ready';
                    } else {
                        state = 'unknown';
                    }
                    h.postMessage('state:' + state + ':' + source);
                } catch (e) {
                    h.postMessage('state-err:' + e.message);
                }
            }

            // Run initial detection once DOM is ready + a 2.5s settle.
            function scheduleInitialDetection() {
                setTimeout(function() { checkCaptchaState('initial'); }, 2500);
            }
            if (document.readyState === 'complete' || document.readyState === 'interactive') {
                scheduleInitialDetection();
            } else {
                window.addEventListener('DOMContentLoaded', scheduleInitialDetection);
            }

            // Diagnostic heartbeat: every 1s while page hasn't reached
            // 'complete', post readyState + content sizes. Diagnoses the
            // "white captcha" symptom from issue #5 — when WKWebView
            // navigates but no didFinish/didFail fires, we need to know
            // whether DOM is stuck in 'loading', sitting empty in
            // 'interactive', or what. Stops itself on 'complete' or after
            // 180s (whichever first) so it can't spam the log indefinitely.
            // The 180s cap covers the worst observed cold-cache load
            // (86s on issue #5 vpn-export-megafon.log, build 49) with
            // headroom — earlier 60s cap cut visibility short.
            (function() {
                var startTime = Date.now();
                var heartbeatId = setInterval(function() {
                    var elapsed = Date.now() - startTime;
                    var ready = document.readyState || 'null';
                    var bodyLen = (document.body && document.body.innerHTML.length) || 0;
                    var titleLen = (document.title || '').length;
                    var url = (location && location.href || '').substring(0, 80);
                    h.postMessage('heartbeat:elapsed=' + elapsed + 'ms readyState=' + ready
                        + ' body=' + bodyLen + ' title=' + titleLen + ' url=' + url);
                    if (ready === 'complete' || elapsed > 180000) {
                        clearInterval(heartbeatId);
                    }
                }, 1000);
            })();

            // Diagnostic: log per-resource timing as it completes. Reveals
            // exactly which subresource(s) hang during cold-cache slow
            // first-load (issue #5 — body=0 for 60-86s while parser is
            // blocked on a synchronous <script src>). Each fetched
            // resource gets one log line with DNS / TCP / TLS / TTFB /
            // body-bytes phases broken out — so we can tell whether the
            // bottleneck is name resolution, connection setup, or actual
            // bytes flowing slow. Stays on for the lifetime of the page;
            // overhead is one postMessage per resource (~10-30 per
            // captcha load, manageable). Query strings stripped from
            // names for log brevity, names truncated at 120 chars.
            if (typeof PerformanceObserver !== 'undefined') {
                try {
                    var po = new PerformanceObserver(function(list) {
                        list.getEntries().forEach(function(entry) {
                            if (entry.entryType !== 'resource') return;
                            var name = entry.name || '';
                            var qIdx = name.indexOf('?');
                            if (qIdx > 0) name = name.substring(0, qIdx);
                            if (name.length > 120) name = name.substring(0, 120) + '...';
                            var dns = Math.round(entry.domainLookupEnd - entry.domainLookupStart);
                            var tcp = Math.round(entry.connectEnd - entry.connectStart);
                            var tls = entry.secureConnectionStart > 0
                                ? Math.round(entry.connectEnd - entry.secureConnectionStart)
                                : 0;
                            var ttfb = Math.round(entry.responseStart - entry.requestStart);
                            var bodyMs = Math.round(entry.responseEnd - entry.responseStart);
                            var total = Math.round(entry.duration);
                            var size = entry.transferSize || 0;
                            h.postMessage('perf:' + (entry.initiatorType || '?')
                                + ' total=' + total + 'ms'
                                + ' dns=' + dns + 'ms'
                                + ' tcp=' + tcp + 'ms'
                                + ' tls=' + tls + 'ms'
                                + ' ttfb=' + ttfb + 'ms'
                                + ' bodyMs=' + bodyMs + 'ms'
                                + ' size=' + size + 'B'
                                + ' name=' + name);
                        });
                    });
                    po.observe({entryTypes: ['resource']});
                } catch (e) {
                    h.postMessage('perf-err:' + e.message);
                }
            } else {
                h.postMessage('perf-err:PerformanceObserver unavailable');
            }

            // Catch JS errors and unhandled promise rejections so we can
            // see if the page is failing on its own scripts (e.g. a
            // sub-resource referenced by VK's captcha JS that the
            // network blocks).
            window.addEventListener('error', function(e) {
                var src = (e.filename || '?');
                if (src.length > 80) src = src.substring(0, 80) + '…';
                h.postMessage('js-error:' + (e.message || 'unknown')
                    + ' at ' + src + ':' + (e.lineno || '?'));
            });
            window.addEventListener('unhandledrejection', function(e) {
                var reason = e.reason ? String(e.reason).substring(0, 200) : 'unknown';
                h.postMessage('js-rejection:' + reason);
            });
        })();
        """
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        // iOS 16.4+ no longer auto-enables Safari Web Inspector for WKWebViews
        // even in Debug builds; explicit opt-in required. Wrapped in #if DEBUG
        // so Release/TestFlight IPAs don't expose the WebView to USB-attached
        // dev tools. Enables: Mac Safari → Develop → iPhone → captcha WebView,
        // then Network tab shows the real HTTP/2 headers Safari mobile sends
        // to id.vk.ru. Needed for matching our Go-side PoW client to the
        // captured Safari fingerprint.
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        // Load captcha URL directly — no iframe needed
        context.coordinator.lastLoadedURL = url.absoluteString
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // When VK rejects a success_token and the Go side fetches a fresh
        // captcha URL, SwiftUI rebinds this view with a new `url` but keeps
        // the same underlying WKWebView alive. Without an explicit reload the
        // user sees the stale page (still showing the green checkmark from
        // the previous solve) and has no way to interact — the only escape
        // is pressing Done. Detect the URL change and reload so the new
        // captcha appears automatically.
        let newURLStr = url.absoluteString
        if context.coordinator.lastLoadedURL != newURLStr {
            context.coordinator.log("URL changed, reloading WebView (\(String(newURLStr.prefix(80))))")
            context.coordinator.lastLoadedURL = newURLStr
            context.coordinator.resetForNewCaptcha()
            uiView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onTokenCaptured: (String) -> Void
        let onLimitDetected: () -> Void
        let onCaptchaReady: () -> Void
        let onLog: (String) -> Void
        let onPageLoadStarted: () -> Void
        let onPageContentVisible: () -> Void
        private var solved = false
        // One-shot guard for onPageContentVisible — first heartbeat with
        // body>0 (or didFinish, whichever first) fires it; subsequent
        // heartbeats stay quiet. Reset on every fresh navigation.
        private var contentVisibleFired = false
        weak var webView: WKWebView?
        // Tracks which URL we last handed to `webView.load(...)`. Used by
        // updateUIView to detect real URL changes vs. SwiftUI re-renders with
        // the same state — avoids redundant reloads.
        var lastLoadedURL: String?

        init(
            onTokenCaptured: @escaping (String) -> Void,
            onLimitDetected: @escaping () -> Void,
            onCaptchaReady: @escaping () -> Void,
            onLog: @escaping (String) -> Void,
            onPageLoadStarted: @escaping () -> Void,
            onPageContentVisible: @escaping () -> Void
        ) {
            self.onTokenCaptured = onTokenCaptured
            self.onLimitDetected = onLimitDetected
            self.onCaptchaReady = onCaptchaReady
            self.onLog = onLog
            self.onPageLoadStarted = onPageLoadStarted
            self.onPageContentVisible = onPageContentVisible
        }

        func log(_ msg: String) {
            // os_log / NSLog visible in Console.app when device is connected
            // to a Mac (useful for live debugging). onLog tunnels the same
            // message through TunnelManager → extension → vpn.log so
            // post-mortem analysis from a vpn.log dump is possible too.
            os_log("%{public}s", log: captchaLog, type: .default, msg)
            NSLog("[Captcha] %@", msg)
            onLog(msg)
        }

        // Called by updateUIView when the captcha URL changes mid-flight
        // (VK rejected a success_token and Go fetched a fresh captcha).
        // Resets the one-shot `solved` guard so the next success_token from
        // the new page is forwarded to the tunnel — otherwise the guard would
        // silently swallow every token after the first. Also resets the
        // contentVisibleFired guard so the loading overlay shows again
        // for the new page.
        func resetForNewCaptcha() {
            solved = false
            contentVisibleFired = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            log("JS: \(String(body.prefix(400)))")

            // First non-empty body in a heartbeat fires onPageContentVisible
            // exactly once per navigation, dropping the loading overlay.
            // Heartbeat format: "heartbeat:elapsed=Xms readyState=Y body=N title=M url=..."
            if !contentVisibleFired && body.hasPrefix("heartbeat:") {
                if let r = body.range(of: "body=") {
                    let after = body[r.upperBound...]
                    let digits = after.prefix(while: { $0.isNumber })
                    if let n = Int(digits), n > 0 {
                        contentVisibleFired = true
                        DispatchQueue.main.async { self.onPageContentVisible() }
                    }
                }
            }

            if body.hasPrefix("token:") {
                let token = String(body.dropFirst(6))
                log("SUCCESS_TOKEN (\(token.count) chars)")
                captureToken(token)
                return
            }

            // Browser-profile capture from intercepted VK API request bodies.
            // Format: "profile-capture:[device=URLENC&][browser_fp=URLENC&]ua=URLENC".
            // device and browser_fp are OPTIONAL (each captured from a
            // different request type — componentDone has device, check has
            // browser_fp). Empty/absent fields are not overwritten on disk;
            // VKProfileCache.update merges with whatever's already saved.
            //
            // Important: device and browser_fp are stored in their RAW
            // URL-encoded form (as VK's JS originally serialized them
            // into the request body). Go-side splices them back into a
            // form-encoded body verbatim — re-encoding would double-escape.
            // Only `ua` (which we add ourselves via encodeURIComponent in
            // JS) gets percent-decoded for human-readable storage.
            if body.hasPrefix("profile-capture:") {
                let payload = String(body.dropFirst("profile-capture:".count))
                var raw: [String: String] = [:]
                for pair in payload.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        raw[String(kv[0])] = String(kv[1])
                    }
                }
                let deviceRaw = raw["device"] ?? ""
                let browserFpRaw = raw["browser_fp"] ?? ""
                let uaDecoded = (raw["ua"] ?? "").removingPercentEncoding ?? ""
                log("profile-capture received: device=\(deviceRaw.count)c browser_fp=\(browserFpRaw.count)c ua=\(uaDecoded.count)c")
                VKProfileCache.update(device: deviceRaw, browserFp: browserFpRaw, userAgent: uaDecoded)
                return
            }
            if body.hasPrefix("profile-capture-err:") {
                log("profile capture error: \(String(body.dropFirst("profile-capture-err:".count)))")
                return
            }

            // State detector posts `state:<kind>:<source>` — e.g.
            // "state:limit:initial" or "state:ready:initial". We react to
            // `limit` and `ready` kinds; `unknown` is logged for diagnostics
            // but no action taken (auto-refresh doesn't start on unknown to
            // avoid refresh loops on unrecognised layouts).
            if body.hasPrefix("state:") {
                let parts = body.split(separator: ":", maxSplits: 2).map(String.init)
                let kind = parts.count >= 2 ? parts[1] : ""
                switch kind {
                case "limit":
                    log("state=limit — delegating to auto-refresh handler")
                    DispatchQueue.main.async { self.onLimitDetected() }
                case "ready":
                    log("state=ready — delegating to stop-auto-refresh handler")
                    DispatchQueue.main.async { self.onCaptchaReady() }
                case "unknown":
                    log("state=unknown — no action (no interactive element and no known limit text)")
                default:
                    log("state=<unrecognised kind \(kind)>")
                }
                return
            }
        }

        private func captureToken(_ token: String) {
            guard !solved else { return }
            solved = true
            log("TOKEN CAPTURED (\(token.count) chars), sending to tunnel")
            DispatchQueue.main.async {
                self.onTokenCaptured(token)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                log("Nav: \(String(url.absoluteString.prefix(200)))")
            }
            decisionHandler(.allow)
        }

        // Diagnostic: confirms the request was actually sent to the server
        // (between Nav (decision) and didStartProvisional (sent on the wire)
        // there's a window where iOS could drop the request without firing
        // any other event). Added 2026-05-07 for issue #5 "white captcha"
        // diagnosis — vpn.from.github.1.log on build 48 had Nav fire then
        // 7.4s of silence with no Loaded / didFail. Need to know which
        // network-layer stage hangs.
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            log("StartProvisional: request sent on wire")
            // Fresh main-frame navigation — reset the loading overlay state
            // so the parent view shows the spinner again for this attempt.
            // Iframe / subresource navigations don't fire this delegate
            // method, so this fires exactly once per top-level captcha load.
            contentVisibleFired = false
            DispatchQueue.main.async { self.onPageLoadStarted() }
        }

        // Diagnostic: HTTP redirect mid-navigation. Logged so we can see if
        // VK is sending us through some redirect chain that hangs.
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            log("Redirect: \(String((webView.url?.absoluteString ?? "nil").prefix(200)))")
        }

        // Diagnostic: response headers received, body about to start. If
        // didCommit fires but didFinish doesn't, the body load is hanging
        // (server stops sending / TLS issue / sub-resource block). If
        // didCommit doesn't fire at all, the request is stuck before
        // headers arrived (TCP / TLS handshake / server unresponsive).
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            log("Commit: response headers received")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            log("FAIL: \(error.localizedDescription) (domain=\(nsErr.domain) code=\(nsErr.code))")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            log("FAIL provisional: \(error.localizedDescription) (domain=\(nsErr.domain) code=\(nsErr.code))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("Loaded: \(String((webView.url?.absoluteString ?? "nil").prefix(150)))")
            // Fallback: if heartbeat never reported body>0 (e.g. JS hooks
            // failed to install for some reason), at least drop the
            // loading overlay when the page fully loads.
            if !contentVisibleFired {
                contentVisibleFired = true
                DispatchQueue.main.async { self.onPageContentVisible() }
            }
        }
    }
}

