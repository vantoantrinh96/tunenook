import Foundation

/// A throwaway defaults suite.
///
/// Tests run inside the app, so each suite is a plist in the installed app's
/// sandbox container. cfprefsd writes those files after the test process ends,
/// so they can't be removed during the run: the next run deletes them instead,
/// which leaves at most one run's worth, all named with `prefix`.
enum TestDefaults {
    static let prefix = "tunenook-tests-"

    private static let removeLeftovers: Void = {
        let folder = URL.libraryDirectory.appendingPathComponent("Preferences", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }()

    static func make() -> UserDefaults {
        _ = removeLeftovers
        return UserDefaults(suiteName: prefix + UUID().uuidString)!
    }
}
