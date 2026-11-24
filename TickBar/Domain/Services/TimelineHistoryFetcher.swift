import Foundation

/// 异步获取分时真实成交历史数据，用于绘制准确的 Sparkline 走势图。
actor TimelineHistoryFetcher {
    static let shared = TimelineHistoryFetcher()

    private var cache: [SymbolID: (timestamp: Date, points: [Double], dates: [Date])] = [:]
    private let cacheTTL: TimeInterval = 60 // 缓存 60 秒，避免高频重复拉取
    private var inFlight: Set<SymbolID> = []

    private let http = HTTPClient(defaultHeaders: [
        "Referer": "https://gu.qq.com/",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ])

    func fetchHistory(for symbol: SymbolID) async -> (points: [Double], dates: [Date])? {
        if let cached = cache[symbol], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return (cached.points, cached.dates)
        }

        guard !inFlight.contains(symbol) else { return nil }
        inFlight.insert(symbol)
        defer { inFlight.remove(symbol) }

        var result: (points: [Double], dates: [Date])?

        switch symbol.market {
        case .a, .hk:
            result = await fetchTencentMinute(for: symbol)
            if result == nil {
                result = await fetchEastmoneyTrends(for: symbol)
            }
        case .us:
            result = await fetchXueqiuMinute(for: symbol)
            if result == nil {
                result = await fetchEastmoneyTrends(for: symbol)
            }
        case .kr, .crypto:
            break
        }

        if let res = result, res.points.count >= 2 {
            cache[symbol] = (Date(), res.points, res.dates)
        }
        return result
    }

    // MARK: - Tencent Minute Query (A股 / 港股)

    private func fetchTencentMinute(for symbol: SymbolID) async -> (points: [Double], dates: [Date])? {
        guard let code = SymbolEncoder.tencent(symbol) else { return nil }
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(code)") else { return nil }

        do {
            let data = try await http.fetchData(url: url, timeout: 3)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let stockDict = dataDict[code] as? [String: Any],
                  let innerData = stockDict["data"] as? [String: Any],
                  let rawList = innerData["data"] as? [String] else { return nil }

            let datePrefix = (innerData["date"] as? String) ?? ""
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd HHmm"
            dateFormatter.timeZone = symbol.market.timeZone

            var rawPrices: [Double] = []
            var rawDates: [Date] = []

            for item in rawList {
                let parts = item.split(separator: " ")
                guard parts.count >= 2,
                      let price = Double(parts[1]), price > 0 else { continue }
                rawPrices.append(price)

                if datePrefix.count >= 8 {
                    let timeStr = String(parts[0])
                    let d = dateFormatter.date(from: "\(datePrefix) \(timeStr)") ?? Date()
                    rawDates.append(d)
                } else {
                    rawDates.append(Date())
                }
            }

            guard rawPrices.count >= 2 else { return nil }
            return Self.downsample(prices: rawPrices, dates: rawDates, targetCount: 48)
        } catch {
            return nil
        }
    }

    // MARK: - Xueqiu Minute (美股)

    private func fetchXueqiuMinute(for symbol: SymbolID) async -> (points: [Double], dates: [Date])? {
        let symStr = symbol.code.uppercased()
        guard let url = URL(string: "https://stock.xueqiu.com/v5/stock/chart/minute.json?symbol=\(symStr)&period=1d") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("https://xueqiu.com/", forHTTPHeaderField: "Referer")
        req.setValue(HTTPClient.defaultUA, forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct XueqiuChartResp: Decodable {
                let data: ChartData?
                struct ChartData: Decodable {
                    let items: [ChartItem]?
                }
                struct ChartItem: Decodable {
                    let current: Double?
                    let timestamp: Double?
                }
            }

            let resp = try JSONDecoder().decode(XueqiuChartResp.self, from: data)
            let items = resp.data?.items ?? []
            var rawPrices: [Double] = []
            var rawDates: [Date] = []

            for it in items {
                guard let p = it.current, p > 0 else { continue }
                rawPrices.append(p)
                if let ms = it.timestamp {
                    rawDates.append(Date(timeIntervalSince1970: ms / 1000.0))
                } else {
                    rawDates.append(Date())
                }
            }

            guard rawPrices.count >= 2 else { return nil }
            return Self.downsample(prices: rawPrices, dates: rawDates, targetCount: 48)
        } catch {
            return nil
        }
    }

    // MARK: - Eastmoney Trends (兜底)

    private func fetchEastmoneyTrends(for symbol: SymbolID) async -> (points: [Double], dates: [Date])? {
        guard let secid = SymbolEncoder.eastMoney(symbol) else { return nil }
        guard let url = URL(string: "https://push2.eastmoney.com/api/qt/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f3,f4&fields2=f51,f53") else { return nil }

        do {
            let data = try await http.fetchData(url: url, headers: ["Referer": "https://quote.eastmoney.com/"], timeout: 3)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let trends = dataDict["trends"] as? [String] else { return nil }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            dateFormatter.timeZone = symbol.market.timeZone

            var rawPrices: [Double] = []
            var rawDates: [Date] = []

            for item in trends {
                let parts = item.split(separator: ",")
                guard parts.count >= 2,
                      let price = Double(parts[1]), price > 0 else { continue }
                rawPrices.append(price)

                let dateStr = String(parts[0])
                let d = dateFormatter.date(from: dateStr) ?? Date()
                rawDates.append(d)
            }

            guard rawPrices.count >= 2 else { return nil }
            return Self.downsample(prices: rawPrices, dates: rawDates, targetCount: 48)
        } catch {
            return nil
        }
    }

    // MARK: - LTTB (Largest-Triangle-Three-Buckets) 降采样，保留分时关键波峰与波谷

    static func downsample(prices: [Double], dates: [Date], targetCount: Int) -> (points: [Double], dates: [Date]) {
        guard prices.count == dates.count,
              prices.count > targetCount,
              targetCount >= 3 else {
            return (prices, dates)
        }

        var sampledPrices: [Double] = []
        var sampledDates: [Date] = []
        sampledPrices.reserveCapacity(targetCount)
        sampledDates.reserveCapacity(targetCount)

        // 始终保留首点
        sampledPrices.append(prices[0])
        sampledDates.append(dates[0])

        let bucketSize = Double(prices.count - 2) / Double(targetCount - 2)
        var a = 0

        for i in 0..<(targetCount - 2) {
            let avgRangeStart = Int(floor(Double(i + 1) * bucketSize)) + 1
            let avgRangeEnd = min(Int(floor(Double(i + 2) * bucketSize)) + 1, prices.count)

            var avgX: Double = 0
            var avgY: Double = 0
            let avgCount = max(avgRangeEnd - avgRangeStart, 1)
            for idx in avgRangeStart..<avgRangeEnd {
                avgX += Double(idx)
                avgY += prices[idx]
            }
            avgX /= Double(avgCount)
            avgY /= Double(avgCount)

            let rangeStart = Int(floor(Double(i) * bucketSize)) + 1
            let rangeEnd = min(Int(floor(Double(i + 1) * bucketSize)) + 1, prices.count - 1)

            let pointAX = Double(a)
            let pointAY = prices[a]

            var maxArea: Double = -1
            var maxAreaIndex = rangeStart

            for idx in rangeStart..<rangeEnd {
                let area = abs((pointAX - avgX) * (prices[idx] - pointAY) - (pointAX - Double(idx)) * (avgY - pointAY)) * 0.5
                if area > maxArea {
                    maxArea = area
                    maxAreaIndex = idx
                }
            }

            sampledPrices.append(prices[maxAreaIndex])
            sampledDates.append(dates[maxAreaIndex])
            a = maxAreaIndex
        }

        // 始终保留末点
        sampledPrices.append(prices[prices.count - 1])
        sampledDates.append(dates[dates.count - 1])

        return (sampledPrices, sampledDates)
    }
}
