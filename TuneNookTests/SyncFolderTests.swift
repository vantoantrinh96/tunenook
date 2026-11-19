import Testing
import Foundation
@testable import TuneNook

@Suite struct SyncFolderTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        func add(_ u: URL) { lock.lock(); _urls.append(u); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func snap(_ id: String, name: String? = nil, exportedAt: Date = Date()) -> DeviceSnapshot {
        var s = DeviceSnapshot.empty(deviceID: id, deviceName: name ?? "Mac \(id)")
        s.exportedAt = exportedAt
        return s
    }

    private func devicesDir(_ root: URL) -> URL { root.appendingPathComponent("devices") }

    @Test func writesAndReadsBack() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = SyncFolder(url: dir)
        try folder.write(snap("A")); try folder.write(snap("B"))
        let result = try folder.read(excluding: "A", now: Date())
        #expect(result.snapshots.map(\.deviceID) == ["B"])
        #expect(result.devices.map(\.deviceID) == ["B"])
        #expect(result.notes.isEmpty)
    }

    @Test func staleDeviceIsListedButNotMerged() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let folder = SyncFolder(url: dir)
        try folder.write(snap("B", exportedAt: now.addingTimeInterval(-91 * 86_400)))
        let result = try folder.read(excluding: "A", now: now)
        #expect(result.snapshots.isEmpty)
        #expect(result.devices.count == 1)
        #expect(result.devices.first?.isStale == true)
    }

    @Test func truncatedFileIsSkipped() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = SyncFolder(url: dir)
        try folder.write(snap("B"))
        let file = devicesDir(dir).appendingPathComponent("B.json")
        let data = try Data(contentsOf: file)
        try data.prefix(data.count / 2).write(to: file)
        let result = try folder.read(excluding: "A", now: Date())
        #expect(result.snapshots.isEmpty)
        #expect(result.notes == ["Couldn't read B.json. It will be tried again."])
    }

    @Test func newerFormatIsSkippedWithNote() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = SyncFolder(url: dir)
        var s = snap("B", name: "Studio Mac"); s.formatVersion = 2
        try folder.write(s)
        let result = try folder.read(excluding: "A", now: Date())
        #expect(result.snapshots.isEmpty)
        #expect(result.notes == ["Studio Mac uses a newer TuneNook. Update TuneNook on this Mac to sync with it."])
    }

    @Test func placeholderRequestsDownload() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: devicesDir(dir), withIntermediateDirectories: true)
        try Data().write(to: devicesDir(dir).appendingPathComponent(".B.json.icloud"))
        let calls = Calls()
        var folder = SyncFolder(url: dir)
        folder.startDownload = { calls.add($0) }
        let result = try folder.read(excluding: "A", now: Date())
        #expect(result.snapshots.isEmpty)
        #expect(result.notes.isEmpty)
        #expect(calls.urls.map(\.lastPathComponent) == ["B.json"])
    }

    @Test func removeDeletesOnlyThatFile() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = SyncFolder(url: dir)
        try folder.write(snap("A")); try folder.write(snap("B"))
        try folder.remove(deviceID: "A")
        let names = try FileManager.default.contentsOfDirectory(atPath: devicesDir(dir).path)
        #expect(names == ["B.json"])
    }

    @Test func missingDevicesFolderReadsEmpty() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try SyncFolder(url: dir).read(excluding: "A", now: Date())
        #expect(result.snapshots.isEmpty)
        #expect(result.devices.isEmpty)
        #expect(result.notes.isEmpty)
    }

    @Test func writeIsAtomic() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = SyncFolder(url: dir)
        try folder.write(snap("A")); try folder.write(snap("A"))
        let names = try FileManager.default.contentsOfDirectory(atPath: devicesDir(dir).path)
        #expect(names == ["A.json"])
    }

    @Test func bookmarkRoundTripsAndClears() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "SyncFolderTests-\(UUID().uuidString)")!
        #expect(throws: SyncFolderError.needsFolder) { try SyncBookmark.resolve(from: defaults) }
        try SyncBookmark.save(dir, in: defaults)
        let url = try SyncBookmark.resolve(from: defaults)
        #expect(url.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
        SyncBookmark.clear(in: defaults)
        #expect(throws: SyncFolderError.needsFolder) { try SyncBookmark.resolve(from: defaults) }
    }
}
