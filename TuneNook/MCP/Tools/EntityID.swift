import Foundation
import SwiftData

/// Opaque string ids for SwiftData rows: the base64url of the row's `PersistentIdentifier` JSON.
/// They stay valid across launches for a saved row, so save before encoding.
enum EntityID {
    static func encode(_ id: PersistentIdentifier) -> String {
        // Sorted keys keep the string stable: the same row always encodes to the same id.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(id) else { return "" }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> PersistentIdentifier? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(PersistentIdentifier.self, from: data)
    }
}
