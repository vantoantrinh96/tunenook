import Foundation
import MCP
import Testing
@testable import TuneNook

struct HTTPMessageTests {
    private func raw(_ s: String) -> Data { Data(s.utf8) }

    private func request(_ parsed: HTTPMessage.Parsed) -> HTTPRequest? {
        if case .request(let r) = parsed { return r }
        return nil
    }

    private func failure(_ parsed: HTTPMessage.Parsed) -> Int? {
        if case .failure(let status) = parsed { return status }
        return nil
    }

    private let post = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 5\r\n\r\nhello"

    @Test func parsesPostWithBody() {
        let r = request(HTTPMessage.parse(raw(post)))
        #expect(r?.method == "POST")
        #expect(r?.path == "/mcp")
        #expect(r?.body == Data("hello".utf8))
        #expect(r?.header("Host") == "127.0.0.1:1")
    }

    @Test func incompleteUntilBodyArrives() {
        let full = raw(post)
        let half = full.prefix(full.count - 3)
        guard case .incomplete = HTTPMessage.parse(Data(half)) else {
            Issue.record("expected incomplete")
            return
        }
        #expect(request(HTTPMessage.parse(full)) != nil)
        guard case .incomplete = HTTPMessage.parse(raw("POST /mcp HTTP/1.1\r\nHost: x")) else {
            Issue.record("expected incomplete for partial headers")
            return
        }
    }

    @Test func headerLookupIsCaseInsensitive() {
        let r = request(HTTPMessage.parse(raw("GET /mcp HTTP/1.1\r\nAUTHORIZATION: Bearer x\r\n\r\n")))
        #expect(r?.header("authorization") == "Bearer x")
    }

    @Test func duplicateHeadersLastWins() {
        let r = request(HTTPMessage.parse(raw("GET /mcp HTTP/1.1\r\nX-A: 1\r\nx-a: 2\r\n\r\n")))
        #expect(r?.header("X-A") == "2")
    }

    @Test func pathDropsQuery() {
        let r = request(HTTPMessage.parse(raw("GET /mcp?a=b HTTP/1.1\r\n\r\n")))
        #expect(r?.path == "/mcp")
    }

    @Test func rejectsGarbage() {
        #expect(failure(HTTPMessage.parse(raw("hello\r\n\r\n"))) == 400)
        #expect(failure(HTTPMessage.parse(raw("GET /mcp HTTP/1.0\r\n\r\n"))) == 400)
    }

    @Test func missingContentLength() {
        #expect(failure(HTTPMessage.parse(raw("POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n"))) == 411)
    }

    @Test func chunked() {
        let s = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(failure(HTTPMessage.parse(raw(s))) == 411)
    }

    @Test func hugeDeclaredBody() {
        // Rejected from the headers alone, before any body is buffered.
        let s = "POST /mcp HTTP/1.1\r\nContent-Length: 52428800\r\n\r\n"
        #expect(failure(HTTPMessage.parse(raw(s))) == 413)
    }

    @Test func oversizedHeaders() {
        let big = String(repeating: "a", count: HTTPMessage.maxHeaderBytes + 1)
        #expect(failure(HTTPMessage.parse(raw("GET /mcp HTTP/1.1\r\nX-Big: \(big)\r\n\r\n"))) == 431)
        // Even without a terminator yet.
        #expect(failure(HTTPMessage.parse(raw("GET /mcp HTTP/1.1\r\nX-Big: \(big)"))) == 431)
    }

    @Test func serializeSetsContentLengthAndClose() {
        let data = HTTPMessage.serialize(.data(Data("{}".utf8), headers: ["Content-Type": "application/json"]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
        let err = String(decoding: HTTPMessage.serialize(status: 404), as: UTF8.self)
        #expect(err.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(err.contains("Content-Length: 0\r\n"))
    }

    @Test func streamSerializesAsEmpty500() {
        let stream = AsyncThrowingStream<Data, Swift.Error> { $0.finish() }
        let text = String(decoding: HTTPMessage.serialize(.stream(stream)), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 500 "))
        #expect(text.contains("Content-Length: 0\r\n"))
    }

    @Test func tooManyHeaders() {
        func make(_ n: Int) -> Data {
            let h = (0..<n).map { "X-H\($0): v\r\n" }.joined()
            return raw("GET /mcp HTTP/1.1\r\n\(h)\r\n")
        }
        #expect(request(HTTPMessage.parse(make(HTTPMessage.maxHeaderCount))) != nil)
        #expect(failure(HTTPMessage.parse(make(HTTPMessage.maxHeaderCount + 1))) == 431)
        #expect(HTTPMessage.maxHeaderCount == 100)
    }

    @Test func bodyInManySmallChunksParsesOnce() {
        let head = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 300\r\n\r\n"
        let body = String(repeating: "b", count: 300)
        var buffer = Data()
        var parsedHead: HTTPMessage.Head?
        var result: HTTPRequest?
        for byte in Data((head + body).utf8) {
            buffer.append(byte)
            if parsedHead == nil {
                switch HTTPMessage.parseHead(buffer) {
                case .head(let h): parsedHead = h
                case .incomplete: continue
                case .failure(let status): Issue.record("failed \(status)"); return
                }
            }
            if let h = parsedHead, let r = h.request(from: buffer) { result = r }
        }
        #expect(result?.body == Data(body.utf8))
        #expect(result?.header("Host") == "x")
    }
}
