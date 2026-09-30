import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = RuleStore()
    @State private var browser = BrowserModel()
    @State private var showDebug = false

    var body: some View {
        VStack(spacing: 0) {
            WebViewContainer(browser: browser, initialConfig: store.scriptConfig)
            BottomBar(browser: browser) { showDebug = true }
        }
        .onChange(of: store.scriptConfig) { _, config in
            browser.apply(config)
        }
        .sheet(isPresented: $showDebug) {
            DebugPanel(store: store, browser: browser)
        }
    }
}

/// Barra mínima: atrás, inicio, buscar y mensajes. La esquina derecha, con una
/// pulsación larga de 2 s, abre el panel de depuración.
private struct BottomBar: View {
    let browser: BrowserModel
    let onDebug: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.backward", "Atrás") { browser.goBack() }
                .disabled(!browser.canGoBack)
            button("house", "Inicio") { browser.goHome() }
            button("magnifyingglass", "Buscar") { browser.open(path: "/explore/search/") }
            button("paperplane", "Mensajes") { browser.open(path: "/direct/inbox/") }
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 2) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDebug()
                }
                .accessibilityLabel("Panel de depuración")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.bar)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
