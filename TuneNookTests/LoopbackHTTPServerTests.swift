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

    @Test func seventeenthConnectionIsClosedWhileFirstSixteenAreServed() async throws {
        let gate = HandlerGate()
        let (server, port) = try await startServer { _ in
            await gate.enter()
            return .data(Data("ok".utf8))
        }
        defer { server.stop() }
        let request = Data("GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n".utf8)

        var clients: [RawClient] = []
        for _ in 0..<LoopbackHTTPServer.maxConnections {
            let c = RawClient(port: port)
            try await c.connect()
            c.send(request)
            clients.append(c)
        }
        await gate.waitUntilEntered(LoopbackHTTPServer.maxConnections)

        let extra = RawClient(port: port)
        try? await extra.connect()
        #expect(await extra.readToEnd().isEmpty)

        await gate.release()
        for c in clients {
            #expect(String(decoding: await c.readToEnd(), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        }
    }

    @Test func slowBodyInSmallChunksIsServed() async throws {
        let (server, port) = try await startServer { req in .data(req.body ?? Data()) }
        defer { server.stop() }
        let body = String(repeating: "x", count: 200)
        let c = RawClient(port: port)
        try await c.connect()
        c.send(Data("POST /mcp HTTP/1.1\r\nContent-Length: 200\r\n\r\n".utf8))
        for ch in body { c.send(Data(String(ch).utf8)) }
        let reply = String(decoding: await c.readToEnd(), as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 200"))
        #expect(reply.hasSuffix(body))
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

private actor HandlerGate {
    private var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiter: (Int, CheckedContinuation<Void, Never>)?

    func enter() async {
        entered += 1
        if let (n, cont) = enteredWaiter, entered >= n { enteredWaiter = nil; cont.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered(_ n: Int) async {
        if entered >= n { return }
        await withCheckedContinuation { enteredWaiter = (n, $0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class RawClient: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "test.rawclient")

    init(port: UInt16) {
        conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                case .cancelled: if once.fire() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ data: Data) { conn.send(content: data, completion: .contentProcessed { _ in }) }

    /// Reads until the peer closes (or the connection errors).
    func readToEnd() async -> Data {
        var all = Data()
        while true {
            let (chunk, done): (Data?, Bool) = await withCheckedContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    cont.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let chunk { all.append(chunk) }
            if done { break }
        }
        conn.cancel()
        return all
    }
}
