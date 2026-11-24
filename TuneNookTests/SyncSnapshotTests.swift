import Foundation
import Testing
@testable import TuneNook

@Suite struct SyncSnapshotTests {
    private func meta(_ t: TimeInterval, by: String = "A", deleted: Bool = false) -> SyncMeta {
        SyncMeta(modifiedAt: Date(timeIntervalSince1970: t), modifiedBy: by, deleted: deleted)
    }

    private func sample() -> DeviceSnapshot {
        var s = DeviceSnapshot.empty(deviceID: "dev-1", deviceName: "Mac")
        s.exportedAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let topicID = UUID(), taskID = UUID()
        s.topics = [SyncTopic(id: topicID, meta: meta(100.5), name: "Swift", colorHex: "#FF0000",
                              createdAt: Date(timeIntervalSince1970: 50.25), mergedInto: nil)]
        s.tasks = [SyncTask(id: taskID, meta: meta(101), title: "Read", estimatedSessions: 3, isDone: false,
                            createdAt: Date(timeIntervalSince1970: 60), completedAt: nil,
                            deadline: Date(timeIntervalSince1970: 900), topicID: topicID)]
        s.sessions = [SyncSession(id: UUID(), meta: meta(102), kind: "focus", startedAt: Date(timeIntervalSince1970: 70),
                                  endedAt: Date(timeIntervalSince1970: 1570), activeSeconds: 1500, completed: true, taskID: taskID)]
        s.settings = ["timer.focusMinutes": SyncSetting(value: .int(30), meta: meta(103)),
                      "music.breakStationID": SyncSetting(value: .null, meta: meta(104))]
        s.goals = [SyncGoal(day: Date(timeIntervalSince1970: 86400), meta: meta(105), kind: "sessions", target: 4)]
        s.unlockedIcons = ["note"]
        return s
    }

    @Test func roundTripsThroughJSON() throws {
        let s = sample()
        #expect(try DeviceSnapshot.decode(s.encoded()) == s)
    }

    @Test func encodingIsDeterministic() throws {
        var a = sample()
        let extra = SyncTopic(id: UUID(), meta: meta(1), name: "B", colorHex: "#00FF00", createdAt: Date(timeIntervalSince1970: 1), mergedInto: nil)
        a.topics.append(extra)
        a.goals.append(SyncGoal(day: Date(timeIntervalSince1970: 172800), meta: meta(2), kind: "sessions", target: 2))
        var b = a
        b.topics.reverse()
        b.goals.reverse()
        #expect(try a.encoded() == b.encoded())
    }

    @Test func syncValueIsBarePrimitive() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(["a": SyncValue.int(3), "b": SyncValue.null])
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":3,"b":null}"#)
        let back = try JSONDecoder().decode([String: SyncValue].self, from: Data(#"{"x":true,"y":"s","z":7}"#.utf8))
        #expect(back == ["x": .bool(true), "y": .string("s"), "z": .int(7)])
    }

    @Test func winsUsesTimeThenDevice() {
        #expect(meta(2).wins(over: meta(1)))
        #expect(!meta(1).wins(over: meta(2)))
        #expect(meta(1, by: "B").wins(over: meta(1, by: "A")))
        #expect(!meta(1, by: "A").wins(over: meta(1, by: "B")))
        #expect(!meta(1).wins(over: meta(1)))
    }

    @Test func missingSettingReadsDefault() {
        let d = TestDefaults.make()
        let byKey = Dictionary(uniqueKeysWithValues: SyncedSetting.all.map { ($0.key, $0) })
        #expect(byKey["timer.focusMinutes"]!.read(from: d) == .int(25))
        #expect(byKey["music.breakStationID"]!.read(from: d) == .null)
        #expect(SyncedSetting.all.count == 14)
    }

    @Test func readWriteRoundTripsEachType() {
        let d = TestDefaults.make()
        let byKey = Dictionary(uniqueKeysWithValues: SyncedSetting.all.map { ($0.key, $0) })
        byKey["timer.focusMinutes"]!.write(.int(40), to: d)
        byKey["timer.autoStartFocus"]!.write(.bool(true), to: d)
        byKey["music.breakStationID"]!.write(.string("st"), to: d)
        #expect(byKey["timer.focusMinutes"]!.read(from: d) == .int(40))
        #expect(byKey["timer.autoStartFocus"]!.read(from: d) == .bool(true))
        #expect(byKey["music.breakStationID"]!.read(from: d) == .string("st"))
        byKey["music.breakStationID"]!.write(.null, to: d)
        #expect(d.object(forKey: "music.breakStationID") == nil)
    }

    @Test func sameContentIgnoresMeta() {
        let s = sample()
        var t = s.topics[0]
        t.meta = meta(999, by: "Z")
        t.mergedInto = UUID()
        #expect(t.sameContent(as: s.topics[0]))
        t.name = "other"
        #expect(!t.sameContent(as: s.topics[0]))
    }

    @Test func largeSnapshotEncodesAndDecodesQuickly() throws {
        var s = sample()
        let taskID = s.tasks[0].id
        s.sessions = (0..<5_000).map { i in
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 1_800.123).syncMillis
            return SyncSession(id: UUID(), meta: meta(1_700_000_000 + Double(i)), kind: "focus", startedAt: start,
                               endedAt: start.addingTimeInterval(1_500).syncMillis, activeSeconds: 1_500, completed: true,
                               taskID: taskID)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let clock = ContinuousClock()
        var data = Data()
        let encode = try clock.measure { data = try s.encoded() }
        var back: DeviceSnapshot?
        let decode = try clock.measure { back = try DeviceSnapshot.decode(data) }
        print("SyncSnapshot benchmark, 5,000 sessions: encode \(encode), decode \(decode)")
        #expect(back == s)
        #expect(encode < .milliseconds(500))
        #expect(decode < .milliseconds(500))
    }

    @Test func datesKeepMillisecondWireFormat() throws {
        var s = DeviceSnapshot.empty(deviceID: "d", deviceName: "Mac")
        s.exportedAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let json = String(decoding: try s.encoded(), as: UTF8.self)
        #expect(json.contains(#""exportedAt":"2023-11-14T22:13:20.123Z""#))
        #expect(try DeviceSnapshot.decode(Data(json.utf8)).exportedAt == s.exportedAt)
    }

    @Test func fastDateParseMatchesFormatter() {
        var generator = SystemRandomNumberGenerator()
        var dates: [Date] = [.distantPast, .distantFuture, Date(timeIntervalSince1970: 0),
                             Date(timeIntervalSince1970: 951_782_400.999), // 2000-02-29
                             Date(timeIntervalSince1970: -1.5)]
        for _ in 0..<20_000 {
            let ms = Int64.random(in: -5_000_000_000_000...10_000_000_000_000, using: &generator)
            dates.append(Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        for date in dates {
            let string = DeviceSnapshot.formatter.string(from: date)
            let expected = DeviceSnapshot.formatter.date(from: string)
            #expect(DeviceSnapshot.parseDate(string) == expected, "\(string)")
            if let fast = DeviceSnapshot.fastParse(string) { #expect(fast == expected, "\(string)") }
        }
        #expect(DeviceSnapshot.fastParse("2023-02-30T00:00:00.000Z") == nil)
        #expect(DeviceSnapshot.fastParse("2023-11-14T22:13:20Z") == nil)
    }
}
