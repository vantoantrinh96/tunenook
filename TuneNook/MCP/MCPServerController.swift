import Foundation
import MCP
import Observation
import Security

/// Owns the local MCP server: whether it is on, its port and bearer token, and its status.
/// Every change is applied in order; a failure shows up in `status` and never throws.
@MainActor @Observable
final class MCPServerController {
    enum Status: Equatable {
        case off, starting, running(port: Int), failed(String)
    }

    static let defaultPort = 47821
    static let portRange = 1024...65535

    enum Key {
        static let enabled = "mcp.enabled"
        static let port = "mcp.port"
        static let token = "mcp.token"
    }

    private(set) var status: Status = .off
    private(set) var isEnabled: Bool
    private(set) var port: Int
    private(set) var token: String

    @ObservationIgnored private let tools: TuneNookTools
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let version: String
    @ObservationIgnored private var listener: LoopbackHTTPServer?
    @ObservationIgnored private var router: MCPRequestRouter?
    /// The last queued apply; each apply waits for the previous one so starts and stops never interleave.
    @ObservationIgnored private var lastApply: Task<Void, Never>?

    init(tools: TuneNookTools, defaults: UserDefaults = .standard) {
        self.tools = tools
        self.defaults = defaults
        self.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        isEnabled = defaults.bool(forKey: Key.enabled)
        if let stored = defaults.object(forKey: Key.port) as? Int, Self.portRange.contains(stored) {
            port = stored
        } else {
            port = Self.defaultPort
        }
        token = defaults.string(forKey: Key.token) ?? ""
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled { ensureToken() }
        await apply()
    }

    /// Ignores values outside `portRange`; restarts the server if it is enabled.
    func setPort(_ newPort: Int) async {
        guard Self.portRange.contains(newPort), newPort != port else { return }
        port = newPort
        defaults.set(newPort, forKey: Key.port)
        if isEnabled { await apply() }
    }

    /// Replaces the token, so clients holding the old one are refused; restarts the server if it is enabled.
    func regenerateToken() async {
        storeToken(Self.makeToken())
        if isEnabled { await apply() }
    }

    /// Called once at launch.
    func startIfEnabled() async {
        guard isEnabled else { return }
        ensureToken()
        await apply()
    }

    // MARK: - Token

    private func ensureToken() {
        if token.isEmpty { storeToken(Self.makeToken()) }
    }

    private func storeToken(_ newToken: String) {
        token = newToken
        defaults.set(newToken, forKey: Key.token)
    }

    /// 32 random bytes, base64url without padding (43 characters).
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Start / stop

    /// Brings the server in line with the current settings: stops whatever runs, then starts if enabled.
    private func apply() async {
        let previous = lastApply
        let task = Task { @MainActor in
            await previous?.value
            await self.stopServer()
            if self.isEnabled {
                await self.startServer()
            } else {
                self.status = .off
            }
        }
        lastApply = task
        await task.value
    }

    private func startServer() async {
        // The gate would accept "Bearer " for an empty token, so never serve without one.
        guard !token.isEmpty else {
            status = .failed("Couldn't start the server.")
            return
        }
        status = .starting
        let port = port
        let router = MCPRequestRouter(
            gate: RequestGate(token: token, port: port),
            host: MCPServerHost(tools: tools, version: version))
        do {
            // A live server from the start, so a client whose session predates this launch keeps working.
            try await router.start()
        } catch {
            status = .failed("Couldn't start the server.")
            return
        }
        // A failed LoopbackHTTPServer can't be restarted, so every start gets a new one.
        let listener = LoopbackHTTPServer(port: UInt16(port)) { request in
            await router.handle(request)
        }
        do {
            try await listener.start()
            self.listener = listener
            self.router = router
            status = .running(port: port)
        } catch {
            await Self.stopOffMain(listener)
            await router.stop()
            if case LoopbackHTTPServer.StartError.portInUse = error {
                status = .failed("Port \(port) is in use by another app. Choose another port.")
            } else {
                status = .failed("Couldn't start the server.")
            }
        }
    }

    private func stopServer() async {
        let listener = listener
        let router = router
        self.listener = nil
        self.router = nil
        if let listener { await Self.stopOffMain(listener) }
        await router?.stop()
    }

    /// `LoopbackHTTPServer.stop()` blocks for up to a second while the port is released.
    private nonisolated static func stopOffMain(_ listener: LoopbackHTTPServer) async {
        await Task.detached { listener.stop() }.value
    }
}

/// Puts each HTTP request through the gate, then hands it to the MCP server's transport.
/// An `initialize` request gets a fresh server and transport (the SDK server accepts one handshake);
/// handshakes run one at a time so overlapping ones never leave two servers running.
actor MCPRequestRouter {
    private let gate: RequestGate
    private let host: MCPServerHost
    private var transport: StatelessHTTPServerTransport?
    private var stopped = false
    /// The last queued handshake; each one waits for the previous to finish.
    private var lastHandshake: Task<HTTPResponse, Never>?

    init(gate: RequestGate, host: MCPServerHost) {
        self.gate = gate
        self.host = host
    }

    /// Attaches a first server so requests work before any `initialize`.
    func start() async throws {
        let fresh = StatelessHTTPServerTransport()
        try await host.attach(transport: fresh)
        transport = fresh
    }

    func stop() async {
        stopped = true
        transport = nil
        await host.stop()
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = gate.rejection(for: request) { return rejection }
        if Self.isInitialize(request.body) { return await handshake(request) }
        guard let transport else { return Self.unavailable }
        return await transport.handleRequest(request)
    }

    private func handshake(_ request: HTTPRequest) async -> HTTPResponse {
        let previous = lastHandshake
        let task = Task { () -> HTTPResponse in
            _ = await previous?.value
            guard !stopped else { return Self.unavailable }
            let fresh = StatelessHTTPServerTransport()
            do {
                try await host.attach(transport: fresh)
            } catch {
                return Self.unavailable
            }
            // Stopped while attaching: don't leave the new server running.
            guard !stopped else {
                await host.stop()
                return Self.unavailable
            }
            transport = fresh
            return await fresh.handleRequest(request)
        }
        lastHandshake = task
        return await task.value
    }

    private static let unavailable = HTTPResponse.error(
        statusCode: 503, .internalError("TuneNook's MCP server isn't available."))

    private static func isInitialize(_ body: Data?) -> Bool {
        guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return json["method"] as? String == "initialize" && json["id"] != nil
    }
}
