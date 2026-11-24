import Foundation

struct TickBarMCPDispatcher {
    func handle(body: Data, tools: TickBarMCPTools) async -> (status: Int, data: Data) {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = request["method"] as? String else {
            return errorResponse(status: 400, message: "Invalid JSON-RPC request")
        }
        let id = request["id"]
        let hasID = id != nil && !(id is NSNull)

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "TickBar", "version": AppVersion.short],
            ]
            return jsonResponse(id: id, result: result)
        case "notifications/initialized", "initialized":
            return (202, Data())
        case "tools/list":
            let toolsList: [[String: Any]] = [
                [
                    "name": "get_stock_quotes",
                    "description": "Fetch stock quotes by market and codes using TickBar data sources.",
                    "inputSchema": Self.stockSchema,
                ],
                [
                    "name": "get_etf_snapshot",
                    "description": "ETF basket snapshot: turnover totals, historical pace vs previous session and multi-day average, large/medium/small trade-size bands, and per-ETF ranking.",
                    "inputSchema": ["type": "object", "properties": [:]],
                ],
            ]
            return jsonResponse(id: id, result: ["tools": toolsList])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return jsonResponse(id: id, error: "Missing tool name", code: -32602)
            }
            do {
                let payload: String
                switch name {
                case "get_stock_quotes":
                    let args = (params["arguments"] as? [String: Any]) ?? [:]
                    payload = try await tools.getStockQuotes(arguments: args)
                case "get_etf_snapshot":
                    payload = try await tools.getEtfSnapshot()
                default:
                    return toolResult(id: id, text: "Unknown tool: \(name)", isError: true)
                }
                return toolResult(id: id, text: payload, isError: false)
            } catch {
                return toolResult(id: id, text: error.localizedDescription, isError: true)
            }
        default:
            if hasID {
                return jsonResponse(id: id, error: "Method not found: \(method)", code: -32601)
            }
            return (202, Data())
        }
    }

    private static let stockSchema: [String: Any] = [
        "type": "object",
        "required": ["market", "codes"],
        "properties": [
            "market": ["type": "string", "description": "Market: a, hk, us, or kr"],
            "codes": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Up to 20 symbol codes for that market",
            ],
        ],
    ]

    private func toolResult(id: Any?, text: String, isError: Bool) -> (Int, Data) {
        let result: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
        return jsonResponse(id: id, result: result)
    }

    private func jsonResponse(id: Any?, result: [String: Any]) -> (Int, Data) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { envelope["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return errorResponse(status: 500, message: "encode failed")
        }
        return (200, data)
    }

    private func jsonResponse(id: Any?, error message: String, code: Int) -> (Int, Data) {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return errorResponse(status: 500, message: "encode failed")
        }
        return (200, data)
    }

    private func errorResponse(status: Int, message: String) -> (Int, Data) {
        let body: [String: Any] = ["error": message]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(message.utf8)
        return (status, data)
    }
}
