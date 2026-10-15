// Rune Weaver App — Native macOS Settings Window Controller.
// Hosts an isolated WebKit view for Settings with strict breakout containment.

import AppKit
import Foundation
import RuneWeaverServer
import WebKit

@MainActor
public final class SettingsWindowController: NSObject {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var allowedBaseURL: URL?

    override private init() {
        super.init()
    }

    /// Displays the native settings window, loading the standalone settings URL.
    /// When a session token is provided, injects the `rw_session` cookie into
    /// the WebKit cookie store prior to navigation so the settings view is
    /// pre-authenticated without prompting for the owner bearer token. The
    /// cookie carries the same sliding idle lifetime the server enforces, so the
    /// native window and the browser dashboard cannot drift on when a session
    /// goes dead or on the deadline the browser should honor.
    public func show(url: URL, sessionToken: String? = nil) async {
        self.allowedBaseURL = url
        let win = getOrCreateWindow()

        if let sessionToken, let webView = self.webView {
            let cookieProps: [HTTPCookiePropertyKey: Any] = [
                .domain: url.host ?? "127.0.0.1",
                .path: "/",
                .name: ServerAuthRequest.sessionCookieName,
                .value: sessionToken,
                .secure: url.scheme == "https" ? "TRUE" : "FALSE",
                .expires: Date().addingTimeInterval(ServerAuth.sessionIdleTimeoutSeconds)
            ]
            if let cookie = HTTPCookie(properties: cookieProps) {
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }

        if webView?.url != url {
            webView?.load(URLRequest(url: url))
        } else if sessionToken != nil {
            webView?.reload()
        }

        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func getOrCreateWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let configuredWebView = WKWebView(frame: .zero, configuration: config)
        configuredWebView.navigationDelegate = self
        configuredWebView.allowsBackForwardNavigationGestures = false

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let initialRect = NSRect(x: 0, y: 0, width: 960, height: 720)
        let settingsWindow = NSWindow(contentRect: initialRect, styleMask: styleMask, backing: .buffered, defer: false)
        settingsWindow.title = "Settings"
        settingsWindow.minSize = NSSize(width: 820, height: 550)
        settingsWindow.setFrameAutosaveName("RuneWeaverSettingsWindow")
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.contentView = configuredWebView

        // Center on screen if no saved frame exists
        if !settingsWindow.setFrameUsingName("RuneWeaverSettingsWindow") {
            settingsWindow.center()
        }

        self.webView = configuredWebView
        self.window = settingsWindow
        return settingsWindow
    }
}

// MARK: - WKNavigationDelegate (Breakout Containment)

extension SettingsWindowController: WKNavigationDelegate {
    public func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let requestURL = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Subresource loads (scripts, styles, api, images) are permitted
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }

        // Check if destination belongs to our local server
        if let allowed = allowedBaseURL,
           requestURL.scheme == allowed.scheme,
           requestURL.host == allowed.host,
           requestURL.port == allowed.port
        {
            // Allow initial navigation or standalone settings routes
            let query = requestURL.query ?? ""
            let fragment = requestURL.fragment ?? ""
            if query.contains("standalone=true") || fragment.contains("standalone=true") || requestURL.path.hasPrefix("/assets") {
                decisionHandler(.allow)
                return
            }

            // Any other same-origin main-frame navigation (including other
            // internal dashboard routes such as #chat without the standalone
            // gate, which forces the SettingsManager-only surface) is
            // cancelled here to keep the window contained to Settings.
            decisionHandler(.cancel)
            return
        }

        // External URLs (documentation, API links, etc.): open in default web browser
        if let scheme = requestURL.scheme, scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(requestURL)
        }

        decisionHandler(.cancel)
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    public func windowWillClose(_: Notification) {
        // Window is hidden and retained for fast re-opening
    }
}
