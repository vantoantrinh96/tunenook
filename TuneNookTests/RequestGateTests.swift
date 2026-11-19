import Foundation
import MCP
import Testing
@testable import TuneNook

struct RequestGateTests {
    private let gate = RequestGate(token: "test-token", port: 47821)

    private func req(
        path: String = "/mcp",
        host: String? = "127.0.0.1:47821",
        origin: String? = nil,
        auth: String? = "Bearer test-token"
    ) -> HTTPRequest {
        var h: [String: String] = [:]
        if let host { h["Host"] = host }
        if let origin { h["Origin"] = origin }
        if let auth { h["Authorization"] = auth }
        return HTTPRequest(method: "POST", headers: h, body: nil, path: path)
    }

    @Test func acceptsGoodRequest() { #expect(gate.rejection(for: req()) == nil) }
    @Test func localhostHostAccepted() { #expect(gate.rejection(for: req(host: "localhost:47821")) == nil) }
    @Test func wrongPath() { #expect(gate.rejection(for: req(path: "/other"))?.statusCode == 404) }
    @Test func missingHost() { #expect(gate.rejection(for: req(host: nil))?.statusCode == 403) }
    @Test func foreignHost() { #expect(gate.rejection(for: req(host: "evil.example:47821"))?.statusCode == 403) }
    @Test func wrongPortHost() { #expect(gate.rejection(for: req(host: "127.0.0.1:1234"))?.statusCode == 403) }
    @Test func foreignOrigin() { #expect(gate.rejection(for: req(origin: "https://evil.example"))?.statusCode == 403) }
    @Test func loopbackOriginAllowed() {
        #expect(gate.rejection(for: req(origin: "http://127.0.0.1:47821")) == nil)
        #expect(gate.rejection(for: req(origin: "http://localhost:47821")) == nil)
    }

    @Test func missingToken() {
        let r = gate.rejection(for: req(auth: nil))
        #expect(r?.statusCode == 401)
        #expect(r?.headers["WWW-Authenticate"] == "Bearer")
    }

    @Test func wrongToken() { #expect(gate.rejection(for: req(auth: "Bearer nope-token"))?.statusCode == 401) }
    @Test func tokenPrefixIsNotEnough() { #expect(gate.rejection(for: req(auth: "Bearer test-toke"))?.statusCode == 401) }
    @Test func tokenWithExtraIsRejected() { #expect(gate.rejection(for: req(auth: "Bearer test-token!"))?.statusCode == 401) }
    @Test func basicSchemeRejected() { #expect(gate.rejection(for: req(auth: "Basic test-token"))?.statusCode == 401) }
    @Test func orderPathBeforeHostBeforeAuth() {
        #expect(gate.rejection(for: req(path: "/x", host: nil, auth: nil))?.statusCode == 404)
        #expect(gate.rejection(for: req(host: nil, auth: nil))?.statusCode == 403)
    }

    @Test func constantTimeEqualRejectsLengthsDifferingBy65536() {
        let expected = Array("Bearer test-token".utf8)
        let longer = expected + [UInt8](repeating: 0, count: 65536)
        #expect(!RequestGate.constantTimeEqual(longer, expected))
        #expect(!RequestGate.constantTimeEqual(expected, longer))
        #expect(RequestGate.constantTimeEqual(expected, expected))
    }
}
