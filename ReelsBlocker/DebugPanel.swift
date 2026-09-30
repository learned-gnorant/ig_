import SwiftUI
import UIKit

/// Panel oculto (pulsación larga de 2 s en la esquina inferior derecha).
/// Sirve para encontrar selectores nuevos desde el teléfono cuando Meta cambie algo.
struct DebugPanel: View {
    let store: RuleStore
    let browser: BrowserModel

    @Environment(\.dismiss) private var dismiss
    @State private var candidate = ""
    @State private var candidateAncestors = 2
    @State private var testResult: String?
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                actionsSection
                generalSection
                testSection
                selectorsSection
                if !store.customSelectors.isEmpty { customSection }
                pathsSection
                maintenanceSection
            }
            .navigationTitle("Depuración")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    // MARK: - Secciones

    private var statusSection: some View {
        Section("Estado") {
            VStack(alignment: .leading, spacing: 4) {
                Text("URL actual").font(.caption).foregroundStyle(.secondary)
                Text(browser.currentURL?.absoluteString ?? "—")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Button("Copiar URL") { copy(browser.currentURL?.absoluteString ?? "", label: "URL") }
            LabeledContent("Elementos ocultos", value: "\(browser.hiddenCount)")
            LabeledContent("Reel fijado", value: browser.reelLockActive ? "Sí" : "No")
            LabeledContent("Rutas bloqueadas (sesión)", value: "\(browser.blockedCount)")
            if let path = browser.lastBlockedPath {
                LabeledContent("Última bloqueada") { Text(path).font(.footnote.monospaced()) }
            }
            LabeledContent("rules.json", value: "v\(store.base.version)")
            if let error = store.loadError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if ScriptBuilder.isBlockerMissing {
                Text("blocker.js no está en el bundle: solo funciona el bloqueo de rutas.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Recargar") { browser.reload() }
            Button("Recarga forzada (sin caché)") { browser.hardReload() }
            Button("Ir a inicio") {
                browser.goHome()
                dismiss()
            }
        }
    }

    private var generalSection: some View {
        Section {
            Toggle("Bloqueo activo", isOn: binding(\.isEnabled))
            Toggle("Fijar reel individual (sin deslizar)", isOn: binding(\.lockScrollOnReelView))
            Toggle("Ocultar publicidad", isOn: binding(\.hideSponsored))
        } footer: {
            Text("Con “Bloqueo activo” apagado la app es Instagram web sin filtros.")
        }
    }

    private var testSection: some View {
        Section {
            TextField("a[href='/reels/']", text: $candidate, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Stepper("Subir \(candidateAncestors) niveles al ocultar", value: $candidateAncestors, in: 0...8)
            HStack {
                Button("Resaltar") {
                    browser.testSelector(candidate) { testResult = $0 }
                }
                Spacer()
                Button("Ocultar y guardar") {
                    let ancestors = candidateAncestors == store.base.hideAncestorLevels ? nil : candidateAncestors
                    testResult = store.addCustomSelector(candidate, ancestors: ancestors)
                        ? "Guardado. Se aplica ya y en cada arranque."
                        : "Vacío o ya existe."
                }
            }
            .buttonStyle(.borderless)
            .disabled(candidate.trimmingCharacters(in: .whitespaces).isEmpty)
            if let testResult {
                Text(testResult).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Probar selector en caliente")
        } footer: {
            Text("Prioridad: href › aria-label (en inglés y español) › role. Nunca clases: Meta las rota.")
        }
    }

    private var selectorsSection: some View {
        Section("Selectores (rules.json)") {
            ForEach(store.base.hideSelectors) { rule in
                selectorToggle(rule)
            }
        }
    }

    private var customSection: some View {
        Section {
            ForEach(store.customSelectors) { rule in
                selectorToggle(rule)
            }
            .onDelete { offsets in
                offsets.map { store.customSelectors[$0].selector }.forEach(store.removeCustomSelector)
            }
        } header: {
            Text("Selectores añadidos aquí")
        } footer: {
            Text("Desliza para borrar. Pásalos a rules.json con “Copiar reglas como JSON”.")
        }
    }

    private var pathsSection: some View {
        Section {
            ForEach(store.base.blockedPathPrefixes, id: \.self) { prefix in
                Toggle(isOn: Binding(
                    get: { store.isPathPrefixEnabled(prefix) },
                    set: { store.setPathPrefix(prefix, enabled: $0) }
                )) {
                    Text(prefix).font(.footnote.monospaced())
                }
            }
        } header: {
            Text("Rutas bloqueadas")
        } footer: {
            Text("Excepciones: \(store.base.allowedPathPrefixes.joined(separator: ", ")). Un reel individual (p. ej. enviado por DM) se permite si “Fijar reel individual” está activo.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button("Copiar reglas como JSON") { copy(store.exportJSON(), label: "Reglas") }
            Button("Restablecer ajustes del panel", role: .destructive) { store.resetOverrides() }
            if let copied {
                Text("\(copied) copiado al portapapeles").font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Restablecer vuelve a rules.json tal cual: borra toggles y selectores añadidos. No cierra la sesión de Instagram.")
        }
    }

    // MARK: - Ayudas

    private func selectorToggle(_ rule: SelectorRule) -> some View {
        Toggle(isOn: Binding(
            get: { store.isSelectorEnabled(rule.selector) },
            set: { store.setSelector(rule.selector, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.selector).font(.footnote.monospaced())
                if let ancestors = rule.ancestors {
                    Text("sube \(ancestors) niveles").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<RuleStore, Bool>) -> Binding<Bool> {
        Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copied = label
    }
}
