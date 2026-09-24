import Foundation

/// `AsoTracker` with no flags opens the app. Headless modes for setup and cron-style runs:
///   --import "<developer name>"   one-time copy of that developer's apps from Astro
///   --update-ranks [--limit N]    check due rankings and exit
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        guard args.contains("--import") || args.contains("--update-ranks") else {
            AsoTrackerApp.main()
            return
        }
        Task {
            do {
                let db = try DB()
                if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
                    let start = Date()
                    try db.importAstro(developer: args[i + 1])
                    for table in ["apps", "keywords", "rankings", "tags", "keyword_tags", "ratings"] {
                        try db.query("SELECT count(*) FROM \(table)") { print(table, $0.int(0)!) }
                    }
                    print(String(format: "imported in %.1fs → %@", Date().timeIntervalSince(start), DB.defaultPath))
                }
                if args.contains("--update-ranks") {
                    let limit = args.firstIndex(of: "--limit").flatMap { Int(args[$0 + 1]) }
                    let n = try await Updater.updateRanks(store: KeywordStore(db: db), limit: limit) { done, total in
                        if done % 50 == 0 || done == total { print("ranks \(done)/\(total)") }
                    }
                    print("checked \(n) search terms")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
