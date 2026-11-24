import Foundation

/// Local MCP entry point. Disabled by default; no HTTP listener until enabled in Settings.
@MainActor
final class TickBarMCPService {
    private weak var container: DependencyContainer?
    private var quoteBroker: MCPQuoteBroker?
    private var tools: TickBarMCPTools?
    private var httpServer: MCPHTTPServer?
    private var serverTask: Task<Void, Never>?
    private(set) var lastError: String?
    private(set) var isRunning = false

    func attach(_ container: DependencyContainer) {
        self.container = container
        let broker = MCPQuoteBroker(orchestrator: container.orchestrator)
        quoteBroker = broker
        let tools = TickBarMCPTools(quoteBroker: broker)
        tools.bind(container)
        self.tools = tools
    }

    func reconcile(enabled: Bool) {
        if enabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        httpServer?.shutdown()
        httpServer = nil
        isRunning = false
    }

    private func startIfNeeded() {
        guard serverTask == nil else { return }
        guard tools != nil else {
            lastError = "MCP is not initialized"
            return
        }
        _ = MCPTokenStore.ensureToken()
        lastError = nil
        serverTask = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        guard let tools else { return }
        let dispatcher = TickBarMCPDispatcher()
        let server = MCPHTTPServer { request in
            await Self.handle(request: request, dispatcher: dispatcher, tools: tools)
        }
        do {
            try server.start(host: TickBarMCPConfig.host, port: TickBarMCPConfig.port)
            httpServer = server
            isRunning = true
            Log.app.info("MCP listening on \(TickBarMCPConfig.endpointURL, privacy: .public)")
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            lastError = String(describing: error)
            isRunning = false
            Log.app.error("MCP server failed: \(String(describing: error), privacy: .public)")
        }
        httpServer?.shutdown()
        httpServer = nil
        isRunning = false
    }

    private static func handle(
        request: MCPHTTPIncomingRequest,
        dispatcher: TickBarMCPDispatcher,
        tools: TickBarMCPTools
    ) async -> MCPHTTPOutgoingResponse {
        guard request.method == "POST", request.path == TickBarMCPConfig.path else {
            return MCPHTTPOutgoingResponse(status: 404, body: Data("Not Found".utf8))
        }
        guard TickBarMCPHTTPPolicy.allows(request) else {
            return MCPHTTPOutgoingResponse(status: 403, body: Data("Forbidden".utf8))
        }
        guard let token = MCPTokenStore.load(),
              request.bearerToken == token else {
            return MCPHTTPOutgoingResponse(status: 401, body: Data("Unauthorized".utf8))
        }
        let (status, data) = await dispatcher.handle(body: request.body, tools: tools)
        if status == 202 {
            return MCPHTTPOutgoingResponse(status: 202, body: Data())
        }
        return MCPHTTPOutgoingResponse(status: status, body: data, json: true)
    }
}

enum TickBarMCPHTTPPolicy {
    static func allows(_ request: MCPHTTPIncomingRequest) -> Bool {
        let host = request.header("Host")?.split(separator: ":").first.map(String.init) ?? ""
        guard host == "127.0.0.1" || host == "localhost" else { return false }
        if let origin = request.header("Origin"), !origin.isEmpty {
            let lower = origin.lowercased()
            guard lower.hasPrefix("http://127.0.0.1")
                || lower.hasPrefix("http://localhost")
                || lower.hasPrefix("https://127.0.0.1")
                || lower.hasPrefix("https://localhost") else { return false }
        }
        let contentType = request.header("Content-Type")?.split(separator: ";").first.map(String.init) ?? ""
        guard contentType == "application/json" else { return false }
        let accept = request.header("Accept") ?? ""
        return accept.contains("application/json")
    }
}
