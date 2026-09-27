import Foundation
import WebKit

/// Same endpoint the iOS App Store app uses. Needs no token; one request returns the full ordered
/// result list (~250 apps). Verified identical to Astro's ranking on 2026-09-24.
enum AppStoreSearch {
    /// Storefront ids for every store we track (all verified against the endpoint's meta.storefront.cc).
    static let storefronts: [String: Int] = [
        "ae": 143481, "ar": 143505, "au": 143460, "bo": 143556, "br": 143503, "ca": 143455, "ch": 143459,
        "cl": 143483, "cn": 143465, "co": 143501, "cr": 143495, "cz": 143489, "de": 143443, "dk": 143458,
        "do": 143508, "ec": 143509, "es": 143454, "fi": 143447, "fr": 143442, "gb": 143444, "gr": 143448,
        "gt": 143504, "hk": 143463, "hn": 143510, "hr": 143494, "hu": 143482, "id": 143476, "ie": 143449,
        "il": 143491, "in": 143467, "it": 143450, "jp": 143462, "kg": 143586, "kr": 143466, "mx": 143468,
        "my": 143473, "nl": 143452, "no": 143457, "pa": 143485, "pe": 143507, "pl": 143478, "pt": 143453,
        "py": 143513, "ro": 143487, "ru": 143469, "sa": 143479, "se": 143456, "sk": 143496, "sv": 143506,
        "th": 143475, "tr": 143480, "tw": 143470, "ua": 143492, "us": 143441, "uz": 143566, "vn": 143471,
    ]

    struct Throttled: Error {}

    static func search(term: String, store: String) async throws -> SearchResult {
        guard let sf = storefronts[store] else { throw DBError(description: "unknown store \(store)") }
        var comps = URLComponents(string: "https://search.itunes.apple.com/WebObjects/MZStore.woa/wa/search")!
        comps.queryItems = [.init(name: "clientApplication", value: "Software"),
                            .init(name: "media", value: "software"),
                            .init(name: "term", value: term)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.setValue("\(sf),29", forHTTPHeaderField: "X-Apple-Store-Front")
        req.setValue("AppStore/3.0 iOS/18.0 model/iPhone16,2 hwp/t8130 build/22A3354 (6; dt:299) AMS/1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 || status == 403 { throw Throttled() }
        guard status == 200 else { throw DBError(description: "search HTTP \(status) for \(store)/\(term)") }
        return try parse(data)
    }

    struct SearchResult {
        let ids: [String]
        let top: [TopApp]   // first few results with display info
    }

    static func parse(_ data: Data, topCount: Int = 5) throws -> SearchResult {
        struct Page: Decodable {
            let pageData: PageData
            let storePlatformData: Platform?
            struct PageData: Decodable { let bubbles: [Bubble]? }
            struct Bubble: Decodable { let results: [Item] }
            struct Item: Decodable { let id: String }
            struct Platform: Decodable {
                let lockups: [String: Lockup]?
                enum CodingKeys: String, CodingKey { case lockups = "native-search-lockup" }
                init(from decoder: Decoder) throws {
                    struct Results: Decodable { let results: [String: Lockup] }
                    lockups = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Results.self, forKey: .lockups)?.results
                }
            }
            struct Lockup: Decodable {
                let name: String
                let subtitle: String?
                let artwork: Artwork?
                let userRating: Rating?
                struct Artwork: Decodable { let url: String }
                struct Rating: Decodable { let value: Double?; let ratingCount: Int? }
            }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let ids = page.pageData.bubbles?.first?.results.map(\.id) ?? []
        let lockups = page.storePlatformData?.lockups ?? [:]
        let top = ids.prefix(topCount).compactMap { id -> TopApp? in
            guard let l = lockups[id] else { return nil }
            let icon = l.artwork?.url.replacingOccurrences(of: "{w}x{h}bb.{f}", with: "128x128bb.png")
            return TopApp(id: id, name: l.name, subtitle: l.subtitle, icon: icon,
                          rating: l.userRating?.value, ratingCount: l.userRating?.ratingCount)
        }
        return SearchResult(ids: ids, top: top)
    }

    /// 1-based position of `appID`, or 1000 (Astro's "not ranked") when absent.
    static func rank(of appID: String, in ids: [String]) -> Int {
        ids.firstIndex(of: appID).map { $0 + 1 } ?? 1000
    }
}

/// iTunes Search/Lookup API: app search when adding, and icons for tracked apps.
enum AppCatalog {
    private struct Response: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let trackId: Int; let trackName: String; let artistName: String; let artworkUrl100: String?
            let averageUserRating: Double?; let userRatingCount: Int?
        }
    }

    /// Searches by name, or looks up a numeric id / apps.apple.com URL directly.
    static func find(_ query: String, country: String) async throws -> [FoundApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var comps = URLComponents(string: "https://itunes.apple.com")!
        if let id = q.firstMatch(of: /(?:id)?(\d{6,})/)?.1, q.allSatisfy(\.isNumber) || q.contains("apple.com") {
            comps.path = "/lookup"
            comps.queryItems = [.init(name: "id", value: String(id)), .init(name: "country", value: country)]
        } else {
            comps.path = "/search"
            comps.queryItems = [.init(name: "term", value: q), .init(name: "entity", value: "software"),
                                .init(name: "country", value: country), .init(name: "limit", value: "15")]
        }
        return try await fetch(comps.url!).map { FoundApp(id: String($0.trackId), name: $0.trackName, developer: $0.artistName, icon: $0.artworkUrl100) }
    }

    /// Icon URL per app id.
    static func icons(ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let items = try await fetch(URL(string: "https://itunes.apple.com/lookup?id=\(ids.joined(separator: ","))")!)
        return Dictionary(items.compactMap { i in i.artworkUrl100.map { (String(i.trackId), $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Current average rating and rating count per app id in one store.
    static func ratings(ids: [String], country: String) async throws -> [String: Rating] {
        guard !ids.isEmpty else { return [:] }
        let items = try await fetch(URL(string: "https://itunes.apple.com/lookup?id=\(ids.joined(separator: ","))&country=\(country)")!)
        return Dictionary(items.map { (String($0.trackId), Rating(value: $0.averageUserRating, count: $0.userRatingCount)) }, uniquingKeysWith: { a, _ in a })
    }

    private static func fetch(_ url: URL) async throws -> [Response.Item] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Response.self, from: data).results
    }
}

/// Tiered schedule: keywords that matter get checked daily, the long tail weekly.
enum Schedule {
    static let hot: TimeInterval = 20 * 3600         // "daily" with slack for when the app runs
    static let cold: TimeInterval = 6.5 * 24 * 3600  // "weekly"
    static let popularity: TimeInterval = 6.5 * 24 * 3600

    static func isRankDue(rank: Int?, tagged: Bool, updated: Double?, now: Double) -> Bool {
        guard let updated else { return true }
        let interval = (rank ?? 1000) <= 100 || tagged ? hot : cold
        return now - updated >= interval
    }
}

/// Keyword popularity from Apple Search Ads' web UI endpoint. Runs inside a WKWebView the user has
/// logged into, so the session cookies ride along. Max 100 terms per request.
@MainActor
enum AdsPopularity {
    static let home = URL(string: "https://app-ads.apple.com/cm/app")!

    static func isLoggedIn(_ web: WKWebView) -> Bool {
        guard !web.isLoading, let url = web.url else { return false }
        return url.host == "app-ads.apple.com" && url.path.hasPrefix("/cm")
    }

    /// Returns popularity per term, in input order. `adamID` must be an app owned by the account.
    static func fetch(_ web: WKWebView, terms: [String], store: String, adamID: String) async throws -> [Int?] {
        precondition(terms.count <= 100)
        // The JS must run in a loaded app-ads.apple.com document; mid-navigation it has no usable origin.
        for _ in 0..<30 where !isLoggedIn(web) { try await Task.sleep(for: .seconds(1)) }
        guard isLoggedIn(web) else { throw DBError(description: "Search Ads のページが読み込めていません。ログインし直してください") }
        let js = """
        const r = await fetch('https://app-ads.apple.com/cm/api/v2/keywords/popularities?adamId=' + adamId, {
          credentials: 'include',
          method: 'POST', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({storefronts: [storefront], terms})});
        return JSON.stringify({status: r.status, body: await r.text()});
        """
        let raw = try await web.callAsyncJavaScript(
            js, arguments: ["adamId": adamID, "storefront": store.uppercased(), "terms": terms],
            contentWorld: .page) as? String ?? ""
        struct Envelope: Decodable { let status: Int; let body: String }
        struct Body: Decodable { let data: [Item]; struct Item: Decodable { let id: Int; let popularity: Int } }
        let env = try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))
        guard env.status == 200 else { throw DBError(description: "Search Ads HTTP \(env.status): \(env.body.prefix(200))") }
        // `id` is the 1-based position in the request, so map by it rather than by name.
        var result = [Int?](repeating: nil, count: terms.count)
        for item in try JSONDecoder().decode(Body.self, from: Data(env.body.utf8)).data where (1...terms.count).contains(item.id) {
            result[item.id - 1] = item.popularity
        }
        return result
    }
}
