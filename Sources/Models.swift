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
    var mark: KeywordMark?
    var rankTrend: [Int] = []        // oldest first, ranked checks only
    var popularityTrend: [Int] = []  // oldest first

    /// Search Ads value when fetched, else the frozen Astro value.
    var displayPopularity: Int { popularity >= 0 ? popularity : astroPopularity }
}

struct Rating: Equatable {
    let value: Double?
    let count: Int?
    var reviews: Int? = nil  // written reviews; own apps via App Store Connect only
    var countChange: Int? = nil    // vs. previous record; read side only
    var reviewsChange: Int? = nil
}

/// Finder-style color label on a keyword.
enum KeywordMark: String, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    var label: String {
        switch self {
        case .red: "赤"
        case .orange: "オレンジ"
        case .yellow: "黄"
        case .green: "緑"
        case .blue: "青"
        case .purple: "紫"
        case .gray: "グレイ"
        }
    }
}

/// One day's value in a count chart; `tone` splits review counts by stars.
struct CountPoint: Identifiable, Equatable {
    let date: Date
    let count: Int
    var tone: ReviewTone? = nil
    var id: String { "\(date.timeIntervalSince1970)-\(tone?.rawValue ?? "")" }
}

/// Good / middling / bad review by stars.
enum ReviewTone: String, CaseIterable {
    case good, neutral, bad

    init(rating: Int) { self = rating >= 4 ? .good : rating == 3 ? .neutral : .bad }

    var label: String {
        switch self {
        case .good: "★4–5"
        case .neutral: "★3"
        case .bad: "★1–2"
        }
    }

    /// Running totals per calendar day and tone (every tone at every day, for stacking), carried to `now`.
    static func cumulative(_ reviews: [(date: Date, rating: Int)], now: Date = Date()) -> [CountPoint] {
        var totals = Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        var points: [CountPoint] = [], day: Date?
        func emit(_ d: Date) { points += allCases.map { CountPoint(date: d, count: totals[$0]!, tone: $0) } }
        for r in reviews.sorted(by: { $0.date < $1.date }) {
            let d = Calendar.current.startOfDay(for: r.date)
            if let day, d != day { emit(day) }
            day = d
            totals[ReviewTone(rating: r.rating)]! += 1
        }
        if let day {
            emit(day)
            let today = Calendar.current.startOfDay(for: now)
            if today > day { emit(today) }
        }
        return points
    }
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
