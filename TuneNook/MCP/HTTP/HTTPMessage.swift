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

    static let maxHeaderCount = 100

    /// A parsed request line and header block, kept so the head is parsed once per connection.
    struct Head: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let contentLength: Int?
        /// Offset of the first body byte in the buffer the head was parsed from.
        let bodyStart: Int

        /// The request once the whole body is buffered; nil while it is still arriving.
        func request(from buffer: Data) -> HTTPRequest? {
            var body: Data?
            if let contentLength {
                guard buffer.count - bodyStart >= contentLength else { return nil }
                let start = buffer.startIndex + bodyStart
                body = Data(buffer[start..<(start + contentLength)])
            }
            return HTTPRequest(method: method, headers: headers, body: body, path: path)
        }
    }

    enum ParsedHead {
        case incomplete
        case head(Head)
        case failure(status: Int)
    }

    /// Parses the header block. `searchFrom` lets callers skip bytes already scanned for the terminator.
    static func parseHead(_ buffer: Data, searchFrom: Int = 0) -> ParsedHead {
        let base = buffer.startIndex
        let from = base + max(0, min(searchFrom, buffer.count))
        guard let end = buffer.range(of: terminator, in: from..<buffer.endIndex) else {
            return buffer.count > maxHeaderBytes ? .failure(status: 431) : .incomplete
        }
        let headEnd = end.lowerBound - base
        guard headEnd <= maxHeaderBytes else { return .failure(status: 431) }

        guard let text = String(data: buffer[base..<end.lowerBound], encoding: .utf8) else {
            return .failure(status: 400)
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" else {
            return .failure(status: 400)
        }
        guard lines.count - 1 <= maxHeaderCount else { return .failure(status: 431) }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        // Keyed by lowercased name so duplicates collapse in O(1); the last one wins.
        var byLowercased: [String: (name: String, value: String)] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .failure(status: 400)
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            byLowercased[name.lowercased()] = (name, value)
        }
        var headers: [String: String] = [:]
        for (_, entry) in byLowercased { headers[entry.name] = entry.value }

        if let encoding = byLowercased["transfer-encoding"]?.value, encoding.lowercased().contains("chunked") {
            return .failure(status: 411)
        }
        var length: Int?
        if let raw = byLowercased["content-length"]?.value {
            guard let n = Int(raw), n >= 0 else { return .failure(status: 400) }
            guard n <= maxBodyBytes else { return .failure(status: 413) }
            length = n
        } else if method == "POST" {
            return .failure(status: 411)
        }
        return .head(Head(
            method: method, path: path, headers: headers, contentLength: length,
            bodyStart: end.upperBound - base))
    }

    static func parse(_ buffer: Data) -> Parsed {
        switch parseHead(buffer) {
        case .incomplete: .incomplete
        case .failure(let status): .failure(status: status)
        case .head(let head):
            if let request = head.request(from: buffer) { .request(request) } else { .incomplete }
        }
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
