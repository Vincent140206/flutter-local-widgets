import 'package:shared_preferences/shared_preferences.dart';

class VersePreferences {
  static const _pinnedKey = 'use_pinned_verse';
  static const _verseIdKey = 'pinned_verse_id';

  Future<bool> usePinnedVerse() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_pinnedKey) ?? false;
  }

  Future<String?> pinnedVerseId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_verseIdKey);
  }

  Future<void> save({required bool pinned, required String? verseId}) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_pinnedKey, pinned);
    if (verseId == null) {
      await preferences.remove(_verseIdKey);
    } else {
      await preferences.setString(_verseIdKey, verseId);
    }
  }
}
