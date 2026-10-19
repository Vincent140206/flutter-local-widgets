# Still — Offline Bible, Photo, and Watchlist Widgets

Still is a Flutter app with fully local Android/iOS widgets. It includes a
searchable World English Bible Protestant Edition (WEBP), a rotating photo
widget, favorites and pinned verses, and a watchlist. The installed app makes
no network requests and requires no account or cloud service.

## Included data

The repository already contains the complete generated WEBP dataset:

- 66 books and 31,098 verses in `assets/bible/bible.db`;
- 125 curated verses across peace, hope, faith, love, strength, wisdom,
  gratitude, and purpose;
- matching curated widget data for Flutter, Android, and iOS.

The original source is the public-domain WEBP VPL/XML archive published by
eBible.org. To rebuild the generated assets later, run:

```powershell
python tools/build_bible_db.py
python tools/validate_assets.py
```

If automatic download is unavailable, pass a local official archive:

```powershell
python tools/build_bible_db.py --source C:\path\to\engwebp_vpl.zip
```

The builder verifies at least 30,000 verses across exactly 66 books, writes a
dataset hash, creates the SQLite database, and copies the curated pool to both
native widget targets.

## Features

- Browse the Bible by book/chapter or search by phrase/reference such as
  `John 3:16`.
- Favorite verses, use a deterministic daily verse, or pin a chosen verse.
- Import original-resolution photos on Android without recompression. App
  previews use a cached display-size decode, while Android widgets calculate a
  density-aware target, center-crop during native region decoding, and enforce
  an 8 MB pixel budget so images stay sharp without loading camera-size bitmaps.
- Rotate photos every 15 seconds while retaining the existing widget behavior.
- Add, complete, and remove local watchlist items.
- Automatically persist and refresh only the widget whose feature changed.
  Photo, verse, and watchlist updates have independent queues, so unrelated
  widgets and images are not reprocessed; there is no manual update step.
- Preserve favorites when the bundled Bible dataset version changes.

## Local storage

- SQLite (`sqflite`): books, verses, curated verses, favorites, dataset
  metadata, and the reserved watchlist table.
- Shared preferences: photo list, active verse mode, and current watchlist.
- Application support storage: high-quality, bounded photo copies.
- `home_widget`: widget-visible values and image copies.

Uninstalling the app generally removes this local data. Gallery originals are
never modified.

## Source structure

The Flutter source uses feature-first boundaries:

```text
lib/
  app/                         app shell
  core/theme/                  shared visual theme
  core/widgets/                native widget synchronization
  features/bible/              database, preferences, reader/search UI
  features/photos/             photo import and local persistence
  features/watchlist/          watchlist model and persistence
  features/home/               dashboard composition
```

Android reads photo files directly from app-local storage, avoiding a second
Flutter decode/export pass. iOS still exports into its required App Group, but
uses file signatures to skip unchanged images and downsamples in WidgetKit.

## Build and verify

Requirements: Flutter SDK, Android SDK, and Python 3.10+.

```powershell
flutter pub get
flutter analyze
flutter test
python -m unittest discover -s tests -v
python tools/validate_assets.py
flutter build apk --debug
```

The debug APK is produced at
`build/app/outputs/flutter-apk/app-debug.apk`.

## Android

The project uses package/namespace `com.example.localwidgets`. The manifest
already registers all three widget providers and boot/time-change handling.
The Daily Verse widget refreshes its bundled verse after the local date changes.
Photo rotation keeps its existing 15-second alarm behavior. Actual lock-screen
widget availability still depends on Android version, device vendor, and
launcher support.

## iOS

`ios/LocalWidgetsExtension/LocalWidgets.swift` contains the Photo, Daily Verse,
and Watchlist WidgetKit implementations. In Xcode:

1. Add a Widget Extension target named `LocalWidgetsExtension` if the project
   does not already contain one.
2. Add `LocalWidgets.swift` and `curated_widget.json` to that extension target.
3. Enable `group.com.example.localwidgets` for both Runner and the extension.
4. Use iOS 16 or newer for lock-screen accessory widget families.

WidgetKit controls the exact background refresh timing. Photo widgets are home
screen only; verse and watchlist include supported lock-screen families.

## Dataset attribution

The World English Bible text is public domain. “World English Bible” is a
trademark of eBible.org; do not label modified verse wording as WEB.
