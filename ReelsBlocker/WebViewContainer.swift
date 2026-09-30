import SwiftUI
import UIKit
import WebKit

/// WKWebView sobre instagram.com con sesión persistente y scripts de bloqueo.
struct WebViewContainer: UIViewRepresentable {
    let browser: BrowserModel
    let initialConfig: ScriptConfig

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(browser: browser)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Almacén persistente: cookies y sesión sobreviven a cerrar la app.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = Self.safariApplicationName

        let controller = WKUserContentController()
        for script in ScriptBuilder.userScripts(for: initialConfig) {
            controller.addUserScript(script)
        }
        controller.add(WeakScriptMessageHandler(context.coordinator), name: ScriptBuilder.messageHandlerName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true // Safari → Desarrollo → [iPhone]

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(WebViewCoordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        browser.attach(webView, config: initialConfig)
        context.coordinator.startObserving(webView)
        webView.load(URLRequest(url: BrowserModel.homeURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Los cambios de reglas llegan por BrowserModel.apply(_:).
    }

    /// El UA por defecto de WKWebView acaba en "Mobile/15E148". Instagram lo trata
    /// mejor si parece Safari, así que se añade "Version/X.Y ... Safari/604.1".
    private static var safariApplicationName: String {
        let parts = UIDevice.current.systemVersion.split(separator: ".")
        let major = parts.first.map(String.init) ?? "17"
        let minor = parts.count > 1 ? String(parts[1]) : "0"
        return "Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }
}

/// WKUserContentController retiene fuerte a su handler; este proxy evita el ciclo.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
