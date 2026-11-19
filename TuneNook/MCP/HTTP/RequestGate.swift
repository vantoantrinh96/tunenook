import Foundation
import MCP

/// Decides whether a request may reach the MCP handler. Keeps other processes and web pages out:
/// DNS-rebinding defence (Host/Origin) first, then the bearer token.
struct RequestGate: Sendable {
    let token: String
    let port: Int

    /// nil means let it through.
    func rejection(for request: HTTPRequest) -> HTTPResponse? {
        guard request.path == "/mcp" else { return reject(404, "Not found") }

        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.header("Host"), hosts.contains(host) else {
            return reject(403, "Forbidden host")
        }
        if let origin = request.header("Origin") {
            let origins: Set<String> = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
            guard origins.contains(origin) else { return reject(403, "Forbidden origin") }
        }
        guard let auth = request.header("Authorization"),
            Self.constantTimeEqual(Array(auth.utf8), Array("Bearer \(token)".utf8))
        else {
            return reject(401, "Unauthorized", headers: ["WWW-Authenticate": "Bearer"])
        }
        return nil
    }

    private func reject(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        .error(statusCode: status, .invalidRequest(message), extraHeaders: headers)
    }

    /// Compares every byte of the expected value; length mismatch is folded into the result.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt(bitPattern: a.count ^ b.count)
        for i in 0..<b.count {
            diff |= UInt((i < a.count ? a[i] : 0) ^ b[i])
        }
        return diff == 0
    }
}
