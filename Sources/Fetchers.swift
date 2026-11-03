import CryptoKit
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

/// App Store Connect API: written-review count per store for the key owner's apps.
/// Credentials come from Settings; the .p8 is read from wherever the user keeps it, never copied.
enum ConnectAPI {
    struct Credentials { let issuer: String; let keyID: String; let keyPath: String }

    static var credentials: Credentials? {
        let d = UserDefaults.standard
        guard let issuer = d.string(forKey: "ascIssuer"), let keyID = d.string(forKey: "ascKeyID"),
              let path = d.string(forKey: "ascKeyPath"), ![issuer, keyID, path].contains(where: \.isEmpty) else { return nil }
        return Credentials(issuer: issuer, keyID: keyID, keyPath: path)
    }

    /// ES256 JWT valid for 15 minutes (Apple allows at most 20).
    static func token(_ c: Credentials, now: Date = Date()) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: c.keyPath, encoding: .utf8))
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        func json(_ o: [String: Any]) throws -> String { b64(try JSONSerialization.data(withJSONObject: o)) }
        let iat = Int(now.timeIntervalSince1970)
        let signed = try json(["alg": "ES256", "kid": c.keyID, "typ": "JWT"]) + "."
            + json(["iss": c.issuer, "iat": iat, "exp": iat + 900, "aud": "appstoreconnect-v1"])
        return signed + "." + b64(try key.signature(for: Data(signed.utf8)).rawRepresentation)
    }

    /// Ids of the apps the key's account owns. ponytail: first page only (200 apps).
    static func ownAppIDs(token: String) async throws -> Set<String> {
        struct Page: Decodable { let data: [Item]; struct Item: Decodable { let id: String } }
        let page: Page = try await get(url("/v1/apps", ["limit": "200", "fields[apps]": "bundleId"]), token: token)
        return Set(page.data.map(\.id))
    }

    /// Written reviews of an app in one store.
    static func reviewCount(appID: String, store: String, token: String) async throws -> Int {
        guard let territory = territories[store] else { throw DBError(description: "unknown store \(store)") }
        struct Page: Decodable {
            let data: [Item]; let links: Links; let meta: Meta?
            struct Item: Decodable { let id: String }
            struct Links: Decodable { let next: String? }
            struct Meta: Decodable { let paging: Paging; struct Paging: Decodable { let total: Int? } }
        }
        var page: Page = try await get(url("/v1/apps/\(appID)/customerReviews",
                                           ["filter[territory]": territory, "limit": "200", "fields[customerReviews]": "rating"]), token: token)
        // `total` is optional in Apple's schema; count the pages when it's missing.
        if let total = page.meta?.paging.total { return total }
        var count = page.data.count
        while let next = page.links.next.flatMap(URL.init(string:)) {
            page = try await get(next, token: token)
            count += page.data.count
        }
        return count
    }

    private static func url(_ path: String, _ query: [String: String]) -> URL {
        var comps = URLComponents(string: "https://api.appstoreconnect.apple.com" + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url!
    }

    private static func get<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DBError(description: "App Store Connect HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// ISO 3166-1 alpha-3 territory per tracked store (all in the API's allowed values as of 2026-11).
    static let territories: [String: String] = [
        "ae": "ARE", "ar": "ARG", "au": "AUS", "bo": "BOL", "br": "BRA", "ca": "CAN", "ch": "CHE",
        "cl": "CHL", "cn": "CHN", "co": "COL", "cr": "CRI", "cz": "CZE", "de": "DEU", "dk": "DNK",
        "do": "DOM", "ec": "ECU", "es": "ESP", "fi": "FIN", "fr": "FRA", "gb": "GBR", "gr": "GRC",
        "gt": "GTM", "hk": "HKG", "hn": "HND", "hr": "HRV", "hu": "HUN", "id": "IDN", "ie": "IRL",
        "il": "ISR", "in": "IND", "it": "ITA", "jp": "JPN", "kg": "KGZ", "kr": "KOR", "mx": "MEX",
        "my": "MYS", "nl": "NLD", "no": "NOR", "pa": "PAN", "pe": "PER", "pl": "POL", "pt": "PRT",
        "py": "PRY", "ro": "ROU", "ru": "RUS", "sa": "SAU", "se": "SWE", "sk": "SVK", "sv": "SLV",
        "th": "THA", "tr": "TUR", "tw": "TWN", "ua": "UKR", "us": "USA", "uz": "UZB", "vn": "VNM",
    ]
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
