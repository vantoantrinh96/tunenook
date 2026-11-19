import Foundation
import MCP
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct MCPAdapterTests {
    let container: ModelContainer
    let tools: TuneNookTools

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        tools = TuneNookTools(
            context: container.mainContext, defaults: defaults, goalStore: GoalStore(defaults: defaults),
            stations: [], isBusy: { _ in false }, deselect: { _ in })
    }

    /// Starts `server` on one end of an in-memory pair and returns a connected, initialized client.
    func connectClient(to server: MCP.Server) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    func text(_ content: [MCP.Tool.Content]) throws -> String {
        guard case .text(let text, _, _) = try #require(content.first) else {
            Issue.record("expected text content")
            return ""
        }
        return text
    }

    @Test func catalogMatchesToolLayer() {
        #expect(MCPToolCatalog.tools.map(\.name) == TuneNookTools.toolNames)
        for tool in MCPToolCatalog.tools {
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object", "\(tool.name)")
            #expect(tool.inputSchema.objectValue?["properties"]?.objectValue != nil, "\(tool.name)")
            #expect(tool.inputSchema.objectValue?["required"]?.arrayValue != nil, "\(tool.name)")
            #expect(tool.description?.isEmpty == false, "\(tool.name)")
            #expect(tool.annotations.openWorldHint == false, "\(tool.name)")
        }
        let readOnly = Set(MCPToolCatalog.tools.filter { $0.annotations.readOnlyHint == true }.map(\.name))
        #expect(readOnly == ["list_topics", "list_tasks", "get_settings", "list_sessions", "get_progress"])
        let destructive = Set(MCPToolCatalog.tools.filter { $0.annotations.destructiveHint == true }.map(\.name))
        #expect(destructive == ["delete_topic", "delete_task"])
    }

    @Test func listToolsOverMCP() async throws {
        let server = await MCPServerFactory.makeServer(tools: tools, version: "1.0.0")
        let client = try await connectClient(to: server)
        let (listed, _) = try await client.listTools()
        #expect(listed.count == 12)
        #expect(listed.map(\.name) == TuneNookTools.toolNames)
        await client.disconnect()
        await server.stop()
    }

    @Test func callToolRoundTrip() async throws {
        let server = await MCPServerFactory.makeServer(tools: tools, version: "1.0.0")
        let client = try await connectClient(to: server)
        let created = try await client.callTool(name: "create_topic", arguments: ["name": "Thesis"])
        #expect(created.isError != true)
        let (content, isError) = try await client.callTool(name: "list_topics", arguments: [:])
        #expect(isError != true)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
        let topics = try #require(json["topics"] as? [[String: Any]])
        #expect(topics.count == 1)
        #expect(topics.first?["name"] as? String == "Thesis")
        await client.disconnect()
        await server.stop()
    }

    @Test func toolErrorBecomesIsError() async throws {
        let server = await MCPServerFactory.makeServer(tools: tools, version: "1.0.0")
        let client = try await connectClient(to: server)
        let (content, isError) = try await client.callTool(name: "create_task", arguments: ["title": "A"])
        #expect(isError == true)
        #expect(try text(content).contains("topic"))
        await client.disconnect()
        await server.stop()
    }

    /// The SDK `Server` refuses a second `initialize` ("Server is already initialized"), so a restarted
    /// client needs a fresh server; `MCPServerHost` provides one per handshake.
    @Test func secondInitializeSucceeds() async throws {
        let host = MCPServerHost(tools: tools, version: "1.0.0")
        for _ in 0..<2 {
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            try await host.attach(transport: serverTransport)
            let client = Client(name: "test-client", version: "1.0.0")
            _ = try await client.connect(transport: clientTransport)
            let (listed, _) = try await client.listTools()
            #expect(listed.count == 12)
            await client.disconnect()
        }
        await host.stop()
    }

    @Test func sameServerRefusesSecondInitialize() async throws {
        let server = await MCPServerFactory.makeServer(tools: tools, version: "1.0.0")
        let first = try await connectClient(to: server)
        await first.disconnect()
        await server.stop()
        await #expect(throws: (any Error).self) { _ = try await connectClient(to: server) }
        await server.stop()
    }
}
