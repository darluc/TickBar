import Foundation

enum Currency: String, Codable, CaseIterable, Sendable {
    case cny = "CNY"
    case usd = "USD"
    case hkd = "HKD"
    case krw = "KRW"

    var symbol: String {
        switch self {
        case .cny: return "¥"
        case .usd: return "$"
        case .hkd: return "HK$"
        case .krw: return "₩"
        }
    }

    func format(_ value: Decimal, fractionDigits: Int? = nil) -> String {
        let formatter = NumberFormatter()
        let digits = fractionDigits ?? (self == .krw ? 0 : 2)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.numberStyle = .decimal
        let n = NSDecimalNumber(decimal: value)
        let text = formatter.string(from: n) ?? "\(value)"
        return "\(symbol)\(text)"
    }
}
