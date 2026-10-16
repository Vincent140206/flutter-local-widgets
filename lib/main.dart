import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appGroupId = 'group.com.example.localwidgets';
const androidPhotoProvider = 'PhotoWidgetProvider';
const androidVerseProvider = 'VerseWidgetProvider';
const androidWatchProvider = 'WatchlistWidgetProvider';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocalWidgetsApp());
}

class LocalWidgetsApp extends StatelessWidget {
  const LocalWidgetsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Still',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0C0D10),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF9F8AFF),
            brightness: Brightness.dark,
          ),
          cardTheme: CardThemeData(
            color: const Color(0xFF1B1D24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        home: const Dashboard(),
      );
}

class WatchItem {
  WatchItem({required this.title, this.watched = false});
  String title;
  bool watched;
  Map<String, dynamic> toJson() => {'title': title, 'watched': watched};
  factory WatchItem.fromJson(Map<String, dynamic> value) => WatchItem(
        title: value['title'] as String? ?? '',
        watched: value['watched'] as bool? ?? false,
      );
}

class LocalRepository {
  static const photosKey = 'photos';
  static const watchKey = 'watchlist';
  static const verseKey = 'verse_text';
  static const referenceKey = 'verse_reference';
  static const rotationKey = 'rotate_photos';

  Future<SharedPreferences> get preferences => SharedPreferences.getInstance();

  Future<List<String>> readPhotos() async {
    final prefs = await preferences;
    return prefs.getStringList(photosKey) ?? [];
  }

  Future<List<WatchItem>> readWatchlist() async {
    final prefs = await preferences;
    final serialized = prefs.getString(watchKey) ?? '[]';
    try {
      return (jsonDecode(serialized) as List)
          .map((e) => WatchItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePhotos(List<String> photos) async {
    (await preferences).setStringList(photosKey, photos);
  }

  Future<void> saveWatchlist(List<WatchItem> items) async {
    (await preferences).setString(
      watchKey,
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> saveVerse(String verse, String reference) async {
    final prefs = await preferences;
    await prefs.setString(verseKey, verse);
    await prefs.setString(referenceKey, reference);
  }

  Future<void> setRotation(bool enabled) async {
    await (await preferences).setBool(rotationKey, enabled);
  }

  Future<void> syncWidgets() async {
    final prefs = await preferences;
    if (Platform.isIOS) await HomeWidget.setAppGroupId(appGroupId);
    final photos = (await readPhotos()).where((path) => File(path).existsSync()).toList();
    final watchlist = await readWatchlist();
    final rotate = prefs.getBool(rotationKey) ?? true;

    final paths = <String>[];
    for (var i = 0; i < photos.length; i++) {
      final sharedPath = await HomeWidget.saveImage(
        'photo_$i',
        FileImage(File(photos[i])),
      );
      paths.add(sharedPath);
    }
    final currentIndex = rotate && paths.isNotEmpty
        ? (DateTime.now().millisecondsSinceEpoch ~/ 15000) % paths.length
        : 0;
    await HomeWidget.saveWidgetData<String>('photo_paths', jsonEncode(paths));
    await HomeWidget.saveWidgetData<String>(
      'photo_path',
      paths.isEmpty ? '' : paths[currentIndex],
    );
    await HomeWidget.saveWidgetData<bool>('rotate_photos', rotate);
    await HomeWidget.saveWidgetData<String>(
      'verse_text',
      prefs.getString(verseKey) ?? 'Be still, and know that I am God.',
    );
    await HomeWidget.saveWidgetData<String>(
      'verse_reference',
      prefs.getString(referenceKey) ?? 'Psalm 46:10',
    );
    await HomeWidget.saveWidgetData<String>(
      'watchlist_json',
      jsonEncode(watchlist.map((item) => item.toJson()).toList()),
    );

    await Future.wait([
      HomeWidget.updateWidget(
        androidName: androidPhotoProvider,
        iOSName: 'PhotoWidget',
      ),
      HomeWidget.updateWidget(
        androidName: androidVerseProvider,
        iOSName: 'VerseWidget',
      ),
      HomeWidget.updateWidget(
        androidName: androidWatchProvider,
        iOSName: 'WatchlistWidget',
      ),
    ]);
  }

  Future<void> updatePhotoWidget() async {
    final prefs = await preferences;
    final rotate = prefs.getBool(rotationKey) ?? true;
    final rawPaths = await HomeWidget.getWidgetData<String>('photo_paths');
    if (rawPaths == null) return;
    try {
      final paths = (jsonDecode(rawPaths) as List).cast<String>();
      if (paths.isEmpty) return;
      final currentIndex = rotate
          ? (DateTime.now().millisecondsSinceEpoch ~/ 15000) % paths.length
          : 0;
      await HomeWidget.saveWidgetData<String>('photo_path', paths[currentIndex]);
      await HomeWidget.updateWidget(
        androidName: androidPhotoProvider,
        iOSName: 'PhotoWidget',
      );
    } catch (_) {}
  }

  Future<List<String>> importPhotos() async {
    final selected = await ImagePicker().pickMultiImage(imageQuality: 86);
    if (selected.isEmpty) return readPhotos();
    final root = Directory(p.join((await getApplicationSupportDirectory()).path, 'photos'));
    await root.create(recursive: true);
    final paths = await readPhotos();
    for (final file in selected) {
      final name = '${DateTime.now().microsecondsSinceEpoch}_${paths.length}${p.extension(file.path)}';
      final copied = await File(file.path).copy(p.join(root.path, name));
      paths.add(copied.path);
    }
    await savePhotos(paths);
    return paths;
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final repo = LocalRepository();
  final verseController = TextEditingController();
  final referenceController = TextEditingController();
  final watchController = TextEditingController();
  List<String> photos = [];
  List<WatchItem> watchlist = [];
  bool rotatePhotos = true;
  bool syncing = false;
  Timer? photoRotationTimer;
  StreamSubscription<Uri?>? widgetClickSubscription;

  @override
  void initState() {
    super.initState();
    load();
    HomeWidget.initiallyLaunchedFromHomeWidget().catchError((_) => null);
    widgetClickSubscription = HomeWidget.widgetClicked.listen((_) {});
    photoRotationTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (mounted && rotatePhotos && photos.isNotEmpty) {
        await repo.updatePhotoWidget();
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> load() async {
    final prefs = await repo.preferences;
    photos = await repo.readPhotos();
    watchlist = await repo.readWatchlist();
    rotatePhotos = prefs.getBool(LocalRepository.rotationKey) ?? true;
    verseController.text = prefs.getString(LocalRepository.verseKey) ??
        'Be still, and know that I am God.';
    referenceController.text = prefs.getString(LocalRepository.referenceKey) ??
        'Psalm 46:10';
    if (mounted) setState(() {});
  }

  Future<void> persistAndSync() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      await repo.saveVerse(verseController.text.trim(), referenceController.text.trim());
      await repo.saveWatchlist(watchlist);
      await repo.setRotation(rotatePhotos);
      await repo.syncWidgets();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Widgets updated locally.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to update widgets: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => syncing = false);
      }
    }
  }

  @override
  void dispose() {
    photoRotationTimer?.cancel();
    widgetClickSubscription?.cancel();
    verseController.dispose();
    referenceController.dispose();
    watchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Still', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          actions: [
            IconButton(
              tooltip: 'Update widgets',
              onPressed: syncing ? null : persistAndSync,
              icon: const Icon(Icons.sync_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            const Text('Your moments, at a glance.',
                style: TextStyle(fontSize: 16, color: Color(0xFFAAAAB5))),
            const SizedBox(height: 26),
            _sectionTitle('01', 'Photo widget'),
            const SizedBox(height: 12),
            Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (photos.isEmpty)
                  const SizedBox(height: 140, child: Center(child: Text('No photos selected')))
                else
                  SizedBox(
                    height: 145,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: photos.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (_, i) {
                        final activeIndex = rotatePhotos && photos.isNotEmpty
                            ? (DateTime.now().millisecondsSinceEpoch ~/ 15000) % photos.length
                            : 0;
                        final isActive = rotatePhotos && i == activeIndex;
                        return Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isActive ? const Color(0xFF9F8AFF) : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Stack(
                              children: [
                                Image.file(
                                  File(photos[i]),
                                  width: 140,
                                  height: 140,
                                  fit: BoxFit.cover,
                                ),
                                if (isActive)
                                  Positioned(
                                    left: 6,
                                    bottom: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.75),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.play_circle_fill, size: 10, color: Color(0xFF9F8AFF)),
                                          SizedBox(width: 4),
                                          Text('Active', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white)),
                                        ],
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  right: 3,
                                  top: 3,
                                  child: IconButton.filledTonal(
                                    onPressed: () async {
                                      final removed = photos.removeAt(i);
                                      await repo.savePhotos(photos);
                                      final file = File(removed);
                                      if (await file.exists()) await file.delete();
                                      await repo.syncWidgets();
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.close, size: 16),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Rotate photos'),
                  subtitle: const Text('Switches photo every 15 seconds'),
                  value: rotatePhotos,
                  onChanged: (value) async {
                    setState(() => rotatePhotos = value);
                    await repo.setRotation(value);
                    await repo.syncWidgets();
                  },
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    photos = await repo.importPhotos();
                    await repo.syncWidgets();
                    setState(() {});
                  },
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Choose photos'),
                ),
              ]),
            )),
            const SizedBox(height: 24),
            _sectionTitle('02', 'Daily verse'),
            const SizedBox(height: 12),
            Card(child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(children: [
                TextField(
                  controller: verseController,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Verse text', border: InputBorder.none),
                ),
                const Divider(),
                TextField(
                  controller: referenceController,
                  decoration: const InputDecoration(labelText: 'Reference', border: InputBorder.none),
                ),
                const SizedBox(height: 8),
                const Align(alignment: Alignment.centerLeft, child: Text(
                  'Verses are entered manually and stored offline.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9999A4)),
                )),
              ]),
            )),
            const SizedBox(height: 24),
            _sectionTitle('03', 'Watchlist'),
            const SizedBox(height: 12),
            Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                for (var i = 0; i < watchlist.length; i++)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: watchlist[i].watched,
                    title: Text(watchlist[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    secondary: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => watchlist.removeAt(i)),
                    ),
                    onChanged: (value) => setState(() => watchlist[i].watched = value ?? false),
                  ),
                Row(children: [
                  Expanded(child: TextField(
                    controller: watchController,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => addWatchItem(),
                    decoration: const InputDecoration(hintText: 'Add a film or series'),
                  )),
                  IconButton.filledTonal(onPressed: addWatchItem, icon: const Icon(Icons.add)),
                ]),
              ]),
            )),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: syncing ? null : persistAndSync,
              icon: const Icon(Icons.widgets_outlined),
              label: Text(syncing ? 'Updating...' : 'Save & update widgets'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
            const SizedBox(height: 10),
            const Text('Add widgets from your phone’s widget gallery after setup. All content stays on this device.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF9999A4))),
          ],
        ),
      );

  Widget _sectionTitle(String index, String title) => Row(children: [
        Text(index, style: const TextStyle(color: Color(0xFFAD9CFF), fontSize: 12)),
        const SizedBox(width: 12),
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      ]);

  void addWatchItem() {
    final text = watchController.text.trim();
    if (text.isEmpty) return;
    setState(() => watchlist.add(WatchItem(title: text)));
    watchController.clear();
  }
}
