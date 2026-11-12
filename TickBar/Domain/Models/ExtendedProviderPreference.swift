import Foundation

/// 扩展报价与主行情独立配置，避免夜盘源替代常规报价。
enum ExtendedProviderID: String, Codable, CaseIterable, Sendable {
    case robinhood, yahoo, xueqiu, sina, nasdaq

    var displayName: String {
        switch self {
        case .xueqiu: return L("dataSource.xueqiu", comment: "")
        case .robinhood: return "Robinhood"
        case .yahoo: return "Yahoo Finance"
        case .sina: return L("dataSource.sina", comment: "")
        case .nasdaq: return "Nasdaq"
        }
    }

    var supportsOvernight: Bool { self == .robinhood || self == .yahoo || self == .xueqiu }
}

struct ExtendedProviderPreference: Codable, Equatable, Sendable {
    var order: [ExtendedProviderID]
    var enabled: [ExtendedProviderID: Bool]

    static let defaults = ExtendedProviderPreference(
        order: ExtendedProviderID.allCases,
        enabled: Dictionary(uniqueKeysWithValues: ExtendedProviderID.allCases.map { ($0, true) })
    )

    /// 新增源自动补全；保留已有顺序和用户关闭的选项。
    var normalized: ExtendedProviderPreference {
        var seen = Set<ExtendedProviderID>()
        let order = (order + ExtendedProviderID.allCases).filter { seen.insert($0).inserted }
        var enabled = enabled
        for id in order where enabled[id] == nil { enabled[id] = true }
        return ExtendedProviderPreference(order: order, enabled: enabled)
    }
}

struct ExtendedProviderReport: Sendable {
    let providerID: String
    let requested: [SymbolID]
    let accepted: [SymbolID]
    let tradeTimes: [SymbolID: Date]
    let timestamp: Date
    let error: String?
}
