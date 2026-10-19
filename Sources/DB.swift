import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible {
    let description: String
}

/// Minimal SQLite3 wrapper. All access happens on one thread (main actor in the app, main task in the CLI).
final class DB {
    private var handle: OpaquePointer?

    static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AsoTracker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aso.sqlite").path
    }

    init(path: String = DB.defaultPath) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw DBError(description: "open failed: \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try exec(DB.schema)
        try? exec("ALTER TABLE keywords ADD COLUMN top_apps TEXT") // JSON [TopApp]; fails harmlessly once added
        try? exec("ALTER TABLE apps ADD COLUMN icon TEXT")
        try? exec("ALTER TABLE keywords ADD COLUMN mark TEXT") // KeywordMark raw value
    }

    deinit { sqlite3_close(handle) }

    static let schema = """
    CREATE TABLE IF NOT EXISTS apps(id TEXT PRIMARY KEY, name TEXT NOT NULL, developer TEXT, platform TEXT NOT NULL DEFAULT 'iphone');
    CREATE TABLE IF NOT EXISTS keywords(
        id INTEGER PRIMARY KEY,
        app_id TEXT NOT NULL REFERENCES apps(id),
        store TEXT NOT NULL,
        text TEXT NOT NULL,
        popularity INTEGER,          -- Apple Search Ads (5-100)
        astro_popularity INTEGER,    -- last value Astro showed; frozen at import
        difficulty INTEGER,          -- Astro's difficulty; frozen at import
        apps_count INTEGER,
        rank INTEGER,                -- 1000 = not in results
        prev_rank INTEGER,
        updated REAL,                -- unix time of last rank check
        pop_updated REAL,
        note TEXT,
        UNIQUE(app_id, store, text)
    );
    CREATE TABLE IF NOT EXISTS rankings(keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE, date REAL NOT NULL, rank INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS rankings_kw_date ON rankings(keyword_id, date);
    CREATE TABLE IF NOT EXISTS tags(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT);
    CREATE TABLE IF NOT EXISTS keyword_tags(
        keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
        tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY(keyword_id, tag_id));
    CREATE TABLE IF NOT EXISTS ratings(app_id TEXT NOT NULL, store TEXT NOT NULL, date REAL NOT NULL, rating REAL, count INTEGER);
    CREATE INDEX IF NOT EXISTS ratings_app ON ratings(app_id, store, date);
    CREATE TABLE IF NOT EXISTS popularity_history(store TEXT NOT NULL, text TEXT NOT NULL, date REAL NOT NULL, popularity INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS popularity_history_term ON popularity_history(store, text, date);
    """

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError(description: msg)
        }
    }

    /// Runs `sql` with `args` bound in order, calling `row` for each result row.
    func query(_ sql: String, _ args: [Any?] = [], row: ((Row) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(description: String(cString: sqlite3_errmsg(handle)) + " — " + sql)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: throw DBError(description: "unsupported bind type \(type(of: arg!))")
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError(description: String(cString: sqlite3_errmsg(handle))) }
            row?(Row(stmt: stmt))
        }
    }

    func run(_ sql: String, _ args: [Any?] = []) throws { try query(sql, args) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}

struct Row {
    let stmt: OpaquePointer?
    func int(_ i: Int32) -> Int? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
}

// MARK: - Astro import

extension DB {
    static let astroPath = NSHomeDirectory()
        + "/Library/Containers/matteospada.it.ASO/Data/Library/Application Support/Astro/Model.sqlite"

    /// One-time copy of Astro's Core Data store for the given developer's apps.
    /// Keyword ids reuse Astro's Z_PK so history rows join without a mapping table.
    func importAstro(developer: String, from path: String = DB.astroPath) throws {
        var existing = 0
        try query("SELECT count(*) FROM keywords") { existing = $0.int(0) ?? 0 }
        guard existing == 0 else { throw DBError(description: "already imported (\(existing) keywords); delete the DB to re-import") }

        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        try run("ATTACH DATABASE ? AS astro", [uri])
        defer { try? exec("DETACH DATABASE astro") }
        let epoch = 978_307_200.0 // Core Data reference date (2001-01-01) as unix time

        try transaction {
            try run("INSERT INTO apps(id, name, developer, platform) SELECT ZAPPID, ZNAME, ZDEVELOPER, ZPLATFORM FROM astro.ZAPPLICATION WHERE ZDEVELOPER = ?", [developer])
            try run("""
                INSERT OR IGNORE INTO keywords(id, app_id, store, text, astro_popularity, difficulty, apps_count, rank, prev_rank, updated, note)
                SELECT k.Z_PK, a.ZAPPID, k.ZSTORE, k.ZTEXT, k.ZPOPULARITY, k.ZDIFFICULTY, k.ZAPPSCOUNT,
                       k.ZCURRENTRANKING, k.ZPREVIOUSRANKING, k.ZLASTUPDATE + ?, NULLIF(k.ZNOTE, '')
                FROM astro.ZKEYWORD k JOIN astro.ZAPPLICATION a ON a.Z_PK = k.ZAPPLICATION
                WHERE a.ZDEVELOPER = ?
                ORDER BY k.Z_PK -- Astro has some duplicate keywords; keep the oldest of each
                """, [epoch, developer])
            try run("INSERT INTO rankings(keyword_id, date, rank) SELECT d.ZKEYWORD, d.ZDATE + ?, d.ZRANKING FROM astro.ZDATAPOINT d WHERE d.ZKEYWORD IN (SELECT id FROM keywords)", [epoch])
            try run("INSERT INTO tags(id, name) SELECT Z_PK, ZNAME FROM astro.ZTAG")
            try run("INSERT INTO keyword_tags SELECT Z_5KEYWORDS, Z_8TAGS FROM astro.Z_5TAGS WHERE Z_5KEYWORDS IN (SELECT id FROM keywords)")
            try run("""
                INSERT INTO ratings(app_id, store, date, rating, count)
                SELECT a.ZAPPID, r.ZSTORE, d.ZDATE + ?, d.ZAVERAGEUSERRATING, d.ZUSERRATINGCOUNT
                FROM astro.ZRATINGDATAPOINT d
                JOIN astro.ZRATING r ON r.Z_PK = d.ZRATING
                JOIN astro.Z_1RATINGS j ON j.Z_6RATINGS = r.Z_PK
                JOIN astro.ZAPPLICATION a ON a.Z_PK = j.Z_1APPLICATIONS
                WHERE a.ZDEVELOPER = ?
                """, [epoch, developer])
        }
    }
}
