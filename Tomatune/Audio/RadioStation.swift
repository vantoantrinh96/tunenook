import Foundation

struct RadioStation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let url: URL
    let source: String

    /// Stations bundled with the app. A remote list can replace this later without an app update.
    static func bundled(in bundle: Bundle = .main) -> [RadioStation] {
        guard let url = bundle.url(forResource: "stations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stations = try? JSONDecoder().decode([RadioStation].self, from: data)
        else { return [] }
        return stations
    }
}
