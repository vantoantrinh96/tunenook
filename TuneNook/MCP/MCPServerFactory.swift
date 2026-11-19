import Foundation
import MCP

enum MCPServerFactory {
    /// A server named "tunenook" with the tools capability and both handlers registered. Not started.
    static func makeServer(tools: TuneNookTools, version: String) async -> MCP.Server {
        let server = MCP.Server(
            name: "tunenook", version: version,
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await run(params, on: tools)
        }
        return server
    }

    private static func text(_ string: String) -> MCP.Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    private static func run(_ params: CallTool.Parameters, on tools: TuneNookTools) async -> CallTool.Result {
        do {
            let arguments = try JSONEncoder().encode(params.arguments ?? [:])
            let output = try await MainActor.run { try tools.call(params.name, arguments: arguments) }
            return CallTool.Result(content: [text(String(decoding: output, as: UTF8.self))], isError: false)
        } catch let error as ToolError {
            return CallTool.Result(content: [text(error.message)], isError: true)
        } catch {
            return CallTool.Result(content: [text("TuneNook couldn't complete that.")], isError: true)
        }
    }
}

/// Owns the live MCP `Server`. The SDK `Server` accepts one `initialize` for its lifetime and never resets,
/// so each new handshake (a client restart, or a stateless HTTP session) gets a fresh `Server` built by
/// `MCPServerFactory`; the previous one is stopped. At most one server is live at a time.
actor MCPServerHost {
    private let tools: TuneNookTools
    private let version: String
    private var current: MCP.Server?

    init(tools: TuneNookTools, version: String) {
        self.tools = tools
        self.version = version
    }

    /// Stops the current server (if any), builds a fresh one and starts it on `transport`.
    /// Returns once the server is listening; the client then performs its handshake.
    @discardableResult
    func attach(transport: any Transport) async throws -> MCP.Server {
        await current?.stop()
        current = nil
        let server = await MCPServerFactory.makeServer(tools: tools, version: version)
        try await server.start(transport: transport)
        current = server
        return server
    }

    func stop() async {
        await current?.stop()
        current = nil
    }
}
