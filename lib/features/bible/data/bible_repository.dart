/// Offline Bible database access and verse models.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class BibleVerse {
  final String id;
  final String reference;
  final String text;
  final String topic;
  final bool isFavorite;

  const BibleVerse({
    required this.id,
    required this.reference,
    required this.text,
    this.topic = '',
    this.isFavorite = false,
  });

  factory BibleVerse.fromMap(Map<String, Object?> row) => BibleVerse(
        id: row['id'] as String,
        reference: row['reference'] as String,
        text: row['text'] as String,
        topic: (row['topic'] ?? '') as String,
        isFavorite: (row['is_favorite'] as int? ?? 0) != 0,
      );
}

class BibleRepository {
  final Database _db;
  final List<BibleVerse> curated;
  final bool isDemo;

  BibleRepository._(this._db, this.curated, this.isDemo);

  static Future<BibleRepository> open() async {
    final dbFolder = await getApplicationSupportDirectory();
    final path = p.join(dbFolder.path, 'still_bible_v1.db');
    // App version bumps do not delete the user's favorites or watchlist.
    final manifest = jsonDecode(
            await rootBundle.loadString('assets/bible/dataset_manifest.json'))
        as Map<String, dynamic>;
    final bundledHash = manifest['hash'] as String;
    Database? existing;
    var needsInstall = !await File(path).exists();
    final preservedFavorites = <String>[];
    if (!needsInstall) {
      existing = await openDatabase(path);
      try {
        final metadata = await existing
            .query('settings', where: 'key=?', whereArgs: ['dataset_hash']);
        needsInstall =
            metadata.isEmpty || metadata.first['value'] != bundledHash;
        if (needsInstall) {
          final rows = await existing.query('favorites', columns: ['verse_id']);
          preservedFavorites
              .addAll(rows.map((row) => row['verse_id'] as String));
        }
      } catch (_) {
        needsInstall = true;
      }
      await existing.close();
    }
    if (needsInstall) {
      final asset = await rootBundle.load('assets/bible/bible.db');
      final bytes =
          asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      await File(path).writeAsBytes(bytes, flush: true);
    }
    final db = await openDatabase(path, readOnly: false);
    if (needsInstall && preservedFavorites.isNotEmpty) {
      final batch = db.batch();
      for (final id in preservedFavorites) {
        batch.rawInsert('''INSERT OR IGNORE INTO favorites(verse_id, created_at)
             SELECT id, ? FROM verses WHERE id = ?''',
            [DateTime.now().toUtc().toIso8601String(), id]);
      }
      await batch.commit(noResult: true);
    }
    final isDemo = manifest['edition'] != 'WEBP';
    final curatedJSON =
        await rootBundle.loadString('assets/bible/curated_widget.json');
    final curated = (jsonDecode(curatedJSON) as List)
        .map((row) => BibleVerse.fromMap(Map<String, Object?>.from(row as Map)))
        .toList();
    return BibleRepository._(db, curated, isDemo);
  }

  BibleVerse? verseOfDay(DateTime date) {
    if (curated.isEmpty) return null;
    final days = DateTime.utc(date.year, date.month, date.day)
        .difference(DateTime.utc(2020, 1, 1))
        .inDays;
    return curated[days % curated.length];
  }

  Future<List<BibleVerse>> search(
      {String query = '',
      String topic = '',
      bool favoritesOnly = false}) async {
    final where = <String>[];
    final arguments = <Object?>[];
    if (query.trim().isNotEmpty) {
      final input = query.trim();
      final reference = RegExp(r'^(.+?)\s+(\d+):(\d+)$').firstMatch(input);
      if (reference != null) {
        where.add("LOWER(b.name) = LOWER(?) AND v.chapter=? AND v.verse=?");
        arguments.addAll([
          reference.group(1)!,
          int.parse(reference.group(2)!),
          int.parse(reference.group(3)!)
        ]);
      } else {
        where.add("(v.text LIKE ? ESCAPE '\\' OR b.name LIKE ? ESCAPE '\\')");
        final escaped = input
            .replaceAll('\\', '\\\\')
            .replaceAll('%', '\\%')
            .replaceAll('_', '\\_');
        arguments.addAll(['%$escaped%', '%$escaped%']);
      }
    }
    if (topic.isNotEmpty) {
      where.add('c.topic = ?');
      arguments.add(topic);
    }
    if (favoritesOnly) where.add('f.verse_id IS NOT NULL');
    final sql = '''
      SELECT v.id, b.name || ' ' || v.chapter || ':' || v.verse AS reference,
             v.text, COALESCE(c.topic, '') AS topic,
             CASE WHEN f.verse_id IS NULL THEN 0 ELSE 1 END AS is_favorite
      FROM verses v
      JOIN books b ON b.id = v.book_id
      LEFT JOIN curated_verses c ON c.verse_id = v.id
      LEFT JOIN favorites f ON f.verse_id = v.id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY v.book_id, v.chapter, v.verse LIMIT 100
    ''';
    final rows = await _db.rawQuery(sql, arguments);
    return rows.map(BibleVerse.fromMap).toList();
  }

  Future<List<String>> bookNames() async {
    final rows =
        await _db.query('books', columns: ['name'], orderBy: 'position');
    return rows.map((row) => row['name'] as String).toList();
  }

  Future<int> chapterCount(String bookName) async {
    final rows =
        await _db.rawQuery('''SELECT MAX(v.chapter) AS chapters FROM verses v
      JOIN books b ON b.id = v.book_id WHERE b.name = ?''', [bookName]);
    return rows.first['chapters'] as int? ?? 1;
  }

  Future<List<BibleVerse>> chapterVerses(String bookName, int chapter) async {
    final rows = await _db.rawQuery(
        '''SELECT v.id, b.name || ' ' || v.chapter || ':' || v.verse AS reference,
      v.text, COALESCE(c.topic, '') AS topic,
      CASE WHEN f.verse_id IS NULL THEN 0 ELSE 1 END AS is_favorite
      FROM verses v JOIN books b ON b.id = v.book_id
      LEFT JOIN curated_verses c ON c.verse_id = v.id
      LEFT JOIN favorites f ON f.verse_id = v.id
      WHERE b.name = ? AND v.chapter = ? ORDER BY v.verse''',
        [bookName, chapter]);
    return rows.map(BibleVerse.fromMap).toList();
  }

  Future<BibleVerse?> byId(String id) async {
    final rows = await _db.rawQuery('''
      SELECT v.id, b.name || ' ' || v.chapter || ':' || v.verse AS reference,
             v.text, COALESCE(c.topic, '') AS topic,
             CASE WHEN f.verse_id IS NULL THEN 0 ELSE 1 END AS is_favorite
      FROM verses v JOIN books b ON b.id = v.book_id
      LEFT JOIN curated_verses c ON c.verse_id = v.id
      LEFT JOIN favorites f ON f.verse_id = v.id
      WHERE v.id = ? LIMIT 1
    ''', [id]);
    return rows.isEmpty ? null : BibleVerse.fromMap(rows.first);
  }

  Future<void> toggleFavorite(BibleVerse verse) async {
    if (verse.isFavorite) {
      await _db.delete('favorites', where: 'verse_id=?', whereArgs: [verse.id]);
    } else {
      await _db.insert(
          'favorites',
          {
            'verse_id': verse.id,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<int> countVerses() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM verses')) ??
      0;

  Future<void> close() => _db.close();
}
