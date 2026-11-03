import Foundation
import Observation
import WebKit

/// View model for background update jobs and the Search Ads session.
@MainActor
@Observable
final class UpdateModel {
    @ObservationIgnored let store: KeywordStore
    @ObservationIgnored private let onFinish: () -> Void
    let web = WKWebView()

    private(set) var adsLoggedIn = false
    private(set) var busy = false
    private(set) var progress: (label: String, done: Int, total: Int)?
    private(set) var status = ""
    private(set) var nextAuto: Date?
    var error: String?

    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var loadObservation: NSKeyValueObservation?

    /// `onFinish` runs after every job so the library can re-read what changed.
    init(store: KeywordStore, onFinish: @escaping () -> Void) {
        self.store = store
        self.onFinish = onFinish
        web.load(URLRequest(url: AdsPopularity.home))
        loadObservation = web.observe(\.isLoading) { [weak self] web, _ in
            Task { @MainActor in self?.adsLoggedIn = AdsPopularity.isLoggedIn(web) }
        }
    }

    /// With `appID`, checks every keyword of that app now instead of only the due ones.
    func updateRanks(appID: String? = nil) {
        guard !busy else { return }
        job = Task { await runRanks(appID: appID) }
    }

    func updatePopularity() {
        guard adsLoggedIn else { error = "Search Ads にログインしてください（ウインドウ > Search Ads）"; return }
        guard !busy else { return }
        job = Task { await runPopularity() }
    }

    func cancel() { job?.cancel() }

    /// Last result plus when the next automatic check runs, so an idle hour doesn't look stalled.
    var statusLine: String {
        let next = nextAuto.map { "次回 \($0.formatted(date: .omitted, time: .shortened))" }
        return [status, next].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Runs due updates now and then hourly while the app is open.
    func autoUpdate() async {
        while !Task.isCancelled {
            if !busy {
                job = Task {
                    await runRanks()
                    if adsLoggedIn && !Task.isCancelled { await runPopularity() }
                }
                await job?.value
            }
            nextAuto = Date(timeIntervalSinceNow: 3600)
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func runRanks(appID: String? = nil) async {
        await run("順位") { [store] progress in
            try await Updater.updateRanksAndRatings(store: store, appID: appID, progress: progress)
        }
    }

    private func runPopularity() async {
        await run("人気度") { [store, web] progress in try await Updater.updatePopularity(store: store, web: web, progress: progress) }
    }

    private func run(_ label: String, _ body: (@escaping (Int, Int) -> Void) async throws -> Void) async {
        busy = true
        defer { busy = false; progress = nil; onFinish() }
        do {
            try await body { [weak self] done, total in self?.progress = total == 0 ? nil : (label, done, total) }
            status = "\(label)の更新完了 \(Date().formatted(date: .omitted, time: .shortened))"
        } catch is CancellationError {
            status = "\(label)の更新を中止"
        } catch {
            self.error = "\(label): \(error)"
            status = ""
        }
    }
}
