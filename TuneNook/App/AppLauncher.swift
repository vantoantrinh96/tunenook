import Foundation
import SwiftUI

/// Starts TuneNook, or an empty app when it only hosts the unit tests.
///
/// The tests run inside the app, which shares its sandbox container with the
/// installed TuneNook. Starting the real app there would open the user's store,
/// sync with their folder and start the MCP server on every test run.
@main
enum AppLauncher {
    static func main() {
        if TestHosting.isActive {
            TestHostApp.main()
        } else {
            TuneNookApp.main()
        }
    }
}

enum TestHosting {
    /// Xcode sets these in the host app's environment when it injects a test bundle.
    static let environmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    static var isActive: Bool { isActive(environment: ProcessInfo.processInfo.environment) }

    static func isActive(environment: [String: String]) -> Bool {
        environmentKeys.contains { environment[$0] != nil }
    }
}

/// No store, no sync, no timers: the tests build what they need themselves.
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
