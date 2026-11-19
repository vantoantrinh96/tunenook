import Foundation
import MCP
import Network
import Testing
@testable import TuneNook

struct LoopbackHTTPServerTests {
    private func randomPort() -> UInt16 { UInt16.random(in: 49152...65000) }

    /// Starts a server, retrying on a different port if the random pick happens to be taken.
    private func startServer(
        idleTimeout: TimeInterval = 10,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse = { _ in .data(Data("ok".utf8)) }
    ) async throws -> (LoopbackHTTPServer, UInt16) {
        for _ in 0..<20 {
            let port = randomPort()
            let server = LoopbackHTTPServer(port: port, idleTimeout: idleTimeout, handler: handler)
            do {
                try await server.start()
                return (server, port)
            } catch LoopbackHTTPServer.StartError.portInUse {
                continue
            }
        }
        throw LoopbackHTTPServer.StartError.failed("no free port")
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }

    private func rawExchange(port: UInt16, send: Data?) async -> Data {
        let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test.raw")
        return await withCheckedContinuation { cont in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let send { conn.send(content: send, completion: .contentProcessed { _ in }) }
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        if once.fire() { cont.resume(returning: data ?? Data()) }
                        conn.cancel()
                    }
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: Data()) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    @Test func servesARequest() async throws {
        let (server, port) = try await startServer { _ in .data(Data("hello".utf8)) }
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        let (data, response) = try await session().data(for: req)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func boundToLoopbackOnly() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        guard case .hostPort(let host, let boundPort)? = server.localEndpoint else {
            Issue.record("no required local endpoint")
            return
        }
        #expect(host == .ipv4(.loopback))
        #expect(boundPort.rawValue == port)
    }

    @Test func secondServerOnSamePortFails() async throws {
        let (first, port) = try await startServer()
        let second = LoopbackHTTPServer(port: port) { _ in .ok() }
        await #expect(throws: LoopbackHTTPServer.StartError.portInUse) { try await second.start() }
        second.stop()
        first.stop()
        let third = LoopbackHTTPServer(port: port) { _ in .ok() }
        try await third.start()
        third.stop()
    }

    @Test func garbageGets400AndCloses() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let reply = await rawExchange(port: port, send: Data("hello\r\n\r\n".utf8))
        #expect(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
    }

    @Test func silentClientIsDropped() async throws {
        let (server, port) = try await startServer(idleTimeout: 0.3)
        defer { server.stop() }
        let reply = await rawExchange(port: port, send: nil)
        #expect(reply.isEmpty)  // closed by the server without a response
    }

    @Test func stopClosesTheListener() async throws {
        let (server, port) = try await startServer()
        server.stop()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        await #expect(throws: URLError.self) { _ = try await session().data(for: req) }
    }
}

/// Fires exactly once; guards a continuation that several callbacks race to resume.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
