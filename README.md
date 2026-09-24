# AsoTracker

A personal macOS app for tracking App Store keyword rankings for your own apps — a self-hosted replacement for paid ASO tools.

- Daily/weekly rank checks across 58 App Store storefronts
- Keyword popularity from Apple Search Ads (your own account)
- Rank history charts, top-5 competing apps per keyword, notes and tags
- One-time import of your data from [Astro](https://tryastro.app)
- Everything stays in a local SQLite file

## Requirements

- macOS 15+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```sh
xcodegen generate
xcodebuild -project AsoTracker.xcodeproj -scheme AsoTracker -derivedDataPath build build
open build/Build/Products/Debug/AsoTracker.app
```

Run the tests with `xcodebuild ... test` (same flags).

## Usage

- **Add an app**: "アプリを追加" at the bottom of the sidebar — search by name, App Store ID or URL.
- **Add keywords**: "キーワードを追加" in the header — pick a storefront, one keyword per line.
- **Popularity**: click "Search Ads" in the toolbar and sign in to Apple Search Ads in the window that opens. Popularity then refreshes weekly.
- **Updates** run on launch and hourly while the app is open. Keywords ranked in the top 100 or tagged are checked daily, the rest weekly.

### Import from Astro

With Astro installed, copy one developer's apps, keywords and full ranking history (read-only on Astro's side):

```sh
build/Build/Products/Debug/AsoTracker.app/Contents/MacOS/AsoTracker --import "Your Developer Name"
```

### Headless rank update

```sh
AsoTracker --update-ranks [--limit N]
```

Data lives in `~/Library/Application Support/AsoTracker/aso.sqlite`.

## Architecture

| Layer | Files |
|---|---|
| Views (SwiftUI) | `Views.swift` |
| View models | `LibraryModel` (browse/edit), `UpdateModel` (jobs, Search Ads session) |
| Update flow | `Updater` — fetch, then record through the store |
| Data access | `KeywordStore` (all SQL), `DB` (thin SQLite3 wrapper) |
| Network | `Fetchers.swift` — App Store search, Search Ads popularity, iTunes lookup |

No third-party dependencies.

## Caveats

Rankings come from the App Store's own search endpoint and popularity from the Apple Search Ads web UI's internal API. Neither is a documented public API: they can change or break without notice, and you are responsible for using them in line with Apple's terms. Requests are throttled (one at a time with pauses), and popularity only works for apps owned by the signed-in Search Ads account.

## License

MIT — see [LICENSE](LICENSE).
