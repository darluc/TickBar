import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

enum TickBarMCPConfig {
    static let host = "127.0.0.1"
    static let port = 18766
    static let path = "/mcp"
    static var endpointURL: String { "http://\(host):\(port)\(path)" }
}

struct MCPHTTPIncomingRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var bearerToken: String? {
        guard let value = header("Authorization"), value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst(7))
    }
}

struct MCPHTTPOutgoingResponse {
    let status: Int
    let body: Data
    let json: Bool

    init(status: Int, body: Data, json: Bool = false) {
        self.status = status
        self.body = body
        self.json = json
    }
}

final class MCPHTTPServer {
    private let handler: @Sendable (MCPHTTPIncomingRequest) async -> MCPHTTPOutgoingResponse
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    init(handler: @escaping @Sendable (MCPHTTPIncomingRequest) async -> MCPHTTPOutgoingResponse) {
        self.handler = handler
    }

    func start(host: String, port: Int) throws {
        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(MCPHTTPChannelHandler(handler: handler))
                }
            }
        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    func shutdown() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class MCPHTTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: @Sendable (MCPHTTPIncomingRequest) async -> MCPHTTPOutgoingResponse
    private var requestHead: HTTPRequestHead?
    private var body = Data()

    init(handler: @escaping @Sendable (MCPHTTPIncomingRequest) async -> MCPHTTPOutgoingResponse) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            if let chunk = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: chunk)
            }
        case .end:
            guard let head = requestHead else { return }
            let headers = Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name.lowercased(), $0.value) })
            let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
            let incoming = MCPHTTPIncomingRequest(
                method: head.method.rawValue,
                path: path,
                headers: headers,
                body: body
            )
            let handler = self.handler
            let loop = context.eventLoop
            Task {
                let response = await handler(incoming)
                loop.execute {
                    Self.write(response: response, context: context)
                }
            }
        }
    }

    private static func write(response: MCPHTTPOutgoingResponse, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        if response.json {
            headers.add(name: "content-type", value: "application/json")
        }
        headers.add(name: "content-length", value: "\(response.body.count)")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        ))), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
