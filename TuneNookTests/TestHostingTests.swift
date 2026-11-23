import Foundation
import Testing
@testable import TuneNook

struct TestHostingTests {
    @Test func detectsXcodeTestEnvironment() {
        #expect(TestHosting.isActive(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(TestHosting.isActive(environment: ["XCTestSessionIdentifier": "abc"]))
        #expect(!TestHosting.isActive(environment: ["HOME": "/Users/someone"]))
    }

    /// The host app must take the empty path, or it opens the user's real store.
    @Test func thisTestRunIsDetected() {
        #expect(TestHosting.isActive)
    }
}
