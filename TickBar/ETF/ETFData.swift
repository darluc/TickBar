import Foundation

struct ETFDescriptor: Identifiable {
    let code: String
    let name: String
    var id: String { code }
    var secid: String { "\(code.hasPrefix("15") ? 0 : 1).\(code)" }

    /// Fixed basket (adjusted 2026-10-15). Never replace with turnover leaders.
    static let basket: [ETFDescriptor] = [
        .init(code: "510310", name: "沪深300ETF易方达"),
        .init(code: "510300", name: "沪深300ETF华泰柏瑞"),
        .init(code: "159919", name: "沪深300ETF嘉实"),
        .init(code: "563360", name: "A500ETF华泰柏瑞"),
        .init(code: "159352", name: "A500ETF南方"),
        .init(code: "159338", name: "中证A500ETF国泰"),
        .init(code: "159361", name: "A500ETF易方达"),
        .init(code: "512050", name: "A500ETF华夏"),
        .init(code: "512100", name: "中证1000ETF南方"),
        .init(code: "159845", name: "中证1000ETF华夏"),
        .init(code: "159633", name: "中证1000ETF易方达"),
        .init(code: "560010", name: "中证1000ETF广发"),
        .init(code: "588000", name: "科创50ETF华夏"),
        .init(code: "588080", name: "科创50ETF易方达"),
        .init(code: "159915", name: "创业板ETF易方达"),
        .init(code: "159952", name: "创业板ETF广发"),
        .init(code: "510500", name: "中证500ETF南方"),
        .init(code: "159949", name: "创业板50ETF华安"),
        .init(code: "510050", name: "上证50ETF华夏"),
        .init(code: "510210", name: "上证指数ETF富国")
    ]
    static let names: [String: String] = Dictionary(uniqueKeysWithValues: basket.map { ($0.code, $0.name) })
    /// 上证综指 is requested for comparison only; it is not part of the basket.
    static let indexCode = "000001"
    static let indexSecid = "1.000001"
}

/// Trading-session coordinates in Asia/Shanghai.
///
/// Minute slots run 0...240: 09:30 is 0, 11:30 is 120, and 13:01 follows immediately at 121
/// (the exchange publishes no 13:00 row), so lunch occupies no chart space. Five-minute bars are
/// labelled by their closing minute, which makes their slots multiples of five in each session.
enum ETFTime {
    static let lastSlot = 240
    static let slotCount = lastSlot + 1
    static let barsPerDay = 48

    private static let zone = TimeZone(identifier: "Asia/Shanghai")!

    /// DateFormatter is expensive to build and is not thread-safe; share one per thread.
    private static func formatter(_ format: String) -> DateFormatter {
        let key = "ETFTime.\(format)"
        if let cached = Thread.current.threadDictionary[key] as? DateFormatter { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        Thread.current.threadDictionary[key] = f
        return f
    }
    static func day(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }

    /// Slot of a trading minute given as minutes after midnight, or nil outside the sessions.
    static func slot(minuteOfDay m: Int) -> Int? {
        if (570...690).contains(m) { return m - 570 }
        if (781...900).contains(m) { return m - 660 }
        return nil
    }
    static func slot(hour: Int, minute: Int) -> Int? { slot(minuteOfDay: hour * 60 + minute) }

    /// Parses "yyyy-MM-dd HH:mm" without allocating; returns the day and slot.
    static func parse(_ stamp: Substring) -> (day: Substring, slot: Int)? {
        let u = stamp.utf8
        guard u.count == 16 else { return nil }
        let b = Array(u)
        guard b[4] == 45, b[7] == 45, b[10] == 32, b[13] == 58 else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range {
                guard (48...57).contains(b[i]) else { return nil }
                n = n * 10 + Int(b[i] - 48)
            }
            return n
        }
        guard let h = digits(11..<13), let m = digits(14..<16), let slot = slot(hour: h, minute: m) else { return nil }
        return (stamp.prefix(10), slot)
    }

    /// Axis labels: slot → clock text.
    static let axis: [(slot: Int, label: String)] = [(0, "09:30"), (60, "10:30"), (120, "11:30"), (180, "14:00"), (240, "15:00")]
    static func label(slot: Int) -> String {
        let minute = slot <= 120 ? 570 + slot : 660 + slot
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

/// One row of the latest quote batch (amount in CNY).
struct ETFQuote: Equatable, Sendable {
    let code: String
    let amount: Double
    let changePercent: Double?
    let timestamp: Date
}

/// Per-slot values of one ETF's current trading day.
struct ETFMinuteSeries: Sendable {
    let day: String
    /// Indexed by slot; nil where the exchange sent no row.
    var amount: [Double?]
    var close: [Double?]
    var lastSlot: Int { amount.lastIndex { $0 != nil } ?? -1 }
}

/// Cumulative curve sampled every five minutes (slots 5, 10, ... 240), prefixed by (0, 0).
struct ETFCurve: Equatable, Sendable {
    let slots: [Int]
    let values: [Double]

    /// Linear interpolation at a slot, clamped to the curve's range.
    func value(at slot: Int) -> Double {
        guard let last = slots.last, let first = slots.first else { return 0 }
        if slot <= first { return values[0] }
        if slot >= last { return values[values.count - 1] }
        var lo = 0, hi = slots.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if slots[mid] <= slot { lo = mid } else { hi = mid }
        }
        let span = Double(slots[hi] - slots[lo])
        return values[lo] + (values[hi] - values[lo]) * Double(slot - slots[lo]) / span
    }
}

enum ETFDataError: Error {
    case invalidResponse
}
