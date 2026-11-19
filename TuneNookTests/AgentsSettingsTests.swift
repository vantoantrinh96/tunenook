import AppKit
import Testing
@testable import TuneNook

@MainActor @Suite struct AgentsSettingsTests {
    @Test func acceptsPortsInRange() {
        #expect(AgentsPortInput.parse("47821") == 47821)
        #expect(AgentsPortInput.parse(" 1024 ") == 1024)
        #expect(AgentsPortInput.parse("65535") == 65535)
    }

    @Test func rejectsOtherInput() {
        for text in ["", " ", "1023", "65536", "abc", "80a", "-5000", "+5000", "4.5", "\u{0663}\u{0664}\u{0665}\u{0666}"] {
            #expect(AgentsPortInput.parse(text) == nil, "\(text)")
        }
    }

    /// The token, command and config all carry the token: clipboard managers must be told to skip them.
    @Test func copiedSecretsAreMarkedConcealed() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tunenook-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        SecretPasteboard.copy("test-token", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "test-token")
        let types = try #require(pasteboard.types)
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
    }
}
