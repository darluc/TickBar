import Foundation
import Combine

/// 包装 provider 优先级 + Finnhub Key 的偏好。读取自 SettingsRepository,变更时落库 + 通知。
@MainActor
final class DataSourcePreferences: ObservableObject {
    @Published var preferences: [Market: ProviderPreference]
    @Published private(set) var extendedPreference: ExtendedProviderPreference
    @Published var finnhubKey: String {
        didSet {
            if oldValue != finnhubKey {
                try? repo.set(Keys.finnhubKey, finnhubKey)
                onFinnhubKeyChange?(finnhubKey)
            }
        }
    }

    var onPreferencesChange: (([Market: ProviderPreference]) -> Void)?
    var onFinnhubKeyChange: ((String) -> Void)?
    var onExtendedPreferenceChange: ((ExtendedProviderPreference) -> Void)?

    private let repo: SettingsRepository

    enum Keys {
        static let providerPrefs = "provider_prefs"
        static let finnhubKey = "finnhub_api_key"
        static let extendedProviders = "us_extended_providers"
    }

    init(repo: SettingsRepository) {
        self.repo = repo
        // 加载 prefs
        if let json = repo.string(Keys.providerPrefs),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: ProviderPreference].self, from: data) {
            var loaded: [Market: ProviderPreference] = [:]
            for (k, v) in decoded {
                if let m = Market(rawValue: k) { loaded[m] = v }
            }
            // 用默认值补全缺失市场
            for market in Market.allCases where loaded[market] == nil {
                loaded[market] = ProviderPreference.defaults[market]
            }
            self.preferences = loaded
        } else {
            self.preferences = ProviderPreference.defaults
        }
        if let json = repo.string(Keys.extendedProviders), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ExtendedProviderPreference.self, from: data) {
            self.extendedPreference = decoded.normalized
        } else {
            self.extendedPreference = .defaults
        }
        self.finnhubKey = repo.string(Keys.finnhubKey) ?? ""
    }

    func updatePreferences(_ prefs: [Market: ProviderPreference]) {
        self.preferences = prefs
        persist()
        onPreferencesChange?(prefs)
    }

    func updateExtendedPreference(_ preference: ExtendedProviderPreference) {
        let normalized = preference.normalized
        self.extendedPreference = normalized
        if let data = try? JSONEncoder().encode(normalized), let json = String(data: data, encoding: .utf8) {
            try? repo.set(Keys.extendedProviders, json)
        }
        onExtendedPreferenceChange?(normalized)
    }

    private func persist() {
        let encoded = preferences.reduce(into: [String: ProviderPreference]()) { acc, kv in
            acc[kv.key.rawValue] = kv.value
        }
        if let data = try? JSONEncoder().encode(encoded),
           let json = String(data: data, encoding: .utf8) {
            try? repo.set(Keys.providerPrefs, json)
        }
    }
}
