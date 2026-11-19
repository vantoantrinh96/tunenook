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
}
