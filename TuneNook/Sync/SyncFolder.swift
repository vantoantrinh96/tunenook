import Foundation

struct RemoteDevice: Equatable, Sendable {
    var deviceID: String
    var deviceName: String
    var exportedAt: Date
    var isStale: Bool
}

struct FolderRead: Sendable {
    /// Active (not stale) snapshots from other devices.
    var snapshots: [DeviceSnapshot]
    /// Every other device seen, stale included.
    var devices: [RemoteDevice]
    /// User-facing notes about files that could not be used.
    var notes: [String]
    /// Another device's file is still downloading or could not be read yet, so
    /// `snapshots` may be missing a Mac.
    var isIncomplete = false
}

enum SyncFolderError: Error, Equatable { case needsFolder }

/// The user-chosen folder holding one `devices/<deviceID>.json` per Mac.
struct SyncFolder: Sendable {
    let url: URL
    var startDownload: @Sendable (URL) -> Void = { try? FileManager.default.startDownloadingUbiquitousItem(at: $0) }

    static let staleWindow: TimeInterval = 90 * 86_400

    private var devicesURL: URL { url.appendingPathComponent("devices", isDirectory: true) }

    /// Just enough of a file to decide whether we can read the rest.
    private struct Header: Decodable {
        var formatVersion: Int
        var deviceName: String?
    }

    func read(excluding deviceID: String, now: Date) throws -> FolderRead {
        var result = FolderRead(snapshots: [], devices: [], notes: [])

        let fm = FileManager.default
        guard fm.fileExists(atPath: devicesURL.path) else { return result }
        let names = try fm.contentsOfDirectory(atPath: devicesURL.path).sorted()

        for name in names {
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                // Placeholder: ask iCloud for the real file and pick it up next time.
                let real = String(name.dropFirst().dropLast(".icloud".count))
                startDownload(devicesURL.appendingPathComponent(real))
                if real != "\(deviceID).json" { result.isIncomplete = true }
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".json".count))
            if stem == deviceID { continue }

            let file = devicesURL.appendingPathComponent(name)
            guard let data = coordinatedRead(file), let header = try? Self.plainDecoder.decode(Header.self, from: data) else {
                result.notes.append("Couldn't read \(name). It will be tried again.")
                result.isIncomplete = true
                continue
            }
            if header.formatVersion > DeviceSnapshot.currentFormat {
                result.notes.append("\(header.deviceName ?? name) uses a newer TuneNook. Update TuneNook on this Mac to sync with it.")
                continue
            }
            guard let snapshot = try? DeviceSnapshot.decode(data) else {
                result.notes.append("Couldn't read \(name). It will be tried again.")
                result.isIncomplete = true
                continue
            }
            if snapshot.deviceID == deviceID { continue }
            let stale = now.timeIntervalSince(snapshot.exportedAt) > Self.staleWindow
            result.devices.append(RemoteDevice(deviceID: snapshot.deviceID, deviceName: snapshot.deviceName,
                                               exportedAt: snapshot.exportedAt, isStale: stale))
            if !stale { result.snapshots.append(snapshot) }
        }
        return result
    }

    func write(_ snapshot: DeviceSnapshot) throws {
        try write(snapshot.encoded(), deviceID: snapshot.deviceID)
    }

    /// Writes bytes already encoded from this device's snapshot.
    func write(_ data: Data, deviceID: String) throws {
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)
        let file = devicesURL.appendingPathComponent("\(deviceID).json")
        try coordinatedWrite(file) { target in
            // `.atomic` writes a temp file beside the target, then renames it into place.
            try data.write(to: target, options: .atomic)
        }
    }

    func remove(deviceID: String) throws {
        let file = devicesURL.appendingPathComponent("\(deviceID).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try coordinatedWrite(file, options: .forDeleting) { target in
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: Coordination

    private static let plainDecoder = JSONDecoder()

    private func coordinatedRead(_ file: URL) -> Data? {
        var coordError: NSError?
        var data: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &coordError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return coordError == nil ? data : nil
    }

    private func coordinatedWrite(_ file: URL, options: NSFileCoordinator.WritingOptions = [],
                                  _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: options, error: &coordError) { target in
            do { try body(target) } catch { bodyError = error }
        }
        if let coordError { throw coordError }
        if let bodyError { throw bodyError }
    }
}

/// Persists the chosen folder as an app-scoped security-scoped bookmark.
enum SyncBookmark {
    static let key = "sync.folderBookmark"

    static func save(_ url: URL, in defaults: UserDefaults) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }

    /// Resolves the bookmark and starts security-scoped access (kept open for the app's lifetime).
    static func resolve(from defaults: UserDefaults) throws -> URL {
        guard let data = defaults.data(forKey: key) else { throw SyncFolderError.needsFolder }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw SyncFolderError.needsFolder
        }
        guard url.startAccessingSecurityScopedResource() else { throw SyncFolderError.needsFolder }
        if stale {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: key)
            }
        }
        return url
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
}
