import Foundation

/// Every read and write of tracked data. Views and view models never see SQL.
final class KeywordStore {
    let db: DB

    init(db: DB) { self.db = db }

    // MARK: - Apps

    func apps() throws -> [AppRow] {
        var rows: [AppRow] = []
        try db.query("""
            SELECT a.id, a.name, count(k.id), sum(k.rank <= 10), a.icon
            FROM apps a LEFT JOIN keywords k ON k.app_id = a.id GROUP BY a.id ORDER BY a.name
            """) {
            rows.append(AppRow(id: $0.text(0)!, name: $0.text(1)!, keywordCount: $0.int(2) ?? 0, top10: $0.int(3) ?? 0, icon: $0.text(4)))
        }
        return rows
    }

    func addApp(_ app: FoundApp) throws {
        try db.run("INSERT OR IGNORE INTO apps(id, name, developer, platform, icon) VALUES (?, ?, ?, 'iphone', ?)",
                   [app.id, app.name, app.developer, app.icon])
    }

    /// Removes an app with its keywords, ranking history (cascade) and ratings.
    func deleteApp(_ id: String) throws {
        try db.transaction {
            try db.run("DELETE FROM keywords WHERE app_id = ?", [id])
            try db.run("DELETE FROM ratings WHERE app_id = ?", [id])
            try db.run("DELETE FROM apps WHERE id = ?", [id])
        }
    }

    func appIDsMissingIcon() throws -> [String] {
        var ids: [String] = []
        try db.query("SELECT id FROM apps WHERE icon IS NULL") { ids.append($0.text(0)!) }
        return ids
    }

    func setIcons(_ icons: [String: String]) throws {
        try db.transaction {
            for (id, url) in icons { try db.run("UPDATE apps SET icon = ? WHERE id = ?", [url, id]) }
        }
    }

    // MARK: - Keywords

    /// Stores an app tracks, most keywords first.
    func stores(appID: String) throws -> [String] {
        var rows: [String] = []
        try db.query("SELECT store FROM keywords WHERE app_id = ? GROUP BY store ORDER BY count(*) DESC", [appID]) { rows.append($0.text(0)!) }
        return rows
    }

    /// Store code meaning "every store" in `keywords(appID:store:)`.
    static let allStores = "*"

    func keywords(appID: String, store: String) throws -> [KeywordRow] {
        var rows: [KeywordRow] = []
        try db.query("""
            SELECT k.id, k.text, k.rank, k.prev_rank, k.popularity, k.astro_popularity, k.difficulty, k.apps_count, k.note,
                   (SELECT group_concat(t.name, ', ') FROM keyword_tags kt JOIN tags t ON t.id = kt.tag_id WHERE kt.keyword_id = k.id),
                   k.updated, k.store, k.mark
            FROM keywords k WHERE k.app_id = ? AND (? = '*' OR k.store = ?)
            """, [appID, store, store]) { r in
            let rank = r.int(2) ?? 1000, prev = r.int(3) ?? rank
            rows.append(KeywordRow(
                id: r.int(0)!, store: r.text(11)!, text: r.text(1)!, rank: rank, prevRank: prev, change: prev - rank,
                popularity: r.int(4) ?? -1, astroPopularity: r.int(5) ?? 0, difficulty: r.int(6) ?? 0,
                appsCount: r.int(7) ?? 0, note: r.text(8) ?? "", tags: r.text(9) ?? "",
                updated: r.double(10).map(Date.init(timeIntervalSince1970:)),
                mark: r.text(12).flatMap(KeywordMark.init(rawValue:))))
        }
        let trends = try trends(appID: appID, store: store)
        for i in rows.indices {
            rows[i].rankTrend = trends.rank[rows[i].id] ?? []
            rows[i].popularityTrend = trends.popularity[rows[i].store + "\u{1}" + rows[i].text] ?? []
        }
        return rows.sorted { $0.rank < $1.rank }
    }

    /// Recent history for the table's sparklines: rank by keyword id, popularity by "store\u{1}term".
    /// ponytail: 圏外 checks are dropped, so a keyword that fell out shows its last ranked stretch.
    private func trends(appID: String, store: String, days: Double = 90) throws -> (rank: [Int: [Int]], popularity: [String: [Int]]) {
        let since = Date().timeIntervalSince1970 - days * 86400
        var rank: [Int: [Int]] = [:], popularity: [String: [Int]] = [:]
        try db.query("""
            SELECT r.keyword_id, r.rank FROM rankings r JOIN keywords k ON k.id = r.keyword_id
            WHERE k.app_id = ? AND (? = '*' OR k.store = ?) AND r.date >= ? AND r.rank < 1000 ORDER BY r.date
            """, [appID, store, store, since]) { rank[$0.int(0)!, default: []].append($0.int(1)!) }
        try db.query("""
            SELECT p.store, p.text, p.popularity FROM popularity_history p
            WHERE p.date >= ? AND EXISTS(SELECT 1 FROM keywords k
                WHERE k.app_id = ? AND k.store = p.store AND k.text = p.text AND (? = '*' OR k.store = ?))
            ORDER BY p.date
            """, [since, appID, store, store]) {
            popularity[$0.text(0)! + "\u{1}" + $0.text(1)!, default: []].append($0.int(2)!)
        }
        return (rank, popularity)
    }

    /// Splits user input (lines, commas, 、) into normalized, unique keywords.
    static func parseKeywords(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    /// Returns how many were new.
    func addKeywords(_ words: [String], appID: String, store: String) throws -> Int {
        var added = 0
        try db.transaction {
            for w in words {
                try db.run("INSERT OR IGNORE INTO keywords(app_id, store, text) VALUES (?, ?, ?)", [appID, store, w])
                added += db.changes
            }
        }
        return added
    }

    /// Removes keywords with their ranking history and tags (cascade).
    func deleteKeywords(_ ids: Set<Int>) throws {
        try db.transaction {
            for id in ids { try db.run("DELETE FROM keywords WHERE id = ?", [id]) }
        }
    }

    func setMark(_ mark: KeywordMark?, keywordIDs: Set<Int>) throws {
        try db.transaction {
            for id in keywordIDs { try db.run("UPDATE keywords SET mark = ? WHERE id = ?", [mark?.rawValue, id]) }
        }
    }

    func setNote(_ note: String, keywordID: Int) throws {
        try db.run("UPDATE keywords SET note = ? WHERE id = ?", [note.isEmpty ? nil : note, keywordID])
    }

    func term(keywordID: Int) throws -> (text: String, store: String)? {
        var found: (String, String)?
        try db.query("SELECT text, store FROM keywords WHERE id = ?", [keywordID]) { found = ($0.text(0)!, $0.text(1)!) }
        return found
    }

    func topApps(keywordID: Int) throws -> [TopApp] {
        var json: String?
        try db.query("SELECT top_apps FROM keywords WHERE id = ?", [keywordID]) { json = $0.text(0) }
        return TopApp.decode(json)
    }

    func setTopApps(_ apps: [TopApp], store: String, text: String) throws {
        try db.run("UPDATE keywords SET top_apps = ? WHERE store = ? AND text = ?", [TopApp.encode(apps), store, text])
    }

    func history(keywordID: Int, since: Double) throws -> [RankPoint] {
        var points: [RankPoint] = []
        try db.query("SELECT date, rank FROM rankings WHERE keyword_id = ? AND date >= ? ORDER BY date", [keywordID, since]) {
            points.append(RankPoint(date: Date(timeIntervalSince1970: $0.double(0)!), rank: $0.int(1)!))
        }
        return points
    }

    /// Latest recorded rating for an app in one store.
    func latestRating(appID: String, store: String) throws -> Rating? {
        var found: Rating?
        try db.query("SELECT rating, count, reviews FROM ratings WHERE app_id = ? AND store = ? ORDER BY date DESC LIMIT 1", [appID, store]) {
            found = Rating(value: $0.double(0), count: $0.int(1), reviews: $0.int(2))
        }
        return found
    }

    // MARK: - Update bookkeeping

    /// App ids per store whose rating was last recorded before `cutoff` (or never).
    func dueRatings(cutoff: Double) throws -> [String: [String]] {
        var byStore: [String: [String]] = [:]
        try db.query("""
            SELECT DISTINCT k.store, k.app_id FROM keywords k
            WHERE NOT EXISTS(SELECT 1 FROM ratings r WHERE r.app_id = k.app_id AND r.store = k.store AND r.date >= ?)
            """, [cutoff]) { byStore[$0.text(0)!, default: []].append($0.text(1)!) }
        return byStore
    }

    /// Records a row for every id, empty when the store didn't return the app, so it isn't due again until tomorrow.
    func recordRatings(_ ratings: [String: Rating], for ids: [String], store: String, at now: Double) throws {
        try db.transaction {
            for id in ids {
                let r = ratings[id]
                try db.run("INSERT INTO ratings(app_id, store, date, rating, count, reviews) VALUES (?, ?, ?, ?, ?, ?)",
                           [id, store, now, r?.value, r?.count, r?.reviews])
            }
        }
    }

    struct Member: Equatable { let id: Int; let appID: String }
    struct Group: Equatable { let store: String; let text: String; var members: [Member] }

    /// Due keywords grouped by (store, text): one search request serves every app tracking that term.
    /// With `appID`, every term that app tracks is due regardless of schedule.
    func dueRankGroups(now: Double, appID: String? = nil) throws -> [Group] {
        var groups: [String: Group] = [:]
        var dueKeys = Set<String>()
        try db.query("""
            SELECT k.id, k.app_id, k.store, k.text, k.rank, k.updated,
                   k.mark IS NOT NULL OR EXISTS(SELECT 1 FROM keyword_tags t WHERE t.keyword_id = k.id)
            FROM keywords k ORDER BY k.rank
            """) { r in
            let store = r.text(2)!, text = r.text(3)!
            let key = store + "\u{1}" + text
            groups[key, default: Group(store: store, text: text, members: [])].members.append(Member(id: r.int(0)!, appID: r.text(1)!))
            let due = appID.map { $0 == r.text(1) } ?? Schedule.isRankDue(rank: r.int(4), tagged: r.int(6) == 1, updated: r.double(5), now: now)
            if due { dueKeys.insert(key) }
        }
        return dueKeys.compactMap { groups[$0] }
    }

    /// Saves one search result for every app in the group.
    func recordSearch(_ result: AppStoreSearch.SearchResult, for group: Group, at now: Double) throws {
        let top = TopApp.encode(result.top)
        try db.transaction {
            for m in group.members {
                let rank = AppStoreSearch.rank(of: m.appID, in: result.ids)
                try db.run("UPDATE keywords SET prev_rank = rank, rank = ?, apps_count = ?, updated = ?, top_apps = ? WHERE id = ?",
                           [rank, result.ids.count, now, top, m.id])
                try db.run("INSERT INTO rankings(keyword_id, date, rank) VALUES (?, ?, ?)", [m.id, now, rank])
            }
        }
    }

    /// Terms whose popularity is older than `cutoff`, per store, with an owned app id to query under.
    func duePopularity(cutoff: Double) throws -> [String: (adamID: String, terms: [String])] {
        var byStore: [String: (adamID: String, terms: [String])] = [:]
        try db.query("""
            SELECT store, text, min(app_id) FROM keywords
            WHERE pop_updated IS NULL OR pop_updated < ? GROUP BY store, text
            """, [cutoff]) { r in
            byStore[r.text(0)!, default: (r.text(2)!, [])].terms.append(r.text(1)!)
        }
        return byStore
    }

    func setPopularity(_ values: [(term: String, popularity: Int)], store: String, at now: Double) throws {
        try db.transaction {
            for v in values {
                try db.run("UPDATE keywords SET popularity = ?, pop_updated = ? WHERE store = ? AND text = ?", [v.popularity, now, store, v.term])
                try db.run("INSERT INTO popularity_history(store, text, date, popularity) VALUES (?, ?, ?, ?)", [store, v.term, now, v.popularity])
            }
        }
    }
}
