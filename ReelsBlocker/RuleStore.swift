import Foundation
import Observation

/// Un selector a ocultar. En rules.json puede ser un string o
/// `{ "selector": "...", "ancestors": 4 }` para sobrescribir `hideAncestorLevels`.
struct SelectorRule: Codable, Hashable, Identifiable {
    var selector: String
    var ancestors: Int?

    var id: String { selector }

    init(selector: String, ancestors: Int? = nil) {
        self.selector = selector
        self.ancestors = ancestors
    }

    private enum CodingKeys: String, CodingKey { case selector, ancestors }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            self.init(selector: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selector: try container.decode(String.self, forKey: .selector),
            ancestors: try container.decodeIfPresent(Int.self, forKey: .ancestors)
        )
    }

    func encode(to encoder: Encoder) throws {
        if let ancestors {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(selector, forKey: .selector)
            try container.encode(ancestors, forKey: .ancestors)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(selector)
        }
    }
}

/// Contenido de Resources/rules.json. Los campos que falten toman el valor por defecto.
struct Rules: Codable, Equatable {
    var version = 1
    var blockedPathPrefixes: [String] = ["/reels/", "/reel/", "/explore/"]
    var allowedPathPrefixes: [String] = ["/explore/search/"]
    var singleReelPathPattern = "^/reels?/[A-Za-z0-9_-]+/?$"
    var hideSelectors: [SelectorRule] = [
        SelectorRule(selector: "a[href='/reels/']"),
        SelectorRule(selector: "a[href='/explore/']"),
    ]
    var hideAncestorLevels = 2
    var neverHideInside: [String] = ["a[href^='/reel/']", "a[href^='/p/']"]
    var lockScrollOnReelView = true
    var reelViewHideSelectors: [String] = []
    var hideSponsored = true
    var sponsoredLabels: [String] = ["Sponsored", "Publicidad", "Patrocinado"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Rules()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        blockedPathPrefixes = try c.decodeIfPresent([String].self, forKey: .blockedPathPrefixes) ?? d.blockedPathPrefixes
        allowedPathPrefixes = try c.decodeIfPresent([String].self, forKey: .allowedPathPrefixes) ?? d.allowedPathPrefixes
        singleReelPathPattern = try c.decodeIfPresent(String.self, forKey: .singleReelPathPattern) ?? d.singleReelPathPattern
        hideSelectors = try c.decodeIfPresent([SelectorRule].self, forKey: .hideSelectors) ?? d.hideSelectors
        hideAncestorLevels = try c.decodeIfPresent(Int.self, forKey: .hideAncestorLevels) ?? d.hideAncestorLevels
        neverHideInside = try c.decodeIfPresent([String].self, forKey: .neverHideInside) ?? d.neverHideInside
        lockScrollOnReelView = try c.decodeIfPresent(Bool.self, forKey: .lockScrollOnReelView) ?? d.lockScrollOnReelView
        reelViewHideSelectors = try c.decodeIfPresent([String].self, forKey: .reelViewHideSelectors) ?? d.reelViewHideSelectors
        hideSponsored = try c.decodeIfPresent(Bool.self, forKey: .hideSponsored) ?? d.hideSponsored
        sponsoredLabels = try c.decodeIfPresent([String].self, forKey: .sponsoredLabels) ?? d.sponsoredLabels
    }
}

/// Cambios hechos desde el panel de depuración. Se guardan en UserDefaults
/// y se aplican encima de rules.json, que nunca se modifica.
struct RuleOverrides: Codable, Equatable {
    var enabled = true
    var disabledSelectors: Set<String> = []
    var disabledPathPrefixes: Set<String> = []
    var customSelectors: [SelectorRule] = []
    var lockScrollOnReelView: Bool?
    var hideSponsored: Bool?
}

/// Lo que se entrega al JS inyectado (window.__RB_CONFIG).
struct ScriptConfig: Codable, Equatable {
    var enabled: Bool
    var rules: Rules
}

@Observable
final class RuleStore {
    /// Reglas tal cual vienen del bundle.
    let base: Rules
    /// Error al leer rules.json; si lo hay se usan los valores por defecto.
    let loadError: String?

    private(set) var overrides: RuleOverrides

    private let defaults: UserDefaults
    private static let overridesKey = "rb.overrides.v1"

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.loadBundledRules(from: bundle)
        base = loaded.rules
        loadError = loaded.error
        if let data = defaults.data(forKey: Self.overridesKey),
           let saved = try? JSONDecoder().decode(RuleOverrides.self, from: data) {
            overrides = saved
        } else {
            overrides = RuleOverrides()
        }
    }

    private static func loadBundledRules(from bundle: Bundle) -> (rules: Rules, error: String?) {
        guard let url = bundle.url(forResource: "rules", withExtension: "json") else {
            return (Rules(), "rules.json no está en el bundle")
        }
        do {
            return (try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url)), nil)
        } catch {
            return (Rules(), "rules.json inválido: \(error)")
        }
    }

    // MARK: - Reglas efectivas

    var isEnabled: Bool {
        get { overrides.enabled }
        set { mutate { $0.enabled = newValue } }
    }

    var lockScrollOnReelView: Bool {
        get { overrides.lockScrollOnReelView ?? base.lockScrollOnReelView }
        set { mutate { $0.lockScrollOnReelView = newValue } }
    }

    var hideSponsored: Bool {
        get { overrides.hideSponsored ?? base.hideSponsored }
        set { mutate { $0.hideSponsored = newValue } }
    }

    var customSelectors: [SelectorRule] { overrides.customSelectors }

    /// rules.json + selectores propios, sin lo desactivado en el panel.
    var effectiveRules: Rules {
        var rules = base
        rules.hideSelectors = (base.hideSelectors + overrides.customSelectors)
            .filter { !overrides.disabledSelectors.contains($0.selector) }
        rules.blockedPathPrefixes = base.blockedPathPrefixes
            .filter { !overrides.disabledPathPrefixes.contains($0) }
        rules.lockScrollOnReelView = lockScrollOnReelView
        rules.hideSponsored = hideSponsored
        return rules
    }

    var scriptConfig: ScriptConfig {
        ScriptConfig(enabled: overrides.enabled, rules: effectiveRules)
    }

    // MARK: - Toggles individuales

    func isSelectorEnabled(_ selector: String) -> Bool {
        !overrides.disabledSelectors.contains(selector)
    }

    func setSelector(_ selector: String, enabled: Bool) {
        mutate {
            if enabled { $0.disabledSelectors.remove(selector) } else { $0.disabledSelectors.insert(selector) }
        }
    }

    func isPathPrefixEnabled(_ prefix: String) -> Bool {
        !overrides.disabledPathPrefixes.contains(prefix)
    }

    func setPathPrefix(_ prefix: String, enabled: Bool) {
        mutate {
            if enabled { $0.disabledPathPrefixes.remove(prefix) } else { $0.disabledPathPrefixes.insert(prefix) }
        }
    }

    /// Añade un selector probado en caliente. Devuelve false si ya existía.
    @discardableResult
    func addCustomSelector(_ selector: String, ancestors: Int? = nil) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !(base.hideSelectors + overrides.customSelectors).contains(where: { $0.selector == trimmed })
        else { return false }
        mutate { $0.customSelectors.append(SelectorRule(selector: trimmed, ancestors: ancestors)) }
        return true
    }

    func removeCustomSelector(_ selector: String) {
        mutate {
            $0.customSelectors.removeAll { $0.selector == selector }
            $0.disabledSelectors.remove(selector)
        }
    }

    func resetOverrides() {
        mutate { $0 = RuleOverrides() }
    }

    /// Reglas efectivas en el formato de rules.json, para copiarlas al repo.
    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(effectiveRules) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func mutate(_ change: (inout RuleOverrides) -> Void) {
        var copy = overrides
        change(&copy)
        guard copy != overrides else { return }
        overrides = copy
        if let data = try? JSONEncoder().encode(copy) {
            defaults.set(data, forKey: Self.overridesKey)
        }
    }
}
