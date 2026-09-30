import SwiftUI
import UIKit
import WebKit

/// Decide qué rutas de instagram.com están prohibidas.
/// Misma lógica que isBlockedPath() en blocker.js.
struct PathPolicy {
    var enabled: Bool
    var blockedPrefixes: [String]
    var allowedPrefixes: [String]
    var singleReel: NSRegularExpression?

    init(_ config: ScriptConfig) {
        enabled = config.enabled
        blockedPrefixes = config.rules.blockedPathPrefixes
        allowedPrefixes = config.rules.allowedPathPrefixes
        singleReel = config.rules.lockScrollOnReelView
            ? try? NSRegularExpression(pattern: config.rules.singleReelPathPattern)
            : nil
    }

    func isSingleReel(_ path: String) -> Bool {
        guard let singleReel else { return false }
        return singleReel.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    func isBlocked(_ path: String) -> Bool {
        guard enabled, !path.isEmpty else { return false }
        if allowedPrefixes.contains(where: { Self.matches(path, $0) }) { return false }
        if isSingleReel(path) { return false }
        return blockedPrefixes.contains { Self.matches(path, $0) }
    }

    /// "/reels/" también cubre "/reels".
    private static func matches(_ path: String, _ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return path.hasPrefix(prefix) || (prefix.hasSuffix("/") && path == String(prefix.dropLast()))
    }

    // MARK: - Hosts

    static func isInstagram(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    /// Dominios que se cargan dentro de la app (login con Facebook, centro de cuentas…).
    /// Todo lo demás se abre en Safari.
    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domains = ["instagram.com", "facebook.com", "meta.com", "fbcdn.net", "cdninstagram.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Delegado del WKWebView: guardia de navegación, bridge JS → Swift y diálogos.
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let browser: BrowserModel
    private var observations: [NSKeyValueObservation] = []

    init(browser: BrowserModel) {
        self.browser = browser
    }

    /// Observa la URL del WKWebView: cambia también con pushState, así que esto
    /// es una segunda red de seguridad para la navegación SPA aunque el JS falle.
    func startObserving(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                self?.urlDidChange(webView)
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                self?.browser.canGoBack = webView.canGoBack
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                self?.browser.isLoading = webView.isLoading
            },
        ]
    }

    private func urlDidChange(_ webView: WKWebView) {
        guard let url = webView.url else { return }
        browser.currentURL = url
        if PathPolicy.isInstagram(url), browser.policy.isBlocked(url.path) {
            browser.didBlock(path: url.path)
            webView.stopLoading()
            webView.load(URLRequest(url: BrowserModel.homeURL))
        }
    }

    @objc func handleRefresh(_ sender: UIRefreshControl) {
        browser.reload()
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        switch scheme {
        case "http", "https":
            break
        case "about", "blob", "data", "javascript":
            decisionHandler(.allow)
            return
        case "instagram", "fb", "itms-apps", "itms-appss":
            // Intentos de saltar a la app nativa o a la App Store: se ignoran.
            decisionHandler(.cancel)
            return
        default:
            // mailto:, tel:, sms:…
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        guard isMainFrame else {
            decisionHandler(.allow)
            return
        }

        if PathPolicy.isInstagram(url), browser.policy.isBlocked(url.path) {
            browser.didBlock(path: url.path)
            decisionHandler(.cancel)
            webView.load(URLRequest(url: BrowserModel.homeURL))
            return
        }

        if !PathPolicy.isInternal(url) {
            // Enlaces externos (incluido lo que redirige l.instagram.com) → Safari.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // _WKNavigationActionPolicyAllowWithoutTryingAppLink (= .allow + 2):
        // evita que un enlace universal de instagram.com abra la app oficial.
        // API privada; aceptable en una app que no pasa por App Store.
        let allowWithoutAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
        decisionHandler(allowWithoutAppLink)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ScriptBuilder.messageHandlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

        switch type {
        case "route":
            if let href = body["href"] as? String, let url = URL(string: href) {
                browser.currentURL = url
            }
        case "blocked", "reelSwipeBlocked":
            if let path = body["path"] as? String {
                browser.didBlock(path: path)
            }
        case "stats":
            browser.hiddenCount = (body["hidden"] as? NSNumber)?.intValue ?? 0
            browser.reelLockActive = (body["reelLock"] as? Bool) ?? false
        default:
            break
        }
    }

    // MARK: - WKUIDelegate

    /// target="_blank" y window.open: dentro de la app si es Instagram, si no a Safari.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if PathPolicy.isInternal(url) {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, from: webView, orElse: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler(true) })
        present(alert, from: webView) { completionHandler(false) }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    private func present(_ alert: UIAlertController, from webView: WKWebView, orElse fallback: () -> Void) {
        var top = webView.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else {
            fallback()
            return
        }
        top.present(alert, animated: true)
    }
}
