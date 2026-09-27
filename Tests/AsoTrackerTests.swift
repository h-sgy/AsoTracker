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
        try store.recordRatings(["1": Rating(value: 4.5, count: 10), "2": Rating(value: nil, count: nil)], store: "jp", at: 200)
        XCTAssertEqual(try store.dueRatings(cutoff: 100), ["us": ["1"]])
        XCTAssertEqual(try store.latestRating(appID: "1", store: "jp"), Rating(value: 4.5, count: 10))
        XCTAssertEqual(try store.dueRatings(cutoff: 300).count, 2)
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
