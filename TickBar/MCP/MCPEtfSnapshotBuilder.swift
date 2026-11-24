import Foundation

struct MCPEtfSnapshotResponse: Codable, Sendable {
    struct TurnoverStatistics: Codable, Sendable {
        /// Sum of covered ETF quote turnover for the displayed session (yuan).
        let totalTurnoverYuan: Double
        /// Intraday cumulative basket turnover at the latest minute edge (yuan).
        let cumulativeTurnoverYuan: Double?
        let liveMinuteSlot: Int
        let basketSize: Int
        let quoteCoverage: Int
        let minuteCoverage: Int
        let currency: String
    }

    struct HistoricalComparison: Codable, Sendable {
        let previousSessionDay: String
        let averageBaselineDays: Int
        /// Basket cumulative turnover at `liveMinuteSlot` for the displayed session.
        let currentCumulativeYuan: Double?
        /// Previous complete session curve at the same minute slot (yuan).
        let referencePreviousYuan: Double?
        /// Rolling mean curve (up to 20 sessions, min 3 complete days) at the same slot (yuan).
        let referenceAverageYuan: Double?
        /// `current / reference - 1` at the same minute; e.g. 0.05 means +5%.
        let paceVsPrevious: Double?
        let paceVsAverage: Double?
        let previousBaselineReady: Bool
        let averageBaselineReady: Bool
    }

    struct TradeSizeTier: Codable, Sendable {
        let turnoverYuan: Double
        let shareOfClassified: Double?
        let thresholdDescription: String
    }

    struct TradeSizeBands: Codable, Sendable {
        let small: TradeSizeTier
        let medium: TradeSizeTier
        let large: TradeSizeTier
        let referenceTurnoverYuan: Double
        let coveredTurnoverYuan: Double
        let coverageRatio: Double
        let inconsistentMinutes: Int
    }

    struct Row: Codable, Sendable {
        let code: String
        let name: String
        let turnoverYuan: Double
        let shareOfBasket: Double?
        let changePercent: Double?
    }

    struct Status: Codable, Sendable {
        let paused: Bool
        let refreshing: Bool
        let panelVisible: Bool
        let market: String
        let statusText: String
        let warning: Bool
        let lastSuccessfulRefresh: String?
        let snapshotUpdated: String?
    }

    let sessionDay: String
    let isHistoricalSession: Bool
    let turnoverStatistics: TurnoverStatistics
    let historicalComparison: HistoricalComparison
    let tradeSizeBands: TradeSizeBands?
    let rows: [Row]
    let status: Status

    // Flat aliases kept for simple clients.
    let basketTurnoverYuan: Double
    let quoteCoverage: Int
    let minuteCoverage: Int
    let paceVsPrevious: Double?
    let paceVsAverage: Double?
    let averageBaselineDays: Int
}

enum MCPEtfSnapshotBuilder {
    @MainActor
    static func build(monitor: ETFMonitor) -> MCPEtfSnapshotResponse {
        build(
            display: monitor.board.display,
            paused: monitor.paused,
            refreshing: monitor.status.refreshing,
            panelVisible: monitor.mcpPanelVisible,
            market: monitor.mcpMarketStatus(),
            statusText: monitor.status.text,
            warning: monitor.status.warning,
            lastSuccessfulRefresh: monitor.mcpLastSuccessfulRefresh
        )
    }

    @MainActor
    static func build(
        display: ETFDisplay,
        paused: Bool,
        refreshing: Bool,
        panelVisible: Bool,
        market: String,
        statusText: String,
        warning: Bool,
        lastSuccessfulRefresh: Date?
    ) -> MCPEtfSnapshotResponse {
        let formatter = ISO8601DateFormatter()
        let today = ETFTime.day(Date())
        let liveSlot = display.liveSlot
        let cumulative = display.cumulative.last

        let stats = MCPEtfSnapshotResponse.TurnoverStatistics(
            totalTurnoverYuan: display.total,
            cumulativeTurnoverYuan: cumulative,
            liveMinuteSlot: liveSlot,
            basketSize: ETFDescriptor.basket.count,
            quoteCoverage: display.quoteCount,
            minuteCoverage: display.minuteCount,
            currency: "CNY"
        )

        let refPrevious = display.previous?.value(at: liveSlot)
        let refAverage = display.average?.value(at: liveSlot)
        let history = MCPEtfSnapshotResponse.HistoricalComparison(
            previousSessionDay: display.previousDay,
            averageBaselineDays: display.averageDays,
            currentCumulativeYuan: cumulative,
            referencePreviousYuan: refPrevious,
            referenceAverageYuan: refAverage,
            paceVsPrevious: display.pacePrevious,
            paceVsAverage: display.paceAverage,
            previousBaselineReady: display.previous != nil,
            averageBaselineReady: display.average != nil
        )

        var bands: MCPEtfSnapshotResponse.TradeSizeBands?
        if let volume = display.volumeBands, volume.hasData {
            let small = volume.amounts.count > 2 ? volume.amounts[2] : 0
            let medium = volume.amounts.count > 1 ? volume.amounts[1] : 0
            let large = volume.amounts.count > 0 ? volume.amounts[0] : 0
            let classifiedTotal = small + medium + large
            func share(_ yuan: Double) -> Double? {
                guard classifiedTotal > 0 else { return nil }
                return yuan / classifiedTotal
            }
            bands = .init(
                small: .init(
                    turnoverYuan: small,
                    shareOfClassified: share(small),
                    thresholdDescription: "single public trade record < ¥100,000"
                ),
                medium: .init(
                    turnoverYuan: medium,
                    shareOfClassified: share(medium),
                    thresholdDescription: "¥100,000 ≤ single record < ¥1,000,000"
                ),
                large: .init(
                    turnoverYuan: large,
                    shareOfClassified: share(large),
                    thresholdDescription: "single public trade record ≥ ¥1,000,000"
                ),
                referenceTurnoverYuan: volume.referenceTurnover,
                coveredTurnoverYuan: volume.coveredTurnover,
                coverageRatio: volume.coverage,
                inconsistentMinutes: volume.inconsistentMinutes
            )
        }

        let rows = display.rows.map { row in
            MCPEtfSnapshotResponse.Row(
                code: row.code,
                name: row.name,
                turnoverYuan: row.amountYuan,
                shareOfBasket: row.shareOfBasket,
                changePercent: row.changePercent
            )
        }

        let status = MCPEtfSnapshotResponse.Status(
            paused: paused,
            refreshing: refreshing,
            panelVisible: panelVisible,
            market: market,
            statusText: statusText,
            warning: warning,
            lastSuccessfulRefresh: lastSuccessfulRefresh.map { formatter.string(from: $0) },
            snapshotUpdated: display.updated.map { formatter.string(from: $0) }
        )

        return MCPEtfSnapshotResponse(
            sessionDay: display.day,
            isHistoricalSession: !display.day.isEmpty && display.day != today,
            turnoverStatistics: stats,
            historicalComparison: history,
            tradeSizeBands: bands,
            rows: rows,
            status: status,
            basketTurnoverYuan: display.total,
            quoteCoverage: display.quoteCount,
            minuteCoverage: display.minuteCount,
            paceVsPrevious: display.pacePrevious,
            paceVsAverage: display.paceAverage,
            averageBaselineDays: display.averageDays
        )
    }
}
