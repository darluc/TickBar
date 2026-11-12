import Foundation

/// 搜索结果的一条匹配。
struct SymbolSearchResult: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let symbol: SymbolID
    let name: String

    init(symbol: SymbolID, name: String) {
        self.id = symbol.description
        self.symbol = symbol
        self.name = name
    }
}

/// 用腾讯 smartbox 做股票搜索(代码 / 名称 / 拼音)。
/// 接口:`https://smartbox.gtimg.cn/s3/?v=2&q={query}&t=all&c=1`
///
/// 返回(GBK):
///   `v_hint="us~aapl.oq~\u82f9\u679c~pg~GP^hk~00700~\u817e\u8baf\u63a7\u80a1~txkg~GP^...";`
///
/// 格式说明:
///   - items 用 `^` 分隔
///   - 每个 item 5 字段用 `~` 分隔:
///       [0] market = sh / sz / hk / us
///       [1] code   = 数字 / "aapl.oq"
///       [2] name   = JSON \uXXXX 转义的中文
///       [3] pinyin abbrev
///       [4] type   = GP / GP-A(股票)/ ZS(指数)/ QZ(权证)/ JJ(基金)
///
///   - 空结果:`v_hint="N";`
final class SymbolSearch: Sendable {
    let http: HTTPClient

    /// 允许的「非股票」类型:基金 / ETF / LOF / 可转债。
    private static let allowedFundTypes: Set<String> = ["ETF", "LOF", "JJ", "ZQ"]

    /// 是否保留该 type。
    /// 股票类用 "GP" 前缀匹配:腾讯对不同板块返回不同后缀(主板 / 创业板 GP-A、
    /// B 股 GP-B、科创板 GP-A-KCB 等),写死全集会漏掉子类型 —— 科创板的
    /// GP-A-KCB 此前就不在白名单里,导致寒武纪(688256)等整个科创板搜不到。
    /// 过滤掉 ZS(指数,大盘里展示)/ QZ(权证)/ KJ(场外基金,无实时行情)等。
    private static func isAllowedType(_ type: String) -> Bool {
        type.hasPrefix("GP") || allowedFundTypes.contains(type)
    }

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://gu.qq.com/"])) {
        self.http = http
    }

    func search(_ query: String) async throws -> [SymbolSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        async let tencentTask = searchTencent(trimmed)
        async let naverTask = searchNaver(trimmed)
        let cryptoResults = searchCrypto(trimmed)

        let tResults = await tencentTask
        let nResults = await naverTask

        // 判断用户输入的特征:
        // 1) 韩文 / 6位数字 -> 韩股优先
        // 2) 包含 USDT / 纯英文代币匹配 -> Crypto 优先
        // 3) 其他 -> 国内/美股优先
        let isKorean = trimmed.range(of: "\\p{Hangul}", options: .regularExpression) != nil
        let isKoreanCode = trimmed.count == 6 && trimmed.allSatisfy { $0.isNumber }
        let isCryptoIntent = trimmed.uppercased().hasSuffix("USDT") || (!cryptoResults.isEmpty && trimmed.allSatisfy { $0.isLetter })

        var out: [SymbolSearchResult] = []
        var seen = Set<String>()

        func appendList(_ list: [SymbolSearchResult]) {
            for item in list {
                if seen.insert(item.symbol.storageKey).inserted {
                    out.append(item)
                }
            }
        }

        if isCryptoIntent {
            appendList(cryptoResults)
            appendList(tResults)
            appendList(nResults)
        } else if isKorean || isKoreanCode {
            appendList(nResults)
            appendList(tResults)
            appendList(cryptoResults)
        } else {
            appendList(tResults)
            appendList(cryptoResults)
            appendList(nResults)
        }

        return Array(out.prefix(35))
    }

    /// 币安 Binance 主流加密货币智能匹配
    private func searchCrypto(_ query: String) -> [SymbolSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return [] }

        struct CryptoToken {
            let symbol: String // e.g. "BTC"
            let name: String   // e.g. "Bitcoin 比特币"
        }

        let presets: [CryptoToken] = [
            CryptoToken(symbol: "BTC", name: "Bitcoin 比特币"),
            CryptoToken(symbol: "ETH", name: "Ethereum 以太坊"),
            CryptoToken(symbol: "SOL", name: "Solana"),
            CryptoToken(symbol: "BNB", name: "BNB 币安币"),
            CryptoToken(symbol: "DOGE", name: "Dogecoin 狗狗币"),
            CryptoToken(symbol: "XRP", name: "Ripple 瑞波币"),
            CryptoToken(symbol: "ADA", name: "Cardano 艾达币"),
            CryptoToken(symbol: "SUI", name: "Sui"),
            CryptoToken(symbol: "PEPE", name: "Pepe"),
            CryptoToken(symbol: "SHIB", name: "Shiba Inu 柴犬币"),
            CryptoToken(symbol: "AVAX", name: "Avalanche 雪崩"),
            CryptoToken(symbol: "LINK", name: "Chainlink"),
            CryptoToken(symbol: "DOT", name: "Polkadot 波卡"),
            CryptoToken(symbol: "TRX", name: "TRON 波场"),
            CryptoToken(symbol: "NEAR", name: "NEAR Protocol"),
            CryptoToken(symbol: "APT", name: "Aptos"),
            CryptoToken(symbol: "TON", name: "Toncoin"),
            CryptoToken(symbol: "UNI", name: "Uniswap"),
            CryptoToken(symbol: "ARB", name: "Arbitrum"),
            CryptoToken(symbol: "OP", name: "Optimism"),
            CryptoToken(symbol: "TIA", name: "Celestia"),
            CryptoToken(symbol: "RENDER", name: "Render"),
            CryptoToken(symbol: "WIF", name: "dogwifhat"),
            CryptoToken(symbol: "FTM", name: "Fantom"),
            CryptoToken(symbol: "LTC", name: "Litecoin 莱特币"),
            CryptoToken(symbol: "BCH", name: "Bitcoin Cash"),
            CryptoToken(symbol: "XLM", name: "Stellar 恒星币"),
            CryptoToken(symbol: "ETC", name: "Ethereum Classic")
        ]

        var results: [SymbolSearchResult] = []

        // 1. 精确与模糊匹配预置代币
        for token in presets {
            let rawCode = token.symbol
            let pair = "\(rawCode)USDT"
            let match = rawCode == q || pair == q || rawCode.hasPrefix(q) || token.name.localizedCaseInsensitiveContains(q)
            if match {
                let sid = SymbolID(code: pair, market: .crypto)
                results.append(SymbolSearchResult(symbol: sid, name: "\(token.name) (\(rawCode)/USDT)"))
            }
        }

        // 2. 如果用户直接输入形如 "XYZ" 或 "XYZUSDT"，生成动态推荐
        let isPureAlpha = q.allSatisfy { $0.isLetter }
        if isPureAlpha && q.count >= 2 && q.count <= 10 {
            let pair = q.hasSuffix("USDT") ? q : "\(q)USDT"
            let base = q.hasSuffix("USDT") ? String(q.dropLast(4)) : q
            let sid = SymbolID(code: pair, market: .crypto)
            if !results.contains(where: { $0.symbol == sid }) {
                results.append(SymbolSearchResult(symbol: sid, name: "\(base)/USDT (Binance)"))
            }
        }

        return results
    }

    private func searchTencent(_ trimmed: String) async -> [SymbolSearchResult] {
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://smartbox.gtimg.cn/s3/?v=2&q=\(encoded)&t=all&c=1") else { return [] }
        do {
            let text = try await http.fetchString(url: url, encoding: GBKDecoder.encoding)
            return parse(text)
        } catch {
            return []
        }
    }

    private func searchNaver(_ query: String) async -> [SymbolSearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://ac.stock.naver.com/ac?q=\(encoded)&target=stock") else { return [] }

        struct NaverSearchResp: Decodable {
            struct Item: Decodable {
                let code: String?
                let name: String?
                let typeCode: String?
                let nationCode: String?
            }
            let items: [Item]?
        }

        do {
            let data = try await http.fetchData(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "application/json,text/plain,*/*",
                "Referer": "https://m.stock.naver.com/"
            ], timeout: 6)
            guard let resp = try? JSONDecoder().decode(NaverSearchResp.self, from: data),
                  let items = resp.items else { return [] }

            var results: [SymbolSearchResult] = []
            for it in items {
                guard let code = it.code, !code.isEmpty else { continue }
                let isKR = it.nationCode == "KOR" || ["KOSPI", "KOSDAQ", "KONEX"].contains(it.typeCode?.uppercased() ?? "")
                guard isKR else { continue }
                let sid = SymbolID(code: code, market: .kr)
                let name = it.name ?? code
                results.append(SymbolSearchResult(symbol: sid, name: name))
            }
            return results
        } catch {
            Log.quote.warning("Naver search failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func parse(_ raw: String) -> [SymbolSearchResult] {
        guard let eqIdx = raw.firstIndex(of: "=") else { return [] }
        let after = raw[raw.index(after: eqIdx)...]
        let stripped = after.trimmingCharacters(in: CharacterSet(charactersIn: " ;\"\n\r"))
        // 空结果用 "N" 标识
        if stripped.isEmpty || stripped == "N" { return [] }

        let items = stripped.split(separator: "^").map(String.init)
        var seen = Set<String>()
        var out: [SymbolSearchResult] = []

        for item in items {
            let fields = item.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            let marketStr = fields[0]
            let rawCode = fields[1]
            let nameRaw = fields[2]
            let type = fields[4]

            guard Self.isAllowedType(type) else { continue }
            guard let sid = decodeSymbol(market: marketStr, rawCode: rawCode) else { continue }
            if !seen.insert(sid.storageKey).inserted { continue }

            let name = decodeJSONString(nameRaw)
            out.append(SymbolSearchResult(symbol: sid, name: name.isEmpty ? sid.code : name))
            if out.count >= 30 { break }
        }
        return out
    }

    private func decodeSymbol(market: String, rawCode: String) -> SymbolID? {
        let m = market.lowercased()
        let code = rawCode.trimmingCharacters(in: .whitespaces)
        switch m {
        case "sh", "sz":
            return SymbolID(code: code, market: .a)
        case "hk":
            // HK 5 位数,前导补零(腾讯可能返回 "00700" 或 "700")
            let padded = code.leftPadded(toLength: 5, withPad: "0")
            return SymbolID(code: padded, market: .hk)
        case "us":
            // 去掉 .oq / .n / .ps 等后缀,转大写
            let body: String
            if let dot = code.firstIndex(of: ".") {
                body = String(code[..<dot])
            } else {
                body = code
            }
            return SymbolID(code: body.uppercased(), market: .us)
        default:
            return nil
        }
    }

    /// 解码 JSON 风格的 \uXXXX 转义。
    /// 包一层引号丢给 JSONDecoder 是最稳的做法。
    private func decodeJSONString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        let wrapped = "\"\(escaped)\""
        guard let data = wrapped.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return s
        }
        return decoded
    }
}
