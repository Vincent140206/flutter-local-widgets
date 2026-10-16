import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'bible/bible_repository.dart';

const appGroupId = 'group.com.example.localwidgets';
const violet = Color(0xFFB5A2FF);
const panel = Color(0xFF1B1C24);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StillApp());
}

class WatchItem {
  WatchItem({required this.title, this.watched = false});
  String title;
  bool watched;
  Map<String, dynamic> toJson() => {'title': title, 'watched': watched};
  factory WatchItem.fromJson(Map<String, dynamic> data) => WatchItem(
        title: data['title'] as String? ?? '',
        watched: data['watched'] as bool? ?? false,
      );
}

class LocalWidgetStore {
  static const _exportedPhotoSourcesKey = 'widget_photo_sources';

  Future<SharedPreferences> get prefs => SharedPreferences.getInstance();

  Future<List<String>> photos() async =>
      (await prefs).getStringList('photos') ?? [];
  Future<bool> rotatePhotos() async =>
      (await prefs).getBool('rotate_photos') ?? true;
  Future<bool> usePinnedVerse() async =>
      (await prefs).getBool('use_pinned_verse') ?? false;
  Future<String?> pinnedVerseId() async =>
      (await prefs).getString('pinned_verse_id');

  Future<List<WatchItem>> watchlist() async {
    try {
      final text = (await prefs).getString('watchlist') ?? '[]';
      return (jsonDecode(text) as List)
          .map((row) =>
              WatchItem.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> importPhotos() async {
    final selected = await ImagePicker().pickMultiImage(
      imageQuality: 78,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    final all = await photos();
    if (selected.isEmpty) return all;
    final root = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'photos'));
    await root.create(recursive: true);
    for (final item in selected) {
      final fileName =
          '${DateTime.now().microsecondsSinceEpoch}_${all.length}${p.extension(item.path)}';
      final local = await File(item.path).copy(p.join(root.path, fileName));
      all.add(local.path);
    }
    await (await prefs).setStringList('photos', all);
    return all;
  }

  Future<void> save({
    required List<String> photos,
    required bool rotate,
    required bool pinned,
    required String? verseId,
    required List<WatchItem> items,
  }) async {
    final storage = await prefs;
    await storage.setStringList('photos', photos);
    await storage.setBool('rotate_photos', rotate);
    await storage.setBool('use_pinned_verse', pinned);
    if (verseId != null) await storage.setString('pinned_verse_id', verseId);
    await storage.setString(
        'watchlist', jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  Future<void> sync({
    required List<String> photos,
    required bool rotate,
    required bool pinned,
    required BibleVerse? selectedVerse,
    required List<WatchItem> items,
  }) async {
    if (Platform.isIOS) await HomeWidget.setAppGroupId(appGroupId);
    final existingPhotos = <String>[];
    for (final path in photos) {
      if (await File(path).exists()) existingPhotos.add(path);
    }

    final storage = await prefs;
    final previousSources =
        storage.getStringList(_exportedPhotoSourcesKey) ?? const [];
    final photosChanged = !_samePaths(previousSources, existingPhotos);
    if (photosChanged) {
      final exportedPaths = <String>[];
      for (var index = 0; index < existingPhotos.length; index++) {
        final file = File(existingPhotos[index]);
        exportedPaths.add(await HomeWidget.saveImage(
          'still_photo_$index',
          FileImage(file),
        ));
      }
      await HomeWidget.saveWidgetData<String>(
        'photo_paths',
        jsonEncode(exportedPaths),
      );
      await storage.setStringList(_exportedPhotoSourcesKey, existingPhotos);
    }
    await HomeWidget.saveWidgetData<bool>('rotate_photos', rotate);
    await HomeWidget.saveWidgetData<String>(
        'verse_mode', pinned ? 'pinned' : 'daily');
    await HomeWidget.saveWidgetData<String>(
        'verse_text', selectedVerse?.text ?? '');
    await HomeWidget.saveWidgetData<String>(
        'verse_reference', selectedVerse?.reference ?? '');
    await HomeWidget.saveWidgetData<String>(
      'watchlist_json',
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
    await Future.wait([
      HomeWidget.updateWidget(
          androidName: 'PhotoWidgetProvider', iOSName: 'PhotoWidget'),
      HomeWidget.updateWidget(
          androidName: 'VerseWidgetProvider', iOSName: 'VerseWidget'),
      HomeWidget.updateWidget(
          androidName: 'WatchlistWidgetProvider', iOSName: 'WatchlistWidget'),
    ]);
  }

  bool _samePaths(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

class StillApp extends StatelessWidget {
  const StillApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Still',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0E0E13),
          colorScheme: ColorScheme.fromSeed(
              seedColor: violet, brightness: Brightness.dark),
          cardTheme: CardThemeData(
            color: panel,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF23242E),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none),
          ),
        ),
        home: const StillHome(),
      );
}

class StillHome extends StatefulWidget {
  const StillHome({super.key});
  @override
  State<StillHome> createState() => _StillHomeState();
}

class _StillHomeState extends State<StillHome> {
  final storage = LocalWidgetStore();
  final watchInput = TextEditingController();
  BibleRepository? bible;
  List<String> photos = [];
  List<WatchItem> watchlist = [];
  BibleVerse? pinnedVerse;
  bool rotate = true;
  bool pinned = false;
  bool syncing = false;
  bool syncPending = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await BibleRepository.open();
      final chosenId = await storage.pinnedVerseId();
      bible = result;
      pinnedVerse = chosenId == null ? null : await result.byId(chosenId);
      photos = await storage.photos();
      watchlist = await storage.watchlist();
      rotate = await storage.rotatePhotos();
      pinned = await storage.usePinnedVerse();
      await _persistAndSync(showMessage: false);
    } catch (exception) {
      error = 'Unable to load the local Bible database: $exception';
    }
    if (mounted) setState(() {});
  }

  BibleVerse? get visibleVerse => pinned && pinnedVerse != null
      ? pinnedVerse
      : bible?.verseOfDay(DateTime.now());

  Future<void> _persistAndSync({bool showMessage = false}) async {
    if (bible == null) return;
    syncPending = true;
    if (syncing) return;
    syncing = true;
    if (mounted) setState(() {});
    try {
      do {
        syncPending = false;
        final photoSnapshot = List<String>.of(photos);
        final watchSnapshot = watchlist
            .map((item) => WatchItem(title: item.title, watched: item.watched))
            .toList();
        final pinnedSnapshot = pinned && pinnedVerse != null;
        final verseSnapshot = visibleVerse;
        await storage.save(
          photos: photoSnapshot,
          rotate: rotate,
          pinned: pinnedSnapshot,
          verseId: pinnedVerse?.id,
          items: watchSnapshot,
        );
        await storage.sync(
          photos: photoSnapshot,
          rotate: rotate,
          pinned: pinnedSnapshot,
          selectedVerse: verseSnapshot,
          items: watchSnapshot,
        );
      } while (syncPending);
      if (showMessage && mounted) _show('Widgets updated from local storage.');
    } catch (exception) {
      if (mounted) _show('Widget sync failed: $exception');
    } finally {
      syncing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _chooseVerse() async {
    final result = bible;
    if (result == null) return;
    final selected = await Navigator.of(context).push<BibleVerse>(
      MaterialPageRoute(builder: (_) => BibleLibraryPage(repository: result)),
    );
    if (selected != null) {
      setState(() {
        pinnedVerse = selected;
        pinned = true;
      });
      await _persistAndSync();
    }
  }

  void _show(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

  @override
  void dispose() {
    watchInput.dispose();
    bible?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Still',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 27)),
          backgroundColor: Colors.transparent,
        ),
        body: bible == null
            ? Center(
                child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Text(error ?? 'Loading your offline library...')))
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                children: [
                  const Text('Your moments, at a glance.',
                      style: TextStyle(color: Color(0xFFAAAAB8))),
                  const SizedBox(height: 24),
                  _heading('01', 'Daily scripture'),
                  const SizedBox(height: 12),
                  Card(
                      child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('TODAY\'S VERSE',
                                    style: TextStyle(
                                        letterSpacing: 2,
                                        fontSize: 10,
                                        color: violet)),
                                IconButton(
                                    onPressed: _chooseVerse,
                                    tooltip: 'Browse the Bible',
                                    icon: const Icon(Icons.menu_book_outlined,
                                        color: violet)),
                              ]),
                          const SizedBox(height: 10),
                          Text('“${visibleVerse?.text ?? 'No verse selected'}”',
                              style:
                                  const TextStyle(fontSize: 19, height: 1.4)),
                          const SizedBox(height: 16),
                          Text(
                              '${visibleVerse?.reference ?? ''} · ${bible!.isDemo ? 'DEMO' : 'WEB'}',
                              style:
                                  const TextStyle(color: violet, fontSize: 12)),
                          const SizedBox(height: 8),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Pin a selected verse'),
                            subtitle: const Text(
                                'Off: daily rotation. On: selected verse.'),
                            value: pinned,
                            onChanged: pinnedVerse == null
                                ? null
                                : (value) async {
                                    setState(() => pinned = value);
                                    await _persistAndSync(showMessage: false);
                                  },
                          ),
                          OutlinedButton.icon(
                            onPressed: _chooseVerse,
                            icon: const Icon(Icons.search),
                            label: const Text('Search all Bible verses'),
                          ),
                          if (bible!.isDemo)
                            const Padding(
                              padding: EdgeInsets.only(top: 10),
                              child: Text(
                                  'Demo database: replace it with the full WEB dataset before release.',
                                  style: TextStyle(
                                      fontSize: 12, color: Color(0xFFAAAAAA))),
                            ),
                        ]),
                  )),
                  const SizedBox(height: 24),
                  _heading('02', 'Photo widget'),
                  const SizedBox(height: 12),
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (photos.isEmpty)
                                const SizedBox(
                                    height: 120,
                                    child: Center(
                                        child: Text('No photos selected')))
                              else
                                SizedBox(
                                    height: 136,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: photos.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(width: 8),
                                      itemBuilder: (_, i) => Stack(children: [
                                        ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            child: Image.file(File(photos[i]),
                                                height: 130,
                                                width: 130,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const Icon(Icons
                                                        .broken_image_outlined))),
                                        Positioned(
                                            top: 0,
                                            right: 0,
                                            child: IconButton.filledTonal(
                                              icon: const Icon(
                                                  Icons.close_rounded,
                                                  size: 16),
                                              onPressed: () async {
                                                final path = photos.removeAt(i);
                                                setState(() {});
                                                await _persistAndSync(
                                                    showMessage: false);
                                                final file = File(path);
                                                if (await file.exists()) {
                                                  await file.delete();
                                                }
                                              },
                                            )),
                                      ]),
                                    )),
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Daily photo rotation'),
                                value: rotate,
                                onChanged: (value) async {
                                  setState(() => rotate = value);
                                  await _persistAndSync(showMessage: false);
                                },
                              ),
                              OutlinedButton.icon(
                                icon: const Icon(
                                    Icons.add_photo_alternate_outlined),
                                label: const Text('Select photos'),
                                onPressed: () async {
                                  photos = await storage.importPhotos();
                                  setState(() {});
                                  await _persistAndSync(showMessage: false);
                                },
                              ),
                            ],
                          ))),
                  const SizedBox(height: 24),
                  _heading('03', 'Watchlist'),
                  const SizedBox(height: 12),
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            children: [
                              for (var i = 0; i < watchlist.length; i++)
                                CheckboxListTile(
                                  title: Text(watchlist[i].title),
                                  value: watchlist[i].watched,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  secondary: IconButton(
                                      onPressed: () async {
                                        setState(() => watchlist.removeAt(i));
                                        await _persistAndSync(
                                            showMessage: false);
                                      },
                                      icon: const Icon(Icons.close_rounded)),
                                  onChanged: (checked) async {
                                    setState(() => watchlist[i].watched =
                                        checked ?? false);
                                    await _persistAndSync(showMessage: false);
                                  },
                                ),
                              Row(children: [
                                Expanded(
                                    child: TextField(
                                  controller: watchInput,
                                  onSubmitted: (_) => _addWatchItem(),
                                  decoration: const InputDecoration(
                                      hintText: 'Add a film or series'),
                                )),
                                const SizedBox(width: 6),
                                IconButton.filledTonal(
                                    onPressed: _addWatchItem,
                                    icon: const Icon(Icons.add)),
                              ]),
                            ],
                          ))),
                  if (syncing) ...[
                    const SizedBox(height: 22),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                      'Offline by design. No account, analytics, or cloud sync.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 12)),
                ],
              ),
      );

  Widget _heading(String index, String label) => Row(children: [
        Text(index, style: const TextStyle(color: violet, fontSize: 12)),
        const SizedBox(width: 10),
        Text(label,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      ]);

  void _addWatchItem() async {
    final title = watchInput.text.trim();
    if (title.isEmpty) return;
    setState(() => watchlist.add(WatchItem(title: title)));
    watchInput.clear();
    await _persistAndSync(showMessage: false);
  }
}

class BibleLibraryPage extends StatefulWidget {
  final BibleRepository repository;
  const BibleLibraryPage({required this.repository, super.key});
  @override
  State<BibleLibraryPage> createState() => _BibleLibraryPageState();
}

class _BibleLibraryPageState extends State<BibleLibraryPage> {
  final input = TextEditingController();
  List<BibleVerse> results = [];
  String topic = '';
  bool favoritesOnly = false;
  bool loading = true;
  int requestId = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final request = ++requestId;
    setState(() => loading = true);
    try {
      final verses = await widget.repository.search(
          query: input.text, topic: topic, favoritesOnly: favoritesOnly);
      if (mounted && request == requestId) {
        setState(() {
          results = verses;
          loading = false;
        });
      }
    } catch (exception) {
      if (mounted && request == requestId) {
        setState(() {
          loading = false;
          results = [];
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$exception')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Offline Bible Library'), actions: [
          IconButton(
            tooltip: 'Read by book and chapter',
            icon: const Icon(Icons.auto_stories_outlined),
            onPressed: () async {
              final selected = await Navigator.of(context).push<BibleVerse>(
                MaterialPageRoute(
                    builder: (_) =>
                        BibleReaderPage(repository: widget.repository)),
              );
              if (selected != null && context.mounted) {
                Navigator.pop(context, selected);
              }
            },
          ),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: TextField(
              controller: input,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search a phrase or John 3:16',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward), onPressed: _search),
              ),
            ),
          ),
          SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  FilterChip(
                      label: const Text('All verses'),
                      selected: !favoritesOnly && topic.isEmpty,
                      onSelected: (_) {
                        topic = '';
                        favoritesOnly = false;
                        _search();
                      }),
                  const SizedBox(width: 8),
                  FilterChip(
                      label: const Text('Favorites'),
                      selected: favoritesOnly,
                      onSelected: (_) {
                        favoritesOnly = !favoritesOnly;
                        topic = '';
                        _search();
                      }),
                  const SizedBox(width: 8),
                  for (final name in [
                    'peace',
                    'hope',
                    'faith',
                    'love',
                    'strength',
                    'wisdom',
                    'gratitude',
                    'purpose'
                  ]) ...[
                    FilterChip(
                        label: Text(name),
                        selected: topic == name,
                        onSelected: (_) {
                          topic = topic == name ? '' : name;
                          favoritesOnly = false;
                          _search();
                        }),
                    const SizedBox(width: 8),
                  ],
                ],
              )),
          Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : results.isEmpty
                      ? const Center(child: Text('No matching verses found.'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 25),
                          itemCount: results.length,
                          itemBuilder: (_, index) {
                            final verse = results[index];
                            return Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(verse.reference,
                                            style: const TextStyle(
                                                color: violet, fontSize: 13)),
                                        const SizedBox(height: 8),
                                        Text(verse.text,
                                            style: const TextStyle(
                                                fontSize: 15, height: 1.45)),
                                        Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              IconButton(
                                                tooltip: 'Toggle favorite',
                                                icon: Icon(verse.isFavorite
                                                    ? Icons.bookmark
                                                    : Icons.bookmark_outline),
                                                onPressed: () async {
                                                  await widget.repository
                                                      .toggleFavorite(verse);
                                                  await _search();
                                                },
                                              ),
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          context, verse),
                                                  child: const Text(
                                                      'Pin to widget')),
                                            ]),
                                      ],
                                    )));
                          },
                        )),
        ]),
      );
}

class BibleReaderPage extends StatefulWidget {
  final BibleRepository repository;
  const BibleReaderPage({required this.repository, super.key});
  @override
  State<BibleReaderPage> createState() => _BibleReaderPageState();
}

class _BibleReaderPageState extends State<BibleReaderPage> {
  List<String> books = [];
  List<BibleVerse> verses = [];
  String? selectedBook;
  int chapter = 1;
  int chapters = 1;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    books = await widget.repository.bookNames();
    if (books.isNotEmpty) await _selectBook(books.first);
  }

  Future<void> _selectBook(String book) async {
    selectedBook = book;
    chapter = 1;
    chapters = await widget.repository.chapterCount(book);
    await _loadChapter();
  }

  Future<void> _loadChapter() async {
    if (selectedBook == null) return;
    final result =
        await widget.repository.chapterVerses(selectedBook!, chapter);
    if (mounted) setState(() => verses = result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Read the Bible')),
        body: Column(children: [
          if (books.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: Row(children: [
                Expanded(
                    child: DropdownButton<String>(
                  isExpanded: true,
                  value: selectedBook,
                  items: books
                      .map((name) =>
                          DropdownMenuItem(value: name, child: Text(name)))
                      .toList(),
                  onChanged: (name) {
                    if (name != null) _selectBook(name);
                  },
                )),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: chapter,
                  items: List.generate(
                      chapters,
                      (index) => DropdownMenuItem(
                          value: index + 1,
                          child: Text('Chapter ${index + 1}'))),
                  onChanged: (value) {
                    if (value != null) {
                      chapter = value;
                      _loadChapter();
                    }
                  },
                ),
              ]),
            ),
          Expanded(
              child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: verses.length,
            itemBuilder: (_, index) {
              final verse = verses[index];
              return ListTile(
                title: Text(verse.text),
                subtitle: Text(verse.reference,
                    style: const TextStyle(color: violet)),
                trailing: PopupMenuButton<String>(
                  onSelected: (choice) async {
                    if (choice == 'pin') {
                      if (context.mounted) Navigator.pop(context, verse);
                    } else {
                      await widget.repository.toggleFavorite(verse);
                      await _loadChapter();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'pin', child: Text('Pin to widget')),
                    PopupMenuItem(
                        value: 'favorite',
                        child: Text(verse.isFavorite
                            ? 'Remove favorite'
                            : 'Add favorite')),
                  ],
                ),
              );
            },
          )),
        ]),
      );
}
