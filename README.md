# AsoTracker

自分のアプリの App Store キーワード順位を追跡する、個人用の macOS アプリです。有料の ASO ツールを置き換えるために作りました。

- 58 か国の App Store で順位を確認（重要な語は毎日、それ以外は週 1 回）
- Apple Search Ads（自分のアカウント）からキーワードの人気度を取得
- 評価と評価数を毎日記録。App Store Connect API を設定すると自分のアプリのレビュー数も記録
- 順位推移グラフ、キーワードごとの上位 5 アプリ、メモ、タグ
- [Astro](https://tryastro.app) からデータを一括で取り込み
- データはすべてローカルの SQLite ファイルに保存

## 必要なもの

- macOS 15 以降
- Xcode 16 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

## ビルド

```sh
xcodegen generate
xcodebuild -project AsoTracker.xcodeproj -scheme AsoTracker -derivedDataPath build build
open build/Build/Products/Debug/AsoTracker.app
```

テストは同じオプションで `xcodebuild ... test` を実行します。

## 使い方

- **アプリの追加**: サイドバー下の「アプリを追加」から。アプリ名、App Store の ID、URL のどれでも検索できます。
- **キーワードの追加**: ヘッダーの「キーワードを追加」から。ストアを選び、1 行に 1 つずつ入力します。
- **人気度**: ツールバーの「Search Ads」を押し、開いたウインドウで Apple Search Ads にログインします。以後、人気度は週 1 回更新されます。
- **レビュー数**: アプリの「設定…」（⌘,）で App Store Connect API の Issuer ID・キー ID・秘密鍵（.p8）を指定します。.p8 はコピーされず、指定した場所から読み込みます。リポジトリ内には置かないでください。
- **更新**: 起動時と、起動中は 1 時間ごとに自動で実行されます。100 位以内かタグ付きのキーワードは毎日、それ以外は週 1 回確認します。
- **削除**: サイドバーのアプリ、または一覧のキーワードを右クリック（キーワードは Delete キーでも可）。

### Astro からの取り込み

Astro がインストールされていれば、指定した開発者名のアプリ・キーワード・順位履歴をまとめてコピーできます（Astro 側のデータは読み取るだけです）。

```sh
build/Build/Products/Debug/AsoTracker.app/Contents/MacOS/AsoTracker --import "開発者名"
```

### 画面なしで順位を更新

```sh
AsoTracker --update-ranks [--limit N]
```

データは `~/Library/Application Support/AsoTracker/aso.sqlite` に保存されます。

## 構成

| 層 | ファイル |
|---|---|
| View（SwiftUI） | `Views.swift` |
| ViewModel | `LibraryModel`（表示・編集）、`UpdateModel`（更新ジョブ・Search Ads のセッション） |
| 更新処理 | `Updater` — 取得して、ストア経由で記録 |
| データアクセス | `KeywordStore`（SQL はすべてここ）、`DB`（SQLite3 の薄いラッパー） |
| 通信 | `Fetchers.swift` — App Store 検索、Search Ads の人気度、iTunes Lookup |

外部ライブラリには依存していません。

## 注意

順位は App Store 自身の検索エンドポイントから、人気度は Apple Search Ads の管理画面が内部で使っている API から取得しています。どちらも公開・文書化された API ではないため、予告なく変わったり使えなくなったりする可能性があります。Apple の利用規約に沿って使うのは利用者の責任です。リクエストは 1 件ずつ間隔を空けて送っています。人気度は、ログインした Search Ads アカウントが所有するアプリについてのみ取得できます。

## ライセンス

MIT — [LICENSE](LICENSE) を参照してください。
