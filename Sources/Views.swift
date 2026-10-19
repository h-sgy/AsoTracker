import AppKit
import Charts
import SwiftUI
import WebKit

struct AsoTrackerApp: App {
    @State private var library: LibraryModel
    @State private var updates: UpdateModel

    init() {
        let store: KeywordStore
        do { store = KeywordStore(db: try DB()) } catch { fatalError("\(error)") }
        let library = LibraryModel(store: store)
        _library = State(initialValue: library)
        _updates = State(initialValue: UpdateModel(store: store, onFinish: { library.reload() }))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(updates)
                .tint(.brand)
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await library.loadMissingIcons()
                    await updates.autoUpdate()
                }
        }
        .defaultSize(width: 1500, height: 920)
        Window("Search Ads", id: "ads") {
            WebView(web: updates.web)
                .frame(minWidth: 900, minHeight: 700)
        }
    }
}

// MARK: - Palette

extension Color {
    /// Adapts to the system appearance.
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }

    static let brand = Color(light: 0x1F63D6, dark: 0x5B9DFF)
    static let onBrand = Color(light: 0xFFFFFF, dark: 0x0B1220)
    static let up = Color(light: 0x1F63D6, dark: 0x6FB1FF)      // blue/orange instead of green/red
    static let down = Color(light: 0xB85A00, dark: 0xFFAB5C)
    static let tintBg = Color(light: 0xDDE8FB, dark: 0x2A3A55)
    static let tintFg = Color(light: 0x1D4FA8, dark: 0xCFE0FF)
    static let amber = Color(light: 0xA07418, dark: 0xC9A15A)
    static let track = Color(light: 0xE3E3E8, dark: 0x2C2C32)
    static let card = Color(light: 0xFFFFFF, dark: 0x202024)
    static let gold = Color(light: 0xE0B12E, dark: 0xF2C94C)
    static let silver = Color(light: 0xB8BEC7, dark: 0xC9CED6)
    static let bronze = Color(light: 0xC9803F, dark: 0xD9955B)
    static let onMedal = Color(light: 0x1C1C1E, dark: 0x1C1C1E)
    static let selectedCard = Color(light: 0xE3EDFF, dark: 0x23324A)
}

// MARK: - Filters

enum Bucket: String, CaseIterable, Identifiable {
    case all = "すべて", top10 = "1〜10位", top50 = "11〜50位", rest = "51位以下", up = "上昇", down = "下降"
    var id: Self { self }

    func contains(_ k: KeywordRow) -> Bool {
        switch self {
        case .all: true
        case .top10: k.rank <= 10
        case .top50: (11...50).contains(k.rank)
        case .rest: (51..<1000).contains(k.rank)
        case .up: k.change > 0
        case .down: k.change < 0
        }
    }

    var dot: Color {
        switch self {
        case .all, .rest: .secondary
        case .top10: .brand
        case .top50: .tintFg
        case .up: .up
        case .down: .down
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(UpdateModel.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<KeywordRow.ID>()
    @State private var pendingKeywordDelete: Set<KeywordRow.ID> = []
    @State private var pendingAppDelete: AppRow?
    @State private var sortOrder = [KeyPathComparator(\KeywordRow.rank)]
    @State private var search = ""
    @State private var bucket = Bucket.all
    @State private var taggedOnly = false
    @State private var addingApp = false
    @State private var addingKeywords = false

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            List(library.apps, selection: $library.selectedAppID) { app in
                AppSidebarRow(app: app)
                    .contextMenu {
                        Button("アプリを削除…", systemImage: "trash", role: .destructive) { pendingAppDelete = app }
                    }
            }
                .navigationSplitViewColumnWidth(min: 220, ideal: 264)
                .safeAreaInset(edge: .bottom) {
                    Button { addingApp = true } label: {
                        Label("アプリを追加", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .padding(12)
                }
                .sheet(isPresented: $addingApp) { AddAppSheet() }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                header
                KPIBar(keywords: library.keywords, selection: $bucket)
                HStack(spacing: 10) {
                    TextField("キーワードを絞り込み", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    Toggle("タグ付きのみ", isOn: $taggedOnly)
                        .toggleStyle(.button)
                        .controlSize(.large)
                }
                keywordTable
            }
            .padding([.top, .horizontal], 24)
            .navigationSplitViewColumnWidth(min: 640, ideal: 820)
        } detail: {
            if selection.count == 1, let kw = library.keywords.first(where: { $0.id == selection.first }) {
                KeywordDetail(keyword: kw).id(kw.id)
            } else {
                ContentUnavailableView("キーワードを選択", systemImage: "chart.xyaxis.line",
                                       description: Text("一覧から選ぶと順位の推移を表示します"))
            }
        }
        .navigationTitle("")
        .toolbar { toolbar }
        .confirmationDialog(keywordDeleteTitle, isPresented: Binding(get: { !pendingKeywordDelete.isEmpty }, set: { if !$0 { pendingKeywordDelete = [] } })) {
            Button("削除", role: .destructive) {
                library.deleteKeywords(pendingKeywordDelete)
                selection.subtract(pendingKeywordDelete)
                pendingKeywordDelete = []
            }
        } message: {
            Text("順位の履歴とタグも削除されます。元に戻せません。")
        }
        .confirmationDialog("「\(pendingAppDelete?.name ?? "")」を削除しますか？", isPresented: Binding(get: { pendingAppDelete != nil }, set: { if !$0 { pendingAppDelete = nil } })) {
            Button("削除", role: .destructive) {
                if let app = pendingAppDelete { library.deleteApp(app.id) }
                selection = []
                pendingAppDelete = nil
            }
        } message: {
            Text("キーワード \(pendingAppDelete?.keywordCount.formatted() ?? "0") 件と、その順位・評価の履歴もすべて削除されます。元に戻せません。")
        }
        .alert("エラー", isPresented: Binding(get: { library.error != nil || updates.error != nil },
                                              set: { if !$0 { library.error = nil; updates.error = nil } })) {
        } message: { Text(library.error ?? updates.error ?? "") }
    }

    private var header: some View {
        @Bindable var library = library
        let app = library.selectedApp
        let last = library.keywords.compactMap(\.updated).max()
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app?.name ?? "").font(.system(size: 24, weight: .bold)).lineLimit(1)
                Text("\(library.keywords.count.formatted()) キーワード · 最終確認 \(last?.formatted(date: .abbreviated, time: .shortened) ?? "—")\(ratingText)")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            StorePicker(stores: library.stores, selection: $library.storeCode)
                .fixedSize()
            Button("キーワードを追加", systemImage: "plus") { addingKeywords = true }
                .controlSize(.large)
                .fixedSize()
                .disabled(library.selectedAppID == nil)
                .sheet(isPresented: $addingKeywords) { AddKeywordsSheet() }
        }
    }

    private var ratingText: String {
        guard let r = library.rating, let v = r.value, let n = r.count else { return "" }
        return " · ★ \(v.formatted(.number.precision(.fractionLength(1))))  \(n.formatted()) 件"
    }

    private var keywordTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("キーワード", value: \.text) { Text($0.text).font(.system(size: 14, weight: .medium)).lineLimit(1) }
                .width(min: 180, ideal: 260)
            TableColumn("順位", value: \.rank) { k in
                HStack(spacing: 8) {
                    RankBadge(rank: k.rank)
                    Sparkline(values: k.rankTrend, reversed: true)
                }
            }.width(128)
            TableColumn("変化", value: \.change) { ChangeLabel(keyword: $0) }.width(64)
            TableColumn("人気度", value: \.displayPopularity) { k in
                HStack(spacing: 8) {
                    MeterCell(value: k.displayPopularity, color: k.popularity < 0 ? .secondary : .brand)
                    Sparkline(values: k.popularityTrend)
                }
                    .help(k.popularity < 0 ? "Astro の値（Search Ads 未取得）" : "Search Ads の人気度")
            }.width(176)
            TableColumn("難易度", value: \.difficulty) { k in
                MeterCell(value: k.difficulty, color: k.difficulty >= 60 ? .down : k.difficulty >= 40 ? .amber : .secondary)
            }.width(120)
            TableColumn("競合数", value: \.appsCount) { Text("\($0.appsCount)").font(.system(size: 13)).foregroundStyle(.secondary) }
                .width(56)
            TableColumn("タグ", value: \.tags) { Text($0.tags).font(.system(size: 12)).foregroundStyle(.secondary) }
                .width(min: 40, ideal: 70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .environment(\.defaultMinListRowHeight, 40)
        .contextMenu(forSelectionType: KeywordRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("\(ids.count) 件のキーワードを削除…", systemImage: "trash", role: .destructive) { pendingKeywordDelete = ids }
            }
        }
        .onDeleteCommand { if !selection.isEmpty { pendingKeywordDelete = selection } }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
    }

    private var keywordDeleteTitle: String {
        let words = library.keywords.filter { pendingKeywordDelete.contains($0.id) }.map(\.text)
        let shown = words.prefix(5).map { "「\($0)」" }.joined(separator: "")
        return words.count <= 5 ? "\(shown)を削除しますか？" : "\(shown)ほか \(words.count - 5) 件を削除しますか？"
    }

    private var rows: [KeywordRow] {
        library.keywords
            .filter { bucket.contains($0) && (!taggedOnly || !$0.tags.isEmpty) }
            .filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let p = updates.progress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .progressViewStyle(.linear).frame(width: 120)
                    Text("\(p.label) \(p.done)/\(p.total)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            } else if !updates.status.isEmpty {
                Text(updates.status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if updates.busy {
                Button("中止", systemImage: "stop.fill") { updates.cancel() }.labelStyle(.titleAndIcon)
            } else {
                Button("順位を更新", systemImage: "arrow.clockwise") { updates.updateRanks() }.labelStyle(.titleAndIcon)
                Button("人気度を更新", systemImage: "flame") {
                    if updates.adsLoggedIn { updates.updatePopularity() } else { openWindow(id: "ads") }
                }.labelStyle(.titleAndIcon)
            }
            Button { openWindow(id: "ads") } label: {
                Label {
                    Text("Search Ads")
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(updates.adsLoggedIn ? .green : .secondary)
                }
            }
            .labelStyle(.titleAndIcon)
            .help(updates.adsLoggedIn ? "ログイン済み" : "未ログイン（人気度の更新に必要）")
        }
    }
}

// MARK: - Sidebar

struct AddAppSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var country = "jp"
    @State private var results: [FoundApp] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("アプリを追加").font(.title2.bold())
            HStack {
                TextField("アプリ名、App Store の ID または URL", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Picker("ストア", selection: $country) {
                    ForEach(AppStoreSearch.storefronts.keys.sorted(), id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                Button("検索", action: search).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            List(results) { app in
                let tracked = library.apps.contains { $0.id == app.id }
                HStack(spacing: 10) {
                    AsyncImage(url: app.icon.flatMap(URL.init(string:))) { $0.resizable() } placeholder: { Color.track }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(app.developer).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tracked {
                        Text("追加済み").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button("追加") { library.addApp(app); dismiss() }
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if searching { ProgressView() }
                else if results.isEmpty { Text("検索するとここに候補が出ます").foregroundStyle(.secondary) }
            }
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func search() {
        searching = true
        Task {
            results = await library.findApps(query, country: country)
            searching = false
        }
    }
}

struct AddKeywordsSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(UpdateModel.self) private var updates
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var store = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("キーワードを追加").font(.title2.bold())
            Text(library.selectedApp?.name ?? "")
                .foregroundStyle(.secondary)
            Picker("ストア", selection: $store) {
                ForEach(AppStoreSearch.storefronts.keys.sorted(), id: \.self) { Text($0.uppercased()).tag($0) }
            }
            .frame(width: 180)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text("1 行に 1 つ、またはカンマ区切り。追加後すぐに順位を確認します。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("追加") {
                    if library.addKeywords(text, store: store) > 0 { updates.updateRanks() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .onAppear { store = library.storeCode.isEmpty ? "jp" : library.storeCode }
    }
}

struct AppSidebarRow: View {
    let app: AppRow
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: app.icon.flatMap(URL.init(string:))) { image in
                image.resizable()
            } placeholder: {
                Text(String(app.name.prefix(1)))
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.track)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                (Text("\(app.keywordCount.formatted()) 語 · 上位10 ") + Text("\(app.top10)").bold().foregroundStyle(.primary))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - List pieces

struct StorePicker: View {
    let stores: [String]
    @Binding var selection: String
    private let visible = 4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(stores.prefix(visible), id: \.self) { segment($0) }
            if stores.count > visible {
                let rest = Array(stores.dropFirst(visible))
                Menu {
                    ForEach(rest, id: \.self) { s in Button(s.uppercased()) { selection = s } }
                } label: {
                    Text(rest.contains(selection) ? selection.uppercased() : "他 \(rest.count)")
                        .font(.system(size: 13, weight: rest.contains(selection) ? .semibold : .regular))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(rest.contains(selection) ? Color.card : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(3)
        .background(Color.track, in: RoundedRectangle(cornerRadius: 9))
    }

    private func segment(_ s: String) -> some View {
        let on = s == selection
        return Button { selection = s } label: {
            Text(s.uppercased())
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(on ? Color.card : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct KPIBar: View {
    let keywords: [KeywordRow]
    @Binding var selection: Bucket

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Bucket.allCases) { b in
                let on = b == selection
                Button { selection = b } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(b.dot).frame(width: 8, height: 8)
                            Text(b.rawValue).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(keywords.filter(b.contains).count.formatted())
                            .font(.system(size: 24, weight: .bold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(on ? Color.selectedCard : Color.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.brand : Color.secondary.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RankBadge: View {
    let rank: Int

    private var background: Color {
        switch rank {
        case 1: .gold
        case 2: .silver
        case 3: .bronze
        case ...10: .brand
        case ...50: .tintBg
        default: .clear
        }
    }
    var body: some View {
        if rank >= 1000 {
            Text("圏外").font(.system(size: 12)).foregroundStyle(.tertiary)
        } else {
            Text("\(rank)")
                .font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(rank <= 3 ? Color.onMedal : rank <= 10 ? Color.onBrand : rank <= 50 ? Color.tintFg : Color.primary)
                .frame(minWidth: 40, minHeight: 24)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct ChangeLabel: View {
    let keyword: KeywordRow
    var body: some View {
        Group {
            if keyword.prevRank >= 1000 && keyword.rank < 1000 {
                Text("IN").foregroundStyle(Color.up)
            } else if keyword.rank >= 1000 && keyword.prevRank < 1000 {
                Text("OUT").foregroundStyle(Color.down)
            } else if keyword.change > 0 {
                Text("▲ \(keyword.change)").foregroundStyle(Color.up)
            } else if keyword.change < 0 {
                Text("▼ \(-keyword.change)").foregroundStyle(Color.down)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
    }
}

struct MeterCell: View {
    let value: Int
    let color: Color
    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.track)
                .frame(width: 64, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: 64 * CGFloat(max(4, min(value, 100))) / 100, height: 6)
                }
            Text("\(value)").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

/// Tiny trend line for a table cell. `reversed` puts small values on top (ranks). Blank under two points.
struct Sparkline: View {
    let values: [Int]
    var reversed = false

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return }
            let span = CGFloat(max(hi - lo, 1))
            func point(_ i: Int) -> CGPoint {
                let t = CGFloat(values[i] - lo) / span
                return CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                               y: 2 + (size.height - 4) * (reversed ? t : 1 - t))
            }
            var path = Path()
            path.move(to: point(0))
            for i in 1..<values.count { path.addLine(to: point(i)) }
            ctx.stroke(path, with: .color(.brand), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(origin: point(values.count - 1), size: .zero).insetBy(dx: -2, dy: -2)), with: .color(.brand))
        }
        .frame(width: 56, height: 20)
    }
}

// MARK: - Detail

struct KeywordDetail: View {
    @Environment(LibraryModel.self) private var library
    let keyword: KeywordRow
    @State private var days: Int? = 30
    @State private var note = ""
    @State private var topApps: [TopApp] = []

    var body: some View {
        let points = library.history(for: keyword.id, days: days)
        let ranked = points.filter { $0.rank < 1000 }.map(\.rank)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        chip(library.storeCode.uppercased())
                        ForEach(keyword.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, id: \.self) { chip($0) }
                    }
                    Text(keyword.text).font(.system(size: 26, weight: .bold)).textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if keyword.rank >= 1000 {
                        Text("圏外").font(.system(size: 40, weight: .heavy))
                    } else {
                        (Text("\(keyword.rank)").font(.system(size: 56, weight: .heavy))
                            + Text(" 位").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary))
                            .monospacedDigit()
                    }
                    ChangeLabel(keyword: keyword).font(.system(size: 16, weight: .bold))
                    if keyword.prevRank < 1000 && keyword.prevRank != keyword.rank {
                        Text("前回 \(keyword.prevRank) 位").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    statCard("人気度", keyword.popularity < 0 ? "\(keyword.astroPopularity)" : "\(keyword.popularity)",
                             sub: keyword.popularity < 0 ? "Astro" : nil)
                    statCard("難易度", "\(keyword.difficulty)")
                    statCard("競合数", "\(keyword.appsCount)")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Picker("期間", selection: $days) {
                        Text("1週間").tag(Int?.some(7))
                        Text("1か月").tag(Int?.some(30))
                        Text("1年").tag(Int?.some(365))
                        Text("全期間").tag(Int?.none)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if ranked.isEmpty {
                        ContentUnavailableView("この期間は圏外", systemImage: "chart.line.downtrend.xyaxis")
                            .frame(height: 220)
                    } else {
                        RankChart(points: points.filter { $0.rank < 1000 }).frame(height: 220)
                        HStack {
                            summary("最高", "\(ranked.min()!) 位")
                            summary("平均", "\(ranked.reduce(0, +) / ranked.count) 位")
                            summary("最低", "\(ranked.max()!) 位")
                            summary("圏外", "\(points.count - ranked.count) 回")
                        }
                    }
                }
                TopAppsSection(apps: topApps, ownAppID: library.selectedAppID)
                VStack(alignment: .leading, spacing: 6) {
                    Text("メモ").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $note)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 80)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                        .onChange(of: note) { _, new in library.saveNote(new, for: keyword.id) }
                }
            }
            .padding(24)
        }
        .onAppear { note = keyword.note }
        .task {
            topApps = library.topApps(for: keyword.id)
            if topApps.isEmpty { topApps = await library.refreshTopApps(for: keyword.id) }
        }
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.track, in: Capsule())
    }

    private func statCard(_ title: String, _ value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                if let sub { Text(sub).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TopAppsSection: View {
    let apps: [TopApp]
    let ownAppID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上位アプリ").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if apps.isEmpty {
                ProgressView().controlSize(.small)
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                let own = app.id == ownAppID
                HStack(spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    AsyncImage(url: app.icon.flatMap(URL.init(string:))) { image in
                        image.resizable()
                    } placeholder: {
                        Color.track
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.system(size: 13, weight: own ? .bold : .medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            if let r = app.rating, let n = app.ratingCount {
                                Text("★ \(r, format: .number.precision(.fractionLength(1)))  \(n.formatted()) 件")
                            }
                            if let sub = app.subtitle { Text(sub).lineLimit(1) }
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if own { Text("自分").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.brand) }
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(own ? Color.selectedCard : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button("App Store で開く") { NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/id\(app.id)")!) }
                }
            }
        }
    }
}

struct RankChart: View {
    let points: [RankPoint]
    @State private var hovered: RankPoint?

    var body: some View {
        let worst = points.map(\.rank).max() ?? 1
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("日付", p.date), yStart: .value("基準", worst), yEnd: .value("順位", p.rank))
                    .foregroundStyle(Color.brand.opacity(0.12))
                LineMark(x: .value("日付", p.date), y: .value("順位", p.rank))
                    .foregroundStyle(Color.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                PointMark(x: .value("日付", last.date), y: .value("順位", last.rank))
                    .foregroundStyle(Color.brand).symbolSize(60)
            }
            if let h = hovered {
                RuleMark(x: .value("日付", h.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(h.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            Text("\(h.rank) 位").bold().monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    }
                PointMark(x: .value("日付", h.date), y: .value("順位", h.rank))
                    .foregroundStyle(Color.brand).symbolSize(40)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let loc) = phase, let frame = proxy.plotFrame,
                              let date: Date = proxy.value(atX: loc.x - geo[frame].origin.x) else { hovered = nil; return }
                        hovered = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    }
            }
        }
    }
}

struct WebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
