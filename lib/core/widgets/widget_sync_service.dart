import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/bible/data/bible_repository.dart';
import '../../features/watchlist/domain/watch_item.dart';

const appGroupId = 'group.com.example.localwidgets';

class WidgetSyncService {
  static const _iosPhotoSignaturesKey = 'widget_photo_signatures_v2';

  Future<void> _photoQueue = Future.value();
  Future<void> _verseQueue = Future.value();
  Future<void> _watchlistQueue = Future.value();
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (Platform.isIOS) await HomeWidget.setAppGroupId(appGroupId);
  }

  Future<void> syncPhotos({
    required List<String> photos,
    required bool rotate,
  }) {
    final snapshot = List<String>.of(photos);
    final operation = _photoQueue.then(
      (_) => _syncPhotos(photos: snapshot, rotate: rotate),
    );
    _photoQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> _syncPhotos({
    required List<String> photos,
    required bool rotate,
  }) async {
    await initialize();
    final existing = <File>[];
    for (final path in photos) {
      final file = File(path);
      if (await file.exists()) existing.add(file);
    }

    final paths = Platform.isIOS
        ? await _exportIosPhotosIfNeeded(existing)
        : existing.map((file) => file.path).toList(growable: false);
    final encodedPaths = jsonEncode(paths);
    final currentPaths =
        await HomeWidget.getWidgetData<String>('photo_paths', defaultValue: '');
    if (currentPaths != encodedPaths) {
      await HomeWidget.saveWidgetData<String>('photo_paths', encodedPaths);
    }
    await HomeWidget.saveWidgetData<bool>('rotate_photos', rotate);
    await HomeWidget.updateWidget(
      androidName: 'PhotoWidgetProvider',
      iOSName: 'PhotoWidget',
    );
  }

  Future<List<String>> _exportIosPhotosIfNeeded(List<File> photos) async {
    final signatures = <String>[];
    for (final photo in photos) {
      final stat = await photo.stat();
      signatures.add(
          '${photo.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}');
    }

    final preferences = await SharedPreferences.getInstance();
    final previous =
        preferences.getStringList(_iosPhotoSignaturesKey) ?? const [];
    final existingExport = await HomeWidget.getWidgetData<String>('photo_paths',
        defaultValue: '[]');
    if (_sameList(previous, signatures)) {
      try {
        return (jsonDecode(existingExport ?? '[]') as List).cast<String>();
      } catch (_) {
        // Re-export below if shared widget state was cleared independently.
      }
    }

    final exported = <String>[];
    for (var index = 0; index < photos.length; index++) {
      exported.add(await HomeWidget.saveImage(
        'still_photo_$index',
        FileImage(photos[index]),
      ));
    }
    await preferences.setStringList(_iosPhotoSignaturesKey, signatures);
    return exported;
  }

  Future<void> syncVerse({
    required bool pinned,
    required BibleVerse? verse,
  }) {
    final operation = _verseQueue.then((_) async {
      await initialize();
      await HomeWidget.saveWidgetData<String>(
        'verse_mode',
        pinned ? 'pinned' : 'daily',
      );
      await HomeWidget.saveWidgetData<String>('verse_text', verse?.text ?? '');
      await HomeWidget.saveWidgetData<String>(
        'verse_reference',
        verse?.reference ?? '',
      );
      await HomeWidget.updateWidget(
        androidName: 'VerseWidgetProvider',
        iOSName: 'VerseWidget',
      );
    });
    _verseQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> syncWatchlist(List<WatchItem> items) {
    final snapshot = items.map((item) => item.copy()).toList();
    final operation = _watchlistQueue.then((_) async {
      await initialize();
      await HomeWidget.saveWidgetData<String>(
        'watchlist_json',
        jsonEncode(snapshot.map((item) => item.toJson()).toList()),
      );
      await HomeWidget.updateWidget(
        androidName: 'WatchlistWidgetProvider',
        iOSName: 'WatchlistWidget',
      );
    });
    _watchlistQueue = operation.catchError((_) {});
    return operation;
  }

  bool _sameList(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}
