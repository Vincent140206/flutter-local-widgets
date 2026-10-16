# Still — Local Widgets

A Flutter starter app for offline photo, Bible verse, and watchlist widgets. The main Flutter screen uses a minimal dark design. Native widgets read only on-device shared storage. No accounts, cloud storage, web APIs, or server are used.

## What works / limitations

- Photo: multiple photos chosen from gallery and copied to application support storage. Android and iOS home-screen widget. Rotation switches photos every 15 seconds. On Android, exact alarms trigger widget refreshes every 15 seconds; iOS uses 15-second interval WidgetKit timeline entries; the Flutter app keeps in-app preview and active widget data synchronized every 15 seconds.
- Verse: user manually edits a verse and its reference. No Bible database is bundled, no automatic verse-of-the-day selection, and no online Bible API.
- Watchlist: add items and mark them watched locally. Widgets display the first few items.
- iOS lock screen: rectangular and inline verse widgets; rectangular watchlist widget. iOS 16+.
- Android lock screen: `widgetCategory=keyguard` advertises eligibility. Actual placement is controlled by the device OS and launcher and is not available on every device.
- iOS photo widget does not appear as a lock-screen accessory (intentionally).
- Shared data is global, not separately configurable per widget instance.
- This is a source starter, not a precompiled/tested app; iOS extension/Xcode configuration and Android manifest insertion must be completed manually.

## Create the Flutter platform scaffolding

This archive intentionally includes authored sources rather than committing generated platform folders. Run these commands inside the extracted `local_widgets_starter` folder:

```bash
flutter create --platforms=android,ios --org com.example --project-name local_widgets .
flutter pub get
```

**Important:** If Flutter reports existing-file conflicts, retain the authored `lib/main.dart` and `pubspec.yaml` from this archive. Flutter-generated Android Gradle files and the iOS Runner project are required.

## Android setup

1. Make sure `android/app/build.gradle.kts` has `applicationId = "com.example.localwidgets"`, and the Kotlin namespace matches `com.example.localwidgets`. If you created the project with `--org com.example --project-name local_widgets`, the initial package may be `com.example.local_widgets` (with an underscore); change it consistently in your Kotlin package, namespace, applicationId, and manifest receiver names, or adjust the scaffold.
2. Keep `LocalWidgetProviders.kt` under `android/app/src/main/kotlin/com/example/localwidgets/`. The three widget providers use classic `RemoteViews` and require no Glance setup.
3. Paste all three `<receiver>` declarations from `android/widget_manifest_receivers.xml` inside the existing manifest's `<application>` element.
4. Paste strings from `android/app/src/main/res/values_strings_extra.txt` into `android/app/src/main/res/values/strings.xml` inside `<resources>`.
5. Set `android:minSdk` to at least the minimum required by your Flutter/plugins (Flutter's generated default usually suffices). Avoid accidentally defining duplicate `<application>` or `<resources>` elements.
6. Run `flutter run` on an Android device. Add a widget through the launcher widget picker. Tap “Save & update widgets” to publish data.

## iOS setup (macOS + Xcode required)

1. Open `ios/Runner.xcworkspace` in Xcode. Set your Runner bundle identifier (e.g. `com.example.localwidgets`).
2. Use File > New > Target > Widget Extension; name the target `LocalWidgetsExtension`. Select iOS 16+ for widget support. If Xcode creates its own sample `@main` Widget, delete that sample to avoid duplicate entry points.
3. Add the supplied `ios/LocalWidgetsExtension/LocalWidgets.swift` to the widget extension target, not Runner. The extension should have only one `@main` entry.
4. In Signing & Capabilities, add App Groups to **both** Runner and LocalWidgetsExtension; enable `group.com.example.localwidgets` on both. Change the constant `appGroupId` in Dart and `groupId` in Swift if using your own registered identifier. `ios/app_group.entitlements` is a template only; Xcode should manage each target's entitlements.
5. Set the extension deployment target to iOS 16 or higher, select valid signing teams and bundle identifiers, and run on device/simulator. Add Photo / Daily Verse / Watchlist from the widget gallery.
6. This sample's SwiftUI styles are intentionally compact on lock screen, where system contrast/tint may override colors.

## Persistence

Flutter stores settings and watchlist in `shared_preferences`, photos in the app's application support directory, and sends widget-accessible copies/values to storage managed by `home_widget`. Uninstalling the app generally deletes its local content. Gallery originals are never modified.

## Potential next iteration

Per-widget configuration (individual photo albums or verses for each installed instance), local curated verse database with copyright-aware translations, and a richer editor can be added without cloud storage.

## References

- https://pub.dev/packages/home_widget
- https://pub.dev/documentation/home_widget/latest/home_widget/HomeWidget-class.html
- https://developer.apple.com/documentation/widgetkit/
- https://android-developers.googleblog.com/2025/03/widgets-on-lock-screen-faq.html
