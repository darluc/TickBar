import Foundation

/// 美股及其他市场的扩展交易时段 (盘前 / 盘后 / 24h 夜盘)
enum ExtendedSession: String, Codable, Sendable {
    case regular
    case preMarket
    case postMarket
    case overnight

    var label: String {
        switch self {
        case .regular: return ""
        case .preMarket: return "盘前"
        case .postMarket: return "盘后"
        case .overnight: return "24h"
        }
    }

    /// 列表行右侧小徽章,跟常见行情软件一致。
    var shortLabel: String {
        switch self {
        case .regular: return ""
        case .preMarket: return "Pre"
        case .postMarket: return "Post"
        case .overnight: return "24h"
        }
    }
}

struct Quote: Equatable, Codable, Sendable {
    let symbol: SymbolID
    let name: String
    let price: Decimal
    let prevClose: Decimal
    let open: Decimal?
    let high: Decimal?
    let low: Decimal?
    let volume: Decimal?
    let currency: Currency
    let timestamp: Date
    let isClosed: Bool

    /// 美股 24h 及盘前盘后价格与时段
    let extendedPrice: Decimal?
    let extendedChange: Decimal?
    let extendedChangePct: Double?
    let extendedSession: ExtendedSession?
    let sparklineHistory: [Double]?
    /// 与走势价格逐点对应；旧缓存或不提供分时的数据源可为空。
    let sparklineTimestamps: [Date]?

    init(
        symbol: SymbolID,
        name: String,
        price: Decimal,
        prevClose: Decimal,
        open: Decimal? = nil,
        high: Decimal? = nil,
        low: Decimal? = nil,
        volume: Decimal? = nil,
        currency: Currency,
        timestamp: Date = Date(),
        isClosed: Bool = false,
        extendedPrice: Decimal? = nil,
        extendedChange: Decimal? = nil,
        extendedChangePct: Double? = nil,
        extendedSession: ExtendedSession? = nil,
        sparklineHistory: [Double]? = nil,
        sparklineTimestamps: [Date]? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.prevClose = prevClose
        self.open = open
        self.high = high
        self.low = low
        self.volume = volume
        self.currency = currency
        self.timestamp = timestamp
        self.isClosed = isClosed
        self.extendedPrice = extendedPrice
        self.extendedChange = extendedChange
        self.extendedChangePct = extendedChangePct
        self.extendedSession = extendedSession
        self.sparklineHistory = sparklineHistory
        self.sparklineTimestamps = sparklineTimestamps
    }

    /// 返回新一天的首个点索引，绘图时将分隔线放在它和前一点之间。
    var sparklineDayBoundaryIndices: [Int] {
        guard symbol.market != .crypto,
              let points = sparklineHistory,
              let timestamps = sparklineTimestamps,
              points.count == timestamps.count,
              timestamps.count >= 2 else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = symbol.market.timeZone
        return (1..<timestamps.count).filter {
            !calendar.isDate(timestamps[$0 - 1], inSameDayAs: timestamps[$0])
        }
    }

    var change: Decimal { price - prevClose }

    var changePct: Double {
        guard prevClose > 0 else { return 0 }
        let pct = (change / prevClose) as NSDecimalNumber
        return pct.doubleValue
    }

    /// 当前有效价格:如果在盘前/盘后/24h 且有扩展报价,优先返回最新成交价
    var effectivePrice: Decimal {
        if let ext = extendedPrice, ext > 0, extendedSession != nil, extendedSession != .regular {
            return ext
        }
        return price
    }

    var effectiveChange: Decimal {
        if let ext = extendedChange, extendedSession != nil, extendedSession != .regular {
            return ext
        }
        return change
    }

    var effectiveChangePct: Double {
        if let ext = extendedChangePct, extendedSession != nil, extendedSession != .regular {
            return ext
        }
        return changePct
    }

    var isExtended: Bool {
        extendedSession != nil && extendedSession != .regular && extendedPrice != nil
    }

    /// 保留常规报价和走势，移除未通过成交时间校验的扩展报价。
    func withoutExtended() -> Quote {
        Quote(
            symbol: symbol, name: name, price: price, prevClose: prevClose,
            open: open, high: high, low: low, volume: volume,
            currency: currency, timestamp: timestamp, isClosed: isClosed,
            sparklineHistory: sparklineHistory, sparklineTimestamps: sparklineTimestamps
        )
    }

    /// 用 Yahoo 的盘前/盘后/分时叠到腾讯等主报价上,保留中文名。
    func overlayingExtended(from other: Quote) -> Quote {
        Quote(
            symbol: symbol,
            name: name.isEmpty ? other.name : name,
            price: price,
            prevClose: prevClose > 0 ? prevClose : other.prevClose,
            open: open ?? other.open,
            high: high ?? other.high,
            low: low ?? other.low,
            volume: volume ?? other.volume,
            currency: currency,
            timestamp: other.timestamp,
            isClosed: isClosed,
            extendedPrice: other.extendedPrice ?? extendedPrice,
            extendedChange: other.extendedChange ?? extendedChange,
            extendedChangePct: other.extendedChangePct ?? extendedChangePct,
            extendedSession: other.extendedSession ?? extendedSession,
            sparklineHistory: other.sparklineHistory ?? sparklineHistory,
            sparklineTimestamps: other.sparklineHistory != nil ? other.sparklineTimestamps : sparklineTimestamps
        )
    }
}
