import Foundation

struct AppRow: Identifiable, Hashable {
    let id: String
    let name: String
    let keywordCount: Int
    let top10: Int
    let icon: String?
}

struct KeywordRow: Identifiable, Hashable {
    let id: Int
    let store: String
    let text: String
    let rank: Int          // 1000 = not ranked
    let prevRank: Int
    let change: Int        // positive = moved up
    let popularity: Int    // -1 = not fetched yet
    let astroPopularity: Int
    let difficulty: Int
    let appsCount: Int
    var note: String
    let tags: String
    let updated: Date?
    var rankTrend: [Int] = []        // oldest first, ranked checks only
    var popularityTrend: [Int] = []  // oldest first

    /// Search Ads value when fetched, else the frozen Astro value.
    var displayPopularity: Int { popularity >= 0 ? popularity : astroPopularity }
}

struct Rating: Equatable {
    let value: Double?
    let count: Int?
}

struct RankPoint: Identifiable {
    let date: Date
    let rank: Int
    var id: Date { date }
}

/// An App Store search/lookup hit, used when adding an app.
struct FoundApp: Identifiable, Hashable {
    let id: String
    let name: String
    let developer: String
    let icon: String?
}

struct TopApp: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let subtitle: String?
    let icon: String?
    let rating: Double?
    let ratingCount: Int?

    static func encode(_ apps: [TopApp]) -> String? {
        apps.isEmpty ? nil : (try? JSONEncoder().encode(apps)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode(_ json: String?) -> [TopApp] {
        json.flatMap { try? JSONDecoder().decode([TopApp].self, from: Data($0.utf8)) } ?? []
    }
}
