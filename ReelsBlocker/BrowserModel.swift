import Foundation
import Observation
import WebKit

/// Estado del navegador compartido entre la vista web, la barra inferior y el
/// panel de depuración. Todo se usa desde el hilo principal.
@Observable
final class BrowserModel {
    static let homeURL = URL(string: "https://www.instagram.com/")!

    var currentURL: URL?
    var canGoBack = false
    var isLoading = false
    /// Elementos ocultados por blocker.js en la página actual.
    var hiddenCount = 0
    var reelLockActive = false
    /// Última ruta prohibida que se ha interceptado (JS o Swift).
    var lastBlockedPath: String?
    var blockedCount = 0

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var policy = PathPolicy(ScriptConfig(enabled: true, rules: Rules()))

    func attach(_ webView: WKWebView, config: ScriptConfig) {
        self.webView = webView
        policy = PathPolicy(config)
    }

    func didBlock(path: String) {
        lastBlockedPath = path
        blockedCount += 1
    }

    // MARK: - Navegación

    func goHome() { load(BrowserModel.homeURL) }

    func open(path: String) {
        guard let url = URL(string: path, relativeTo: BrowserModel.homeURL) else { return }
        load(url)
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        webView.goBack()
    }

    func reload() { webView?.reload() }

    /// Recarga ignorando la caché.
    func hardReload() { webView?.reloadFromOrigin() }

    private func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    // MARK: - Reglas

    /// Sustituye los scripts para próximas cargas y actualiza la página actual en caliente.
    func apply(_ config: ScriptConfig) {
        policy = PathPolicy(config)
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in ScriptBuilder.userScripts(for: config) {
            controller.addUserScript(script)
        }
        webView.evaluateJavaScript(ScriptBuilder.liveUpdateScript(for: config), completionHandler: nil)
    }

    /// Resalta en la página lo que casa con `selector` y devuelve un resumen legible.
    func testSelector(_ selector: String, completion: @escaping (String) -> Void) {
        guard let webView else {
            completion("No hay página cargada")
            return
        }
        webView.evaluateJavaScript(ScriptBuilder.testSelectorScript(selector)) { result, error in
            if let error {
                completion("Error: \(error.localizedDescription)")
                return
            }
            guard let dict = result as? [String: Any] else {
                completion("Sin respuesta")
                return
            }
            if (dict["ok"] as? Bool) == true {
                let count = (dict["count"] as? NSNumber)?.intValue ?? 0
                completion(count == 1 ? "1 coincidencia (resaltada en rojo 3 s)" : "\(count) coincidencias (resaltadas en rojo 3 s)")
            } else {
                completion("Selector inválido: \(dict["error"] as? String ?? "?")")
            }
        }
    }
}
