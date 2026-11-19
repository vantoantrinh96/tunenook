import Foundation
import MCP

/// Minimal HTTP/1.1 request parser and response serializer. One request per connection.
enum HTTPMessage {
    enum Parsed {
        case incomplete
        case request(HTTPRequest)
        case failure(status: Int)
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    private static let terminator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> Parsed {
        let bytes = Data(buffer)  // normalise indices to zero
        guard let end = bytes.range(of: terminator) else {
            return bytes.count > maxHeaderBytes ? .failure(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .failure(status: 431) }

        guard let head = String(data: bytes[..<end.lowerBound], encoding: .utf8) else {
            return .failure(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" else {
            return .failure(status: 400)
        }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .failure(status: 400)
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers.removeValue(forKey: existing)
            }
            headers[name] = value
        }
        let lookup = HTTPRequest(method: method, headers: headers)

        if let encoding = lookup.header("Transfer-Encoding"), encoding.lowercased().contains("chunked") {
            return .failure(status: 411)
        }
        var length: Int?
        if let raw = lookup.header("Content-Length") {
            guard let n = Int(raw), n >= 0 else { return .failure(status: 400) }
            guard n <= maxBodyBytes else { return .failure(status: 413) }
            length = n
        } else if method == "POST" {
            return .failure(status: 411)
        }

        var body: Data?
        if let length {
            let rest = bytes[end.upperBound...]
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        return .request(HTTPRequest(method: method, headers: headers, body: body, path: path))
    }

    static func serialize(_ response: HTTPResponse) -> Data {
        switch response {
        case .stream:
            return serialize(status: 500)  // never produced by the stateless transport
        default:
            return serialize(status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
        }
    }

    static func serialize(status: Int) -> Data {
        serialize(status: status, headers: [:], body: Data())
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    private static func serialize(status: Int, headers: [String: String], body: Data) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "content-length" || lower == "connection" { continue }
            // Header injection guard.
            guard !name.contains(where: \.isNewline), !value.contains(where: \.isNewline) else { continue }
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(text.utf8) + body
    }
}
