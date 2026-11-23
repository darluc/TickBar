import Foundation

/// Basket-level turnover split by `StockVolumeBand`, using today's trade-detail snapshot.
/// Reconciles each minute's detail volume to the minute series; sums amounts in CNY.
struct ETFBasketVolumeClassification: Equatable, Sendable {
    /// Amounts in yuan: large / medium / small.
    var amounts: [Double] = [0, 0, 0]
    /// Basket turnover covered by classified minutes (yuan).
    var coveredTurnover: Double = 0
    /// Total turnover in classified minutes from minute series (yuan).
    var referenceTurnover: Double = 0
    /// Minutes with detail present but volume mismatch.
    var inconsistentMinutes = 0

    var hasData: Bool { referenceTurnover > 0 }

    /// Coverage of turnover in the computed range.
    var coverage: Double {
        guard referenceTurnover > 0 else { return 0 }
        return coveredTurnover / referenceTurnover
    }

    static func aggregate(minutes: [String: ETFMinuteSeries], trades: [String: [StockVolumeTrade]],
                          day: String, throughSlot: Int) -> ETFBasketVolumeClassification {
        guard throughSlot >= 0 else { return ETFBasketVolumeClassification() }
        let codes = Set(ETFDescriptor.basket.map(\.code))
        var out = ETFBasketVolumeClassification()
        for code in codes {
            guard let series = minutes[code], series.day == day else { continue }
            let grouped = Dictionary(grouping: trades[code] ?? [], by: \.slot)
            for slot in 0...throughSlot {
                guard let total = series.amount[slot], total > 0 else { continue }
                out.referenceTurnover += total
                let records = grouped[slot] ?? []
                let detailTurnover = records.reduce(0) { $0 + $1.estimatedAmount }
                guard records.isEmpty == false, detailTurnover > 0,
                      Self.matches(detailTurnover, total) else {
                    if !records.isEmpty { out.inconsistentMinutes += 1 }
                    continue
                }
                out.coveredTurnover += total
                for trade in records {
                    out.amounts[trade.band.rawValue] += trade.estimatedAmount
                }
            }
        }
        return out
    }

    private static func matches(_ detail: Double, _ reference: Double) -> Bool {
        abs(detail - reference) <= max(1, reference * 1e-4)
    }
}
