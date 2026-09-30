import Foundation
import WebKit

/// Genera los WKUserScript a partir de las reglas. La lógica vive en
/// Resources/blocker.js; aquí solo se le pasa la configuración.
enum ScriptBuilder {
    /// Nombre del WKScriptMessageHandler (window.webkit.messageHandlers.rb).
    static let messageHandlerName = "rb"

    static let blockerSource: String = {
        guard let url = Bundle.main.url(forResource: "blocker", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return source
    }()

    static var isBlockerMissing: Bool { blockerSource.isEmpty }

    static func configJSON(_ config: ScriptConfig) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return "{\"enabled\":false,\"rules\":{}}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Un literal de string JS seguro (JSON es un subconjunto de JS).
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    static func userScripts(for config: ScriptConfig) -> [WKUserScript] {
        let json = configJSON(config)

        // 1. Antes de parsear el documento: CSS + guardia de rutas. Evita el flash.
        let start = """
        window.__RB_CONFIG = \(json);
        \(blockerSource)
        window.__rb && window.__rb.start();
        """

        // 2. Al terminar de cargar: MutationObserver y ocultación por JS.
        //    Si el primer script falló, este vuelve a intentarlo entero.
        let end = """
        window.__RB_CONFIG = window.__RB_CONFIG || \(json);
        \(blockerSource)
        if (window.__rb) { window.__rb.start(); window.__rb.ready(); }
        """

        return [
            WKUserScript(source: start, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: end, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
        ]
    }

    /// Aplica una configuración nueva a la página ya cargada, sin recargar.
    static func liveUpdateScript(for config: ScriptConfig) -> String {
        "window.__rb && window.__rb.update(\(configJSON(config))); true;"
    }

    static func testSelectorScript(_ selector: String) -> String {
        "window.__rb ? window.__rb.test(\(jsString(selector))) : {ok: false, error: 'blocker.js no está cargado'};"
    }
}
