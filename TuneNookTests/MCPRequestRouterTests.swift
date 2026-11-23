import Foundation
import MCP
import os
import SwiftData
import Testing
@testable import TuneNook

/// Drives `MCPRequestRouter` directly (no sockets): the gate, the request chain and the handler deadline.
@MainActor
struct MCPRequestRouterTests {
    let container: ModelContainer
    let defaults: UserDefaults

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        defaults = TestDefaults.make()
    }

    private func makeRouter(deadline: Duration = MCPRequestRouter.defaultDeadline,
                            now: @escaping () -> Date = Date.init) async throws -> MCPRequestRouter {
        let tools = TuneNookTools(
            context: container.mainContext, defaults: defaults, goalStore: GoalStore(defaults: defaults),
            stations: [], isBusy: { _ in false }, deselect: { _ in }, now: now)
        let router = MCPRequestRouter(
            gate: RequestGate(token: "test-token", port: 47821),
            host: MCPServerHost(tools: tools, version: "1"),
            deadline: deadline)
        try await router.start()
        return router
    }

    private nonisolated static func request(id: Int, method: String, params: [String: Any]? = nil) -> HTTPRequest {
        var json: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { json["params"] = params }
        return HTTPRequest(
            method: "POST",
            headers: [
                "Host": "127.0.0.1:47821", "Authorization": "Bearer test-token",
                "Accept": "application/json", "Content-Type": "application/json",
            ],
            body: try! JSONSerialization.data(withJSONObject: json), path: "/mcp")
    }

    private nonisolated static func createTopic(id: Int, name: String) -> HTTPRequest {
        request(id: id, method: "tools/call", params: ["name": "create_topic", "arguments": ["name": name]])
    }

    /// The text of a `tools/call` result, or nil.
    private nonisolated static func toolText(_ response: HTTPResponse) -> String? {
        guard let data = response.bodyData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["result"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return nil }
        return content.first?["text"] as? String
    }

    /// `router.handle`, or nil if it hasn't answered within `seconds`. Unstructured on purpose:
    /// a task group would wait for a request that never completes.
    private nonisolated static func handle(_ router: MCPRequestRouter, _ request: HTTPRequest,
                                           within seconds: Double = 5) async -> HTTPResponse? {
        await withCheckedContinuation { (cont: CheckedContinuation<HTTPResponse?, Never>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (HTTPResponse?) -> Void = { response in
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { cont.resume(returning: response) }
            }
            Task { finish(await router.handle(request)) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
    }

    /// Every client numbers its ids from 0 or 1, and the stateless transport keys its waiters by id alone,
    /// so requests from different clients with the same id must never be in flight together.
    @Test func concurrentRequestsWithTheSameIdEachGetTheirOwnAnswer() async throws {
        let router = try await makeRouter()
        let names = (1...12).map { "Client \($0)" }
        let answers = await withTaskGroup(of: (String, HTTPResponse?).self) { group in
            for name in names {
                group.addTask { (name, await Self.handle(router, Self.createTopic(id: 1, name: name))) }
            }
            var collected: [String: HTTPResponse?] = [:]
            for await (name, response) in group { collected[name] = response }
            return collected
        }
        for name in names {
            guard let response = answers[name] ?? nil else {
                Issue.record("\(name) never got an answer")
                continue
            }
            #expect(response.statusCode == 200)
            let text = try #require(Self.toolText(response))
            let topic = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(topic["name"] as? String == name, "\(name) got another client's answer")
        }
        await router.stop()
    }

    /// A handler over the deadline gets a 503 (so the connection closes and frees its slot), and the
    /// router moves on: the next request is answered normally.
    @Test func handlerOverTheDeadlineGets503AndTheRouterRecovers() async throws {
        let slow = OSAllocatedUnfairLock(initialState: true)
        let router = try await makeRouter(deadline: .milliseconds(200), now: {
            // Blocks the main actor inside the tool call, well past the deadline, on the first call only.
            if slow.withLock({ value in defer { value = false }; return value }) { Thread.sleep(forTimeInterval: 1) }
            return Date()
        })
        // Without a deadline this would be a 200 once the tool finished.
        let response = try #require(await Self.handle(router, Self.createTopic(id: 1, name: "Slow")))
        #expect(response.statusCode == 503)

        let next = try #require(await Self.handle(router, Self.createTopic(id: 1, name: "Next")))
        #expect(next.statusCode == 200)
        let text = try #require(Self.toolText(next))
        #expect(text.contains("Next"))
        await router.stop()
    }
}
