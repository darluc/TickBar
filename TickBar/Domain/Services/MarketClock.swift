import Foundation

/// 各市场交易时段判定。
///
/// 默认规则:
///   - A 股:09:30-11:30 + 13:00-15:00(Asia/Shanghai),周六/日休市
///   - 港股:09:30-12:00 + 13:00-16:00(Asia/Shanghai),周六/日休市
///   - 美股:09:30-16:00(America/New_York),周六/日休市
///
/// 节假日:无法做到 100% 准确(没有可靠免费 API),依赖用户手动 override
/// (`market_override_<market>` 设置,格式 `YYYY-MM-DD:open|closed`),
/// 当 override 日期等于「该市场所在时区今天」时生效。
enum MarketStatus: Equatable, Sendable {
    case open
    case lunchBreak
    case closed
}

enum MarketOverride: String, Equatable, Sendable {
    case forceOpen = "open"
    case forceClosed = "closed"
}

final class MarketClock: @unchecked Sendable {
    private let settingsRepo: SettingsRepository?

    init(settingsRepo: SettingsRepository? = nil) {
        self.settingsRepo = settingsRepo
    }

    func status(_ market: Market, at date: Date = Date()) -> MarketStatus {
        // 1) 用户 override 优先
        switch overrideToday(for: market, at: date) {
        case .forceClosed:
            return .closed
        case .forceOpen:
            return statusByHours(market, at: date)  // 跳过周末检查,只看时段
        case nil:
            break
        }

        // 2) 周末
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = market.timeZone
        let weekday = cal.dateComponents([.weekday], from: date).weekday ?? 1
        if weekday == 1 || weekday == 7 { return .closed }

        return statusByHours(market, at: date)
    }

    /// 不考虑周末/节假日,仅根据时段判断(午休 / 开盘 / 收盘)。
    /// forceOpen 用户认为今天该开,我们就跳过周末检查走这里。
    private func statusByHours(_ market: Market, at date: Date) -> MarketStatus {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = market.timeZone
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        switch market {
        case .a:
            if minutes >= 9 * 60 + 30 && minutes <= 11 * 60 + 30 { return .open }
            if minutes >= 13 * 60 && minutes <= 15 * 60 { return .open }
            if minutes > 11 * 60 + 30 && minutes < 13 * 60 { return .lunchBreak }
            return .closed
        case .hk:
            if minutes >= 9 * 60 + 30 && minutes <= 12 * 60 { return .open }
            if minutes >= 13 * 60 && minutes <= 16 * 60 { return .open }
            if minutes > 12 * 60 && minutes < 13 * 60 { return .lunchBreak }
            return .closed
        case .us:
            if minutes >= 9 * 60 + 30 && minutes < 16 * 60 { return .open }
            return .closed
        case .kr:
            // KRX (KOSPI / KOSDAQ): 09:00 - 15:30 (KST), no lunch break
            if minutes >= 9 * 60 && minutes <= 15 * 60 + 30 { return .open }
            return .closed
        case .crypto:
            // 币圈 (Binance): 7x24 全天候交易，永不休市
            return .open
        }
    }

    /// 任一市场开盘则视为活跃。午休不算活跃(行情确实不动)。
    func anyOpen(at date: Date = Date()) -> Bool {
        for m in Market.allCases where status(m, at: date) == .open {
            return true
        }
        return false
    }

    /// 菜单栏滚动 / 行情刷新是否该继续:常规开盘,或自选里有美股且处于盘前/盘后/夜盘。
    func anyQuoteActive(markets: Set<Market>, at date: Date = Date()) -> Bool {
        let targets = markets.isEmpty ? Set(Market.allCases) : markets
        for m in targets {
            if m == .crypto { return true }
            if status(m, at: date) == .open { return true }
            if m == .us, usExtendedSession(at: date) != nil { return true }
        }
        return false
    }

    /// 美股扩展时段(不含常规盘):盘前 04:00-09:30、盘后 16:00-20:00、夜盘 20:00-04:00。
    func usExtendedSession(at date: Date = Date()) -> ExtendedSession? {
        guard overrideToday(for: .us, at: date) != .forceClosed else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Market.us.timeZone
        let weekday = cal.dateComponents([.weekday], from: date).weekday ?? 1
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        // 盘前:周一至周五 04:00-09:30
        if minutes >= 4 * 60 && minutes < 9 * 60 + 30 {
            return (weekday >= 2 && weekday <= 6) ? .preMarket : nil
        }
        // 盘后:周一至周五 16:00-20:00
        if minutes >= 16 * 60 && minutes < 20 * 60 {
            return (weekday >= 2 && weekday <= 6) ? .postMarket : nil
        }
        // 夜盘 20:00-24:00:周日到周四
        if minutes >= 20 * 60 {
            return (weekday == 1 || (weekday >= 2 && weekday <= 5)) ? .overnight : nil
        }
        // 夜盘 00:00-04:00:周一到周五
        if minutes < 4 * 60 {
            return (weekday >= 2 && weekday <= 6) ? .overnight : nil
        }
        return nil
    }

    /// 报价必须来自当前扩展交易时段，不能用抓取时间代替成交时间。
    func isCurrentUSExtendedTrade(_ tradeDate: Date?, session: ExtendedSession, at date: Date = Date()) -> Bool {
        guard let tradeDate, usExtendedSession(at: date) == session,
              tradeDate <= date.addingTimeInterval(60) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        let hour: Int
        switch session {
        case .preMarket: hour = 4
        case .postMarket: hour = 16
        case .overnight: hour = 20
        case .regular: return false
        }
        var start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        if session == .overnight && start > date {
            start = calendar.date(byAdding: .day, value: -1, to: start)!
        }
        return tradeDate >= start
    }

    // MARK: - Override(节假日纠错)

    /// 读取 settings 里这个市场的 override,仅当 override 日期匹配「该市场时区下今天」时才生效。
    /// 隔天会因为日期对不上自动失效。
    func overrideToday(for market: Market, at date: Date = Date()) -> MarketOverride? {
        guard let repo = settingsRepo,
              let raw = repo.string(SettingsRepository.Keys.marketOverride(market)) else { return nil }
        // 格式 "YYYY-MM-DD:open" / "YYYY-MM-DD:closed"
        let parts = raw.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let savedDate = String(parts[0])
        guard savedDate == Self.dateString(date, tz: market.timeZone) else { return nil }
        return MarketOverride(rawValue: String(parts[1]))
    }

    static func dateString(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
