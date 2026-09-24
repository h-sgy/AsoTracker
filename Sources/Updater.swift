import Foundation
import WebKit

/// Update jobs shared by the app and the CLI: fetch from the network, record through the store.
enum Updater {
    /// Checks due rankings sequentially. Returns the number of search requests made.
    /// ponytail: one request at a time with a fixed pause; parallelize per store if runs get too long.
    @discardableResult
    static func updateRanks(store: KeywordStore, limit: Int? = nil,
                            search: (String, String) async throws -> AppStoreSearch.SearchResult = AppStoreSearch.search,
                            pause: Duration = .milliseconds(400),
                            progress: (Int, Int) -> Void = { _, _ in }) async throws -> Int {
        var groups = try store.dueRankGroups(now: Date().timeIntervalSince1970)
        if let limit { groups = Array(groups.prefix(limit)) }
        for (i, g) in groups.enumerated() {
            try Task.checkCancellation()
            progress(i, groups.count)
            let result: AppStoreSearch.SearchResult
            do {
                result = try await searchWithBackoff(term: g.text, store: g.store, search: search)
            } catch is AppStoreSearch.Throttled {
                throw DBError(description: "App Store search is throttling; stopped after \(i) of \(groups.count)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("skip \(g.store)/\(g.text): \(error)")
                continue
            }
            try store.recordSearch(result, for: g, at: Date().timeIntervalSince1970)
            try await Task.sleep(for: pause)
        }
        progress(groups.count, groups.count)
        return groups.count
    }

    private static func searchWithBackoff(term: String, store: String,
                                          search: (String, String) async throws -> AppStoreSearch.SearchResult) async throws -> AppStoreSearch.SearchResult {
        for attempt in 0..<3 {
            do { return try await search(term, store) }
            catch is AppStoreSearch.Throttled where attempt < 2 { try await Task.sleep(for: .seconds(60)) }
        }
        throw AppStoreSearch.Throttled()
    }

    /// Refreshes Search Ads popularity for keywords older than a week, 100 terms per request.
    @MainActor
    static func updatePopularity(store: KeywordStore, web: WKWebView, progress: (Int, Int) -> Void = { _, _ in }) async throws {
        let due = try store.duePopularity(cutoff: Date().timeIntervalSince1970 - Schedule.popularity)
        let batches = due.flatMap { storeCode, v in
            stride(from: 0, to: v.terms.count, by: 100).map { (storeCode, v.adamID, Array(v.terms[$0..<min($0 + 100, v.terms.count)])) }
        }
        for (i, (storeCode, adamID, terms)) in batches.enumerated() {
            try Task.checkCancellation()
            progress(i, batches.count)
            let pops = try await AdsPopularity.fetch(web, terms: terms, store: storeCode, adamID: adamID)
            let values = zip(terms, pops).compactMap { term, pop in pop.map { (term: term, popularity: $0) } }
            try store.setPopularity(values, store: storeCode, at: Date().timeIntervalSince1970)
            try await Task.sleep(for: .milliseconds(500))
        }
        progress(batches.count, batches.count)
    }
}
