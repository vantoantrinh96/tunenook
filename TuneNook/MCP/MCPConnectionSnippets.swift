import Foundation

/// Copyable text that connects an MCP client to TuneNook's local server.
enum MCPConnectionSnippets {
    static func url(port: Int) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    static func claudeCodeCommand(port: Int, token: String) -> String {
        "claude mcp add --transport http tunenook \(url(port: port)) --header \"Authorization: Bearer \(token)\""
    }

    static func jsonConfig(port: Int, token: String) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                "tunenook": [
                    "type": "http",
                    "url": url(port: port),
                    "headers": ["Authorization": "Bearer \(token)"],
                ] as [String: Any]
            ]
        ]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
