import Foundation
import Observation

/// View model for browsing and editing tracked apps and keywords.
@MainActor
@Observable
final class LibraryModel {
    @ObservationIgnored let store: KeywordStore

    private(set) var apps: [AppRow] = []
    var selectedAppID: String? { didSet { loadStores() } }
    private(set) var stores: [String] = []
    var storeCode: String = KeywordStore.allStores { didSet { loadKeywords() } }
    private(set) var keywords: [KeywordRow] = []
    private(set) var rating: Rating?
    var error: String?

    init(store: KeywordStore) {
        self.store = store
        loadApps()
        selectedAppID = apps.first?.id
    }

    var showsAllStores: Bool { storeCode == KeywordStore.allStores }

    var selectedApp: AppRow? { apps.first { $0.id == selectedAppID } }

    /// Re-reads everything shown, keeping the current selection.
    func reload() {
        loadApps()
        loadStores()
    }

    private func loadApps() {
        attempt { apps = try store.apps() }
    }

    private func loadStores() {
        guard let selectedAppID else { stores = []; keywords = []; return }
        attempt { stores = try store.stores(appID: selectedAppID) }
        let fallback = stores.count > 1 ? KeywordStore.allStores : stores.first ?? ""
        let next = stores.contains(storeCode) || storeCode == KeywordStore.allStores && stores.count > 1 ? storeCode : fallback
        if next == storeCode { loadKeywords() } else { storeCode = next }
    }

    private func loadKeywords() {
        guard let selectedAppID else { keywords = []; rating = nil; return }
        attempt {
            keywords = try store.keywords(appID: selectedAppID, store: storeCode)
            rating = try store.latestRating(appID: selectedAppID, store: storeCode)
        }
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { self.error = "\(error)" }
    }

    // MARK: - Keyword detail

    func history(for keywordID: Int, days: Int?) -> [RankPoint] {
        let since = days.map { Date().timeIntervalSince1970 - Double($0) * 86400 } ?? 0
        return (try? store.history(keywordID: keywordID, since: since)) ?? []
    }

    func topApps(for keywordID: Int) -> [TopApp] {
        (try? store.topApps(keywordID: keywordID)) ?? []
    }

    /// Fetches the top apps now for a keyword whose last rank check predates stored top apps.
    func refreshTopApps(for keywordID: Int) async -> [TopApp] {
        guard let term = try? store.term(keywordID: keywordID),
              let result = try? await AppStoreSearch.search(term: term.text, store: term.store) else { return [] }
        attempt { try store.setTopApps(result.top, store: term.store, text: term.text) }
        return result.top
    }

    func setMark(_ mark: KeywordMark?, for ids: Set<Int>) {
        attempt { try store.setMark(mark, keywordIDs: ids) }
        for i in keywords.indices where ids.contains(keywords[i].id) { keywords[i].mark = mark }
    }

    func saveNote(_ note: String, for keywordID: Int) {
        attempt { try store.setNote(note, keywordID: keywordID) }
        if let i = keywords.firstIndex(where: { $0.id == keywordID }) { keywords[i].note = note }
    }

    // MARK: - Adding and removing

    func findApps(_ query: String, country: String) async -> [FoundApp] {
        do { return try await AppCatalog.find(query, country: country) }
        catch { self.error = "App Store の検索に失敗: \(error.localizedDescription)"; return [] }
    }

    func addApp(_ app: FoundApp) {
        attempt { try store.addApp(app) }
        loadApps()
        selectedAppID = app.id
    }

    /// Returns how many keywords were new.
    @discardableResult
    func addKeywords(_ text: String, store storeCode: String) -> Int {
        guard let appID = selectedAppID else { return 0 }
        var added = 0
        attempt { added = try store.addKeywords(KeywordStore.parseKeywords(text), appID: appID, store: storeCode) }
        loadApps()
        loadStores()
        self.storeCode = storeCode
        return added
    }

    func deleteApp(_ id: String) {
        attempt { try store.deleteApp(id) }
        loadApps()
        if selectedAppID == id { selectedAppID = apps.first?.id }
    }

    func deleteKeywords(_ ids: Set<Int>) {
        attempt { try store.deleteKeywords(ids) }
        reload()
    }

    /// Fetches icons once for apps that have none.
    /// ponytail: never refreshed; clear apps.icon to pick up a changed icon.
    func loadMissingIcons() async {
        guard let ids = try? store.appIDsMissingIcon(), !ids.isEmpty,
              let icons = try? await AppCatalog.icons(ids: ids) else { return }
        attempt { try store.setIcons(icons) }
        loadApps()
    }
}
