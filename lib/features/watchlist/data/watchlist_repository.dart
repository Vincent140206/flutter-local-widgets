import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/watch_item.dart';

class WatchlistRepository {
  static const _key = 'watchlist';

  Future<List<WatchItem>> read() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final text = preferences.getString(_key) ?? '[]';
      return (jsonDecode(text) as List)
          .map((row) =>
              WatchItem.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<WatchItem> items) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }
}
