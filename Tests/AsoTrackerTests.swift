import CryptoKit
import XCTest
@testable import AsoTracker

final class AsoTrackerTests: XCTestCase {
    func testParseSearchAndRank() throws {
        let json = #"{"pageData":{"bubbles":[{"name":"software","results":[{"id":"111","type":"software"},{"id":"222","type":"software"}]}]},"storePlatformData":{"native-search-lockup":{"results":{"111":{"name":"First","artwork":{"url":"https://x/{w}x{h}bb.{f}"},"userRating":{"value":4.5,"ratingCount":10}}}}}}"#
        let result = try AppStoreSearch.parse(Data(json.utf8))
        let ids = result.ids
        XCTAssertEqual(result.top, [TopApp(id: "111", name: "First", subtitle: nil, icon: "https://x/128x128bb.png", rating: 4.5, ratingCount: 10)])
        XCTAssertEqual(ids, ["111", "222"])
        XCTAssertEqual(AppStoreSearch.rank(of: "222", in: ids), 2)
        XCTAssertEqual(AppStoreSearch.rank(of: "999", in: ids), 1000)
        XCTAssertEqual(try AppStoreSearch.parse(Data(#"{"pageData":{}}"#.utf8)).ids, [])
    }

    func testTieredSchedule() {
        let now = 1_000_000.0
        let day = 86_400.0
        XCTAssertTrue(Schedule.isRankDue(rank: 50, tagged: false, updated: nil, now: now))
        XCTAssertTrue(Schedule.isRankDue(rank: 50, tagged: false, updated: now - day, now: now))
        XCTAssertFalse(Schedule.isRankDue(rank: 50, tagged: false, updated: now - 3600, now: now))
        XCTAssertFalse(Schedule.isRankDue(rank: 1000, tagged: false, updated: now - day, now: now))
        XCTAssertTrue(Schedule.isRankDue(rank: 1000, tagged: true, updated: now - day, now: now))
        XCTAssertTrue(Schedule.isRankDue(rank: 1000, tagged: false, updated: now - 7 * day, now: now))
    }
}

final class KeywordStoreTests: XCTestCase {
    private func makeStore() throws -> KeywordStore {
        let store = KeywordStore(db: try DB(path: ":memory:"))
        try store.addApp(FoundApp(id: "1", name: "Mine", developer: "me", icon: nil))
        try store.addApp(FoundApp(id: "2", name: "Other", developer: "me", icon: nil))
        return store
    }

    func testParseKeywords() {
        XCTAssertEqual(KeywordStore.parseKeywords(" Photo \nphoto, 写真、\n\n写真 "), ["photo", "写真"])
    }

    func testAddKeywordsSkipsDuplicates() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.addKeywords(["a", "b"], appID: "1", store: "jp"), 2)
        XCTAssertEqual(try store.addKeywords(["b", "c"], appID: "1", store: "jp"), 1)
        XCTAssertEqual(try store.stores(appID: "1"), ["jp"])
        XCTAssertEqual(try store.keywords(appID: "1", store: "jp").map(\.text).sorted(), ["a", "b", "c"])
        _ = try store.addKeywords(["a"], appID: "1", store: "us")
        XCTAssertEqual(try store.keywords(appID: "1", store: KeywordStore.allStores).map { "\($0.store)/\($0.text)" }.sorted(),
                       ["jp/a", "jp/b", "jp/c", "us/a"])
    }

    func testSameTermAcrossAppsIsOneSearchAndRecordsEachRank() async throws {
        let store = try makeStore()
        _ = try store.addKeywords(["eraser"], appID: "1", store: "us")
        _ = try store.addKeywords(["eraser"], appID: "2", store: "us")
        var searches = 0
        let n = try await Updater.updateRanks(store: store, search: { _, _ in
            searches += 1
            return .init(ids: ["2", "x", "1"], top: [])
        }, pause: .zero)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(try store.keywords(appID: "1", store: "us").first?.rank, 3)
        XCTAssertEqual(try store.keywords(appID: "2", store: "us").first?.rank, 1)
        // Just checked, so nothing is due now.
        XCTAssertTrue(try store.dueRankGroups(now: Date().timeIntervalSince1970).isEmpty)
    }

    func testRatingsDueDailyPerStore() throws {
        let store = try makeStore()
        _ = try store.addKeywords(["a"], appID: "1", store: "jp")
        _ = try store.addKeywords(["a"], appID: "2", store: "jp")
        _ = try store.addKeywords(["a"], appID: "1", store: "us")
        XCTAssertEqual(try store.dueRatings(cutoff: 100).mapValues { $0.sorted() }, ["jp": ["1", "2"], "us": ["1"]])
        try store.recordRatings(["1": Rating(value: 4.5, count: 10, reviews: 3)], for: ["1", "2"], store: "jp", at: 200) // "2" not sold in jp
        XCTAssertEqual(try store.dueRatings(cutoff: 100), ["us": ["1"]])
        XCTAssertEqual(try store.latestRating(appID: "1", store: "jp"), Rating(value: 4.5, count: 10, reviews: 3))
        XCTAssertEqual(try store.dueRatings(cutoff: 300).count, 2)
        // All stores: each store's latest row, counts summed, average weighted by count.
        try store.recordRatings(["1": Rating(value: 4.0, count: 30, reviews: 5)], for: ["1"], store: "us", at: 200)
        XCTAssertEqual(try store.latestRating(appID: "1", store: KeywordStore.allStores), Rating(value: 4.125, count: 40, reviews: 8))
        XCTAssertNil(try store.latestRating(appID: "9", store: KeywordStore.allStores))
    }

    func testRatingChangeSincePreviousRecord() throws {
        let store = try makeStore()
        let day = 86400.0
        try store.recordRatings(["1": Rating(value: 4, count: 10, reviews: 2)], for: ["1"], store: "jp", at: 10 * day)
        try store.recordRatings(["1": Rating(value: 4, count: 12, reviews: 3)], for: ["1"], store: "jp", at: 11 * day)
        try store.recordRatings(["1": Rating(value: 5, count: 5)], for: ["1"], store: "us", at: 10 * day)
        try store.recordRatings(["1": Rating(value: 5, count: 6)], for: ["1"], store: "us", at: 11 * day)
        try store.recordRatings(["1": Rating(value: 3, count: 1)], for: ["1"], store: "dz", at: 1 * day) // stale, Astro era
        try store.recordRatings(["1": Rating(value: 3, count: 4)], for: ["1"], store: "dz", at: 2 * day)
        let jp = try store.latestRating(appID: "1", store: "jp")
        XCTAssertEqual(jp?.countChange, 2)
        XCTAssertEqual(jp?.reviewsChange, 1)
        XCTAssertNil(try store.latestRating(appID: "1", store: "dz")?.countChange)
        let all = try store.latestRating(appID: "1", store: KeywordStore.allStores)
        XCTAssertEqual(all?.count, 22)        // latest of each store, dz included
        XCTAssertEqual(all?.countChange, 3)   // jp +2, us +1; dz's old +3 left out
        XCTAssertEqual(all?.reviewsChange, 1)
    }

    func testConnectTokenIsVerifiableES256() throws {
        let key = P256.Signing.PrivateKey()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_TEST.p8").path
        try key.pemRepresentation.write(toFile: path, atomically: true, encoding: .utf8) // same PKCS#8 PEM as Apple's .p8
        defer { try? FileManager.default.removeItem(atPath: path) }
        let token = try ConnectAPI.token(.init(issuer: "iss", keyID: "KID", keyPath: path), now: Date(timeIntervalSince1970: 1000))
        let parts = token.split(separator: ".").map { s -> Data in
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b += String(repeating: "=", count: (4 - b.count % 4) % 4)
            return Data(base64Encoded: b)!
        }
        XCTAssertEqual(parts.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: parts[0]) as? [String: Any])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: parts[1]) as? [String: Any])
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KID")
        XCTAssertEqual(payload["iss"] as? String, "iss")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(payload["exp"] as? Int, 1900)
        let signed = Data(token.split(separator: ".").prefix(2).joined(separator: ".").utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: parts[2]), for: signed))
    }

    func testRatingCountHistoryCarriesStoresForward() throws {
        let store = try makeStore()
        let d0 = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)).timeIntervalSince1970
        try store.recordRatings(["1": Rating(value: 4, count: 10)], for: ["1"], store: "jp", at: d0 + 3600)
        try store.recordRatings(["1": Rating(value: 4, count: 5)], for: ["1"], store: "us", at: d0 + 7200)
        try store.recordRatings(["1": Rating(value: 4, count: 12)], for: ["1"], store: "jp", at: d0 + 86400 + 3600) // us not checked that day
        XCTAssertEqual(try store.ratingCountHistory(appID: "1", store: KeywordStore.allStores).map(\.count), [15, 17])
        XCTAssertEqual(try store.ratingCountHistory(appID: "1", store: "jp").map(\.count), [10, 12])
    }

    func testReviewHistoryStacksTonesPerDay() {
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let d2 = cal.date(byAdding: .day, value: 2, to: d0)!
        let points = ReviewTone.cumulative([(d0.addingTimeInterval(3600), 5), (d0.addingTimeInterval(7200), 1), (d2.addingTimeInterval(3600), 4)],
                                           now: cal.date(byAdding: .day, value: 5, to: d0)!)
        func at(_ day: Date) -> [ReviewTone: Int] {
            Dictionary(uniqueKeysWithValues: points.filter { $0.date == day }.compactMap { p in p.tone.map { ($0, p.count) } })
        }
        XCTAssertEqual(at(d0), [.good: 1, .neutral: 0, .bad: 1])
        XCTAssertEqual(at(d2), [.good: 2, .neutral: 0, .bad: 1])
        XCTAssertEqual(points.count, 9) // d0, d2, then carried to today
        XCTAssertNotNil(ConnectAPI.parseDate("2024-05-01T12:34:56-07:00"))
        XCTAssertNotNil(ConnectAPI.parseDate("2024-05-01T12:34:56.123Z"))
    }

    func testEveryStoreHasAConnectTerritory() {
        XCTAssertEqual(Set(ConnectAPI.territories.keys), Set(AppStoreSearch.storefronts.keys))
    }

    func testTrendsForSparklines() async throws {
        let store = try makeStore()
        _ = try store.addKeywords(["a"], appID: "1", store: "jp")
        for ids in [["1"], ["x"], ["x", "1"]] {
            try await Updater.updateRanks(store: store, search: { _, _ in .init(ids: ids, top: []) }, pause: .zero)
            try store.db.run("UPDATE keywords SET updated = NULL") // make it due again
        }
        let now = Date().timeIntervalSince1970
        try store.setPopularity([(term: "a", popularity: 20)], store: "jp", at: now)
        try store.setPopularity([(term: "a", popularity: 35)], store: "jp", at: now)
        let k = try XCTUnwrap(store.keywords(appID: "1", store: "jp").first)
        XCTAssertEqual(k.rankTrend, [1, 2]) // 圏外 dropped
        XCTAssertEqual(k.popularityTrend, [20, 35])
    }

    func testMarkPersistsAndMakesKeywordDaily() async throws {
        let store = try makeStore()
        _ = try store.addKeywords(["a"], appID: "1", store: "jp")
        try await Updater.updateRanks(store: store, search: { _, _ in .init(ids: [], top: []) }, pause: .zero)
        let id = try XCTUnwrap(store.keywords(appID: "1", store: "jp").first?.id)
        try store.db.run("UPDATE keywords SET updated = ?", [Date().timeIntervalSince1970 - 86_400])
        XCTAssertTrue(try store.dueRankGroups(now: Date().timeIntervalSince1970).isEmpty) // 圏外 → weekly
        try store.setMark(.red, keywordIDs: [id])
        XCTAssertEqual(try store.keywords(appID: "1", store: "jp").first?.mark, .red)
        XCTAssertEqual(try store.dueRankGroups(now: Date().timeIntervalSince1970).count, 1) // marked → daily
        try store.setMark(nil, keywordIDs: [id])
        XCTAssertNil(try store.keywords(appID: "1", store: "jp").first?.mark)
    }

    func testUpdateOneAppIgnoresSchedule() async throws {
        let store = try makeStore()
        _ = try store.addKeywords(["a", "b"], appID: "1", store: "jp")
        _ = try store.addKeywords(["c"], appID: "2", store: "jp")
        try await Updater.updateRanks(store: store, search: { _, _ in .init(ids: ["1"], top: []) }, pause: .zero)
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(try store.dueRankGroups(now: now).isEmpty)
        XCTAssertEqual(try store.dueRankGroups(now: now, appID: "1").map(\.text).sorted(), ["a", "b"])
    }

    func testDeletesCascadeToHistory() async throws {
        let store = try makeStore()
        _ = try store.addKeywords(["a", "b"], appID: "1", store: "jp")
        try await Updater.updateRanks(store: store, search: { _, _ in .init(ids: ["1"], top: []) }, pause: .zero)
        let a = try XCTUnwrap(store.keywords(appID: "1", store: "jp").first { $0.text == "a" })
        XCTAssertEqual(try store.history(keywordID: a.id, since: 0).count, 1)

        try store.deleteKeywords([a.id])
        XCTAssertEqual(try store.history(keywordID: a.id, since: 0).count, 0)

        try store.deleteApp("1")
        XCTAssertEqual(try store.apps().map(\.id), ["2"])
        var orphans = -1
        try store.db.query("SELECT count(*) FROM rankings") { orphans = $0.int(0)! }
        XCTAssertEqual(orphans, 0)
    }
}
