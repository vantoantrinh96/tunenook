import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct MCPServerControllerTests {
    let container: ModelContainer
    let tools: TuneNookTools
    let defaults: UserDefaults

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        tools = TuneNookTools(
            context: container.mainContext, defaults: defaults, goalStore: GoalStore(defaults: defaults),
            stations: [], isBusy: { _ in false }, deselect: { _ in })
    }

    private func makeController() -> MCPServerController {
        MCPServerController(tools: tools, defaults: defaults)
    }

    private func randomPort() -> Int { Int.random(in: 49152...65000) }

    /// Enables `controller` on a random high port, retrying if the pick happens to be taken.
    private func enableOnFreePort(_ controller: MCPServerController) async throws -> Int {
        for _ in 0..<20 {
            let port = randomPort()
            await controller.setPort(port)
            await controller.setEnabled(true)
            if controller.status == .running(port: port) { return port }
            await controller.setEnabled(false)
        }
        throw LoopbackHTTPServer.StartError.failed("no free port")
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }

    private func body(_ id: Int, _ method: String, _ params: [String: Any]? = nil) -> Data {
        var json: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { json["params"] = params }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func initializeBody(id: Int = 1) -> Data {
        body(id, "initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "test-client", "version": "1.0.0"],
        ])
    }

    /// POSTs `body` to `/mcp`; returns the status code and the decoded JSON body (if any).
    private func post(port: Int, token: String?, body: Data) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: URL(string: MCPConnectionSnippets.url(port: port))!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await session().data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private nonisolated static func postStatus(port: Int, token: String?, body: Data) async throws -> Int {
        var request = URLRequest(url: URL(string: MCPConnectionSnippets.url(port: port))!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let (_, response) = try await URLSession(configuration: config).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func listedToolCount(port: Int, token: String, id: Int = 2) async throws -> Int? {
        let (status, json) = try await post(port: port, token: token, body: body(id, "tools/list"))
        #expect(status == 200)
        return ((json?["result"] as? [String: Any])?["tools"] as? [Any])?.count
    }

    @Test func offByDefaultWithNoToken() async {
        let controller = makeController()
        #expect(controller.status == .off)
        #expect(controller.isEnabled == false)
        #expect(controller.port == MCPServerController.defaultPort)
        #expect(controller.token.isEmpty)
        await controller.startIfEnabled()
        #expect(controller.status == .off)
        #expect(controller.token.isEmpty)
    }

    @Test func enablingCreatesATokenAndRuns() async throws {
        let controller = makeController()
        let port = try await enableOnFreePort(controller)
        #expect(controller.token.count == 43)
        #expect(controller.token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(controller.status == .running(port: port))
        #expect(defaults.bool(forKey: MCPServerController.Key.enabled))
        #expect(defaults.integer(forKey: MCPServerController.Key.port) == port)
        #expect(defaults.string(forKey: MCPServerController.Key.token) == controller.token)
        await controller.setEnabled(false)
    }

    @Test func persistedSettingsRestoreOnLaunch() async throws {
        let first = makeController()
        let port = try await enableOnFreePort(first)
        let token = first.token
        await first.setEnabled(true)  // already enabled: keeps the token
        #expect(first.token == token)
        await first.setEnabled(false)
        defaults.set(true, forKey: MCPServerController.Key.enabled)

        let second = makeController()
        #expect(second.isEnabled)
        #expect(second.port == port)
        #expect(second.token == token)
        await second.startIfEnabled()
        #expect(second.status == .running(port: port))
        await second.setEnabled(false)
    }

    @Test func endToEndOverHTTP() async throws {
        let controller = makeController()
        let port = try await enableOnFreePort(controller)
        let token = controller.token

        let (status, json) = try await post(port: port, token: token, body: initializeBody())
        #expect(status == 200)
        let serverInfo = (json?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "tunenook")

        let (unauthorized, _) = try await post(port: port, token: nil, body: initializeBody())
        #expect(unauthorized == 401)

        #expect(try await listedToolCount(port: port, token: token) == 12)
        await controller.setEnabled(false)
    }

    /// A client that initialized before the app relaunched keeps its session and sends no new `initialize`.
    @Test func toolsListWithoutInitializeWorks() async throws {
        let controller = makeController()
        let port = try await enableOnFreePort(controller)
        #expect(try await listedToolCount(port: port, token: controller.token) == 12)
        await controller.setEnabled(false)
    }

    @Test func concurrentInitializesLeaveAWorkingServer() async throws {
        let controller = makeController()
        let port = try await enableOnFreePort(controller)
        let token = controller.token
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 1...8 {
                let request = initializeBody(id: id)
                group.addTask { try await Self.postStatus(port: port, token: token, body: request) }
            }
            var collected: [Int] = []
            for try await status in group { collected.append(status) }
            return collected
        }
        #expect(statuses == Array(repeating: 200, count: 8))
        #expect(try await listedToolCount(port: port, token: token, id: 9) == 12)
        await controller.setEnabled(false)
    }

    @Test func disablingStopsListening() async throws {
        let controller = makeController()
        let port = try await enableOnFreePort(controller)
        let token = controller.token
        await controller.setEnabled(false)
        #expect(controller.status == .off)
        #expect(controller.isEnabled == false)
        #expect(defaults.bool(forKey: MCPServerController.Key.enabled) == false)
        await #expect(throws: (any Error).self) {
            _ = try await post(port: port, token: token, body: initializeBody())
        }
    }

    @Test func regenerateInvalidatesTheOldToken() async throws {
        let controller = makeController()
        let port = try await enableOnFreePort(controller)
        let old = controller.token
        await controller.regenerateToken()
        let new = controller.token
        #expect(new != old)
        #expect(new.count == 43)
        #expect(defaults.string(forKey: MCPServerController.Key.token) == new)
        #expect(controller.status == .running(port: port))
        #expect(try await post(port: port, token: old, body: initializeBody()).0 == 401)
        #expect(try await post(port: port, token: new, body: initializeBody()).0 == 200)
        await controller.setEnabled(false)
    }

    @Test func portInUseShowsFailureAndRecovers() async throws {
        var squatter: LoopbackHTTPServer?
        var port = 0
        for _ in 0..<20 {
            port = randomPort()
            let candidate = LoopbackHTTPServer(port: UInt16(port)) { _ in .ok() }
            if (try? await candidate.start()) != nil {
                squatter = candidate
                break
            }
        }
        let occupier = try #require(squatter)

        let controller = makeController()
        await controller.setPort(port)
        await controller.setEnabled(true)
        #expect(controller.status == .failed("Port \(port) is in use by another app. Choose another port."))
        #expect(controller.isEnabled)

        await Task.detached { occupier.stop() }.value
        await controller.setEnabled(false)
        await controller.setEnabled(true)
        #expect(controller.status == .running(port: port))
        #expect(try await post(port: port, token: controller.token, body: initializeBody()).0 == 200)
        await controller.setEnabled(false)
    }

    @Test func changingPortWhileRunningMoves() async throws {
        let controller = makeController()
        let oldPort = try await enableOnFreePort(controller)
        // Retry if the random pick happens to be taken, so the HTTP checks always run.
        var newPort = oldPort
        for _ in 0..<20 {
            newPort = randomPort()
            guard newPort != oldPort else { continue }
            await controller.setPort(newPort)
            if controller.status == .running(port: newPort) { break }
        }
        #expect(controller.status == .running(port: newPort))
        #expect(controller.port == newPort)
        #expect(defaults.integer(forKey: MCPServerController.Key.port) == newPort)
        #expect(try await post(port: newPort, token: controller.token, body: initializeBody()).0 == 200)
        await #expect(throws: (any Error).self) {
            _ = try await post(port: oldPort, token: controller.token, body: initializeBody())
        }
        await controller.setEnabled(false)
    }

    @Test func outOfRangePortIsIgnored() async {
        let controller = makeController()
        let port = randomPort()
        await controller.setPort(port)
        await controller.setPort(80)
        #expect(controller.port == port)
        await controller.setPort(70000)
        #expect(controller.port == port)
        #expect(defaults.integer(forKey: MCPServerController.Key.port) == port)
    }

    /// The gate would accept `Bearer ` if the token were empty, so an enabled server with no stored token
    /// gets a fresh one before it serves.
    @Test func neverServesWithAnEmptyToken() async throws {
        // Retry if the random pick happens to be taken, so the HTTP check always runs.
        var port = 0
        var controller = makeController()
        for _ in 0..<20 {
            port = randomPort()
            defaults.set(true, forKey: MCPServerController.Key.enabled)
            defaults.set(port, forKey: MCPServerController.Key.port)
            defaults.set("", forKey: MCPServerController.Key.token)
            controller = makeController()
            #expect(controller.token.isEmpty)
            await controller.startIfEnabled()
            #expect(controller.token.count == 43)
            if controller.status == .running(port: port) { break }
            await controller.setEnabled(false)
        }
        try #require(controller.status == .running(port: port))
        #expect(try await post(port: port, token: "", body: initializeBody()).0 == 401)
        await controller.setEnabled(false)
    }

    @Test func snippets() throws {
        #expect(MCPConnectionSnippets.url(port: 47821) == "http://127.0.0.1:47821/mcp")
        #expect(
            MCPConnectionSnippets.claudeCodeCommand(port: 47821, token: "test-token")
                == "claude mcp add --transport http tunenook http://127.0.0.1:47821/mcp --header \"Authorization: Bearer test-token\"")
        let config = MCPConnectionSnippets.jsonConfig(port: 47821, token: "test-token")
        #expect(config.contains("\n"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let server = try #require((json["mcpServers"] as? [String: Any])?["tunenook"] as? [String: Any])
        #expect(server["type"] as? String == "http")
        #expect(server["url"] as? String == "http://127.0.0.1:47821/mcp")
        #expect((server["headers"] as? [String: String])?["Authorization"] == "Bearer test-token")
    }
}
