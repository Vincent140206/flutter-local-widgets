import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/still_theme.dart';
import '../../../core/widgets/widget_sync_service.dart';
import '../../bible/data/bible_repository.dart';
import '../../bible/data/verse_preferences.dart';
import '../../bible/presentation/bible_library_page.dart';
import '../../photos/data/photo_repository.dart';
import '../../spotify/services/spotify_widget_service.dart';
import '../../watchlist/data/watchlist_repository.dart';
import '../../watchlist/domain/watch_item.dart';
import '../../whatsapp/services/whatsapp_widget_service.dart';

class StillHomePage extends StatefulWidget {
  const StillHomePage({super.key});

  @override
  State<StillHomePage> createState() => _StillHomePageState();
}

class _StillHomePageState extends State<StillHomePage>
    with WidgetsBindingObserver {
  final photoRepository = PhotoRepository();
  final versePreferences = VersePreferences();
  final watchlistRepository = WatchlistRepository();
  final widgetSync = WidgetSyncService();
  final watchInput = TextEditingController();
  final spotifyWidget = SpotifyWidgetService();
  final whatsappWidget = WhatsAppWidgetService();

  BibleRepository? bible;
  List<String> photos = [];
  List<WatchItem> watchlist = [];
  BibleVerse? pinnedVerse;
  bool rotate = true;
  bool pinned = false;
  bool importingPhotos = false;
  bool notificationAccess = false;
  bool checkingNotificationAccess = true;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _refreshNotificationAccess();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshNotificationAccess();
  }

  Future<void> _refreshNotificationAccess() async {
    final access = await spotifyWidget.hasNotificationAccess();
    if (access) await spotifyWidget.refreshNotificationListener();
    if (!mounted) return;
    setState(() {
      notificationAccess = access;
      checkingNotificationAccess = false;
    });
  }

  Future<void> _load() async {
    try {
      final result = await BibleRepository.open();
      final chosenId = await versePreferences.pinnedVerseId();
      bible = result;
      pinnedVerse = chosenId == null ? null : await result.byId(chosenId);
      photos = await photoRepository.readPhotos();
      watchlist = await watchlistRepository.read();
      rotate = await photoRepository.readRotation();
      pinned = await versePreferences.usePinnedVerse();
      if (mounted) setState(() {});
      unawaited(_syncInitialState());
    } catch (exception) {
      error = 'Unable to load the local Bible database: $exception';
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncInitialState() async {
    try {
      await Future.wait([
        widgetSync.syncPhotos(photos: photos, rotate: rotate),
        widgetSync.syncVerse(
          pinned: pinned && pinnedVerse != null,
          verse: visibleVerse,
        ),
        widgetSync.syncWatchlist(watchlist),
      ]);
    } catch (exception) {
      if (mounted) _show('Widget sync failed: $exception');
    }
  }

  BibleVerse? get visibleVerse => pinned && pinnedVerse != null
      ? pinnedVerse
      : bible?.verseOfDay(DateTime.now());

  Future<void> _chooseVerse() async {
    final repository = bible;
    if (repository == null) return;
    final selected = await Navigator.of(context).push<BibleVerse>(
      MaterialPageRoute(
        builder: (_) => BibleLibraryPage(repository: repository),
      ),
    );
    if (selected == null) return;
    setState(() {
      pinnedVerse = selected;
      pinned = true;
    });
    await _saveAndSyncVerse();
  }

  Future<void> _saveAndSyncVerse() async {
    try {
      final usePinned = pinned && pinnedVerse != null;
      await versePreferences.save(
        pinned: usePinned,
        verseId: pinnedVerse?.id,
      );
      await widgetSync.syncVerse(pinned: usePinned, verse: visibleVerse);
    } catch (exception) {
      if (mounted) _show('Unable to update the verse widget: $exception');
    }
  }

  Future<void> _importPhotos() async {
    if (importingPhotos) return;
    setState(() => importingPhotos = true);
    try {
      final updated = await photoRepository.importPhotos();
      if (!mounted) return;
      setState(() => photos = updated);
      await widgetSync.syncPhotos(photos: updated, rotate: rotate);
    } catch (exception) {
      if (mounted) _show('Unable to add photos: $exception');
    } finally {
      if (mounted) setState(() => importingPhotos = false);
    }
  }

  Future<void> _removePhoto(int index) async {
    final removed = photos[index];
    setState(() => photos.removeAt(index));
    try {
      await photoRepository.savePhotos(photos);
      await photoRepository.deletePhoto(removed);
      await widgetSync.syncPhotos(photos: photos, rotate: rotate);
    } catch (exception) {
      if (mounted) _show('Unable to remove the photo: $exception');
    }
  }

  Future<void> _setRotation(bool value) async {
    setState(() => rotate = value);
    try {
      await photoRepository.saveRotation(value);
      await widgetSync.syncPhotos(photos: photos, rotate: value);
    } catch (exception) {
      if (mounted) _show('Unable to update photo rotation: $exception');
    }
  }

  Future<void> _saveAndSyncWatchlist() async {
    try {
      await watchlistRepository.save(watchlist);
      await widgetSync.syncWatchlist(watchlist);
    } catch (exception) {
      if (mounted) _show('Unable to update the watchlist widget: $exception');
    }
  }

  void _show(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    watchInput.dispose();
    bible?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text(
            'Still',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 27),
          ),
          backgroundColor: Colors.transparent,
        ),
        body: bible == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Text(error ?? 'Loading your offline library...'),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                children: [
                  const Text(
                    'Your moments, at a glance.',
                    style: TextStyle(color: Color(0xFFAAAAB8)),
                  ),
                  const SizedBox(height: 24),
                  _heading('01', 'Daily scripture'),
                  const SizedBox(height: 12),
                  _verseCard(),
                  const SizedBox(height: 24),
                  _heading('02', 'Photo widget'),
                  const SizedBox(height: 12),
                  _photoCard(),
                  const SizedBox(height: 24),
                  _heading('03', 'Watchlist'),
                  const SizedBox(height: 12),
                  _watchlistCard(),
                  if (Platform.isAndroid) ...[
                    const SizedBox(height: 24),
                    _heading('04', 'Spotify now playing'),
                    const SizedBox(height: 12),
                    _spotifyCard(),
                    const SizedBox(height: 24),
                    _heading('05', 'WhatsApp notifications'),
                    const SizedBox(height: 12),
                    _whatsappCard(),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Offline by design. No account, analytics, or cloud sync.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 12),
                  ),
                ],
              ),
      );

  Widget _spotifyCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: const Color(0xFF242530),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.music_note_rounded, color: violet),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'NOW PLAYING',
                          style: TextStyle(
                            letterSpacing: 1.8,
                            fontSize: 10,
                            color: violet,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          checkingNotificationAccess
                              ? 'Checking access…'
                              : notificationAccess
                                  ? 'Ready for Spotify'
                                  : 'Notification access required',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    notificationAccess
                        ? Icons.check_circle_rounded
                        : Icons.info_outline_rounded,
                    color:
                        notificationAccess ? const Color(0xFF72D69B) : violet,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                notificationAccess
                    ? 'Still can now read Spotify’s local media session. Play a song, then add the widget to your home screen.'
                    : 'Allow Still under Notification access so it can read Spotify’s title, artist, cover, and playback state. Other notifications are ignored.',
                style: const TextStyle(
                  color: Color(0xFFB8B8C3),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: checkingNotificationAccess
                        ? null
                        : () async {
                            await spotifyWidget.openNotificationAccess();
                          },
                    icon: Icon(
                      notificationAccess
                          ? Icons.settings_outlined
                          : Icons.lock_open,
                    ),
                    label: Text(
                      notificationAccess ? 'Manage access' : 'Allow access',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final requested = await spotifyWidget.requestPinWidget();
                      if (!requested && mounted) {
                        _show(
                          'Open your launcher’s widget picker and choose Still · Now Playing.',
                        );
                      }
                    },
                    icon: const Icon(Icons.add_to_home_screen_outlined),
                    label: const Text('Add widget'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _whatsappCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: const Color(0xFF24312A),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.chat_bubble_rounded,
                      color: Color(0xFF72D69B),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'WHATSAPP NOTIFICATIONS',
                          style: TextStyle(
                            letterSpacing: 1.5,
                            fontSize: 10,
                            color: Color(0xFF72D69B),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          checkingNotificationAccess
                              ? 'Checking access…'
                              : notificationAccess
                                  ? 'Ready for notifications'
                                  : 'Notification access required',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    notificationAccess
                        ? Icons.check_circle_rounded
                        : Icons.info_outline_rounded,
                    color:
                        notificationAccess ? const Color(0xFF72D69B) : violet,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                notificationAccess
                    ? 'Still keeps WhatsApp notifications on your home screen after they are dismissed, then removes them when WhatsApp reports the chat as opened or read.'
                    : 'Allow notification access to show sender names and message previews. Still ignores other apps and stores the data only on this device.',
                style: const TextStyle(
                  color: Color(0xFFB8B8C3),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Read detection is best-effort. Muted chats, hidden previews, and manually marked unread chats may not appear.',
                style: TextStyle(
                  color: Color(0xFF858691),
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: checkingNotificationAccess
                        ? null
                        : () async {
                            await whatsappWidget.openNotificationAccess();
                          },
                    icon: Icon(
                      notificationAccess
                          ? Icons.settings_outlined
                          : Icons.lock_open,
                    ),
                    label: Text(
                      notificationAccess ? 'Manage access' : 'Allow access',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final requested = await whatsappWidget.requestPinWidget();
                      if (!requested && mounted) {
                        _show(
                          'Open your launcher’s widget picker and choose Still · WhatsApp Notifications.',
                        );
                      }
                    },
                    icon: const Icon(Icons.add_to_home_screen_outlined),
                    label: const Text('Add widget'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _verseCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'TODAY\'S VERSE',
                    style: TextStyle(
                      letterSpacing: 2,
                      fontSize: 10,
                      color: violet,
                    ),
                  ),
                  IconButton(
                    onPressed: _chooseVerse,
                    tooltip: 'Browse the Bible',
                    icon: const Icon(Icons.menu_book_outlined, color: violet),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '\u201c${visibleVerse?.text ?? 'No verse selected'}\u201d',
                style: const TextStyle(fontSize: 19, height: 1.4),
              ),
              const SizedBox(height: 16),
              Text(
                '${visibleVerse?.reference ?? ''} \u00b7 ${bible!.isDemo ? 'DEMO' : 'WEB'}',
                style: const TextStyle(color: violet, fontSize: 12),
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pin a selected verse'),
                subtitle: const Text(
                  'Off: daily rotation. On: selected verse.',
                ),
                value: pinned,
                onChanged: pinnedVerse == null
                    ? null
                    : (value) async {
                        setState(() => pinned = value);
                        await _saveAndSyncVerse();
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
                    style: TextStyle(fontSize: 12, color: Color(0xFFAAAAAA)),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _photoCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photos.isEmpty)
                const SizedBox(
                  height: 120,
                  child: Center(child: Text('No photos selected')),
                )
              else
                SizedBox(
                  height: 136,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, index) => Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(
                            File(photos[index]),
                            height: 130,
                            width: 130,
                            cacheWidth: 780,
                            cacheHeight: 780,
                            filterQuality: FilterQuality.high,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox(
                              height: 130,
                              width: 130,
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IconButton.filledTonal(
                            icon: const Icon(Icons.close_rounded, size: 16),
                            onPressed: () => _removePhoto(index),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Photo rotation'),
                subtitle: const Text('Changes every 15 seconds when enabled.'),
                value: rotate,
                onChanged: _setRotation,
              ),
              OutlinedButton.icon(
                icon: importingPhotos
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  importingPhotos ? 'Processing photos...' : 'Select photos',
                ),
                onPressed: importingPhotos ? null : _importPhotos,
              ),
            ],
          ),
        ),
      );

  Widget _watchlistCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              for (var index = 0; index < watchlist.length; index++)
                CheckboxListTile(
                  title: Text(watchlist[index].title),
                  value: watchlist[index].watched,
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: IconButton(
                    onPressed: () async {
                      setState(() => watchlist.removeAt(index));
                      await _saveAndSyncWatchlist();
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                  onChanged: (checked) async {
                    setState(() {
                      watchlist[index].watched = checked ?? false;
                    });
                    await _saveAndSyncWatchlist();
                  },
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: watchInput,
                      onSubmitted: (_) => _addWatchItem(),
                      decoration: const InputDecoration(
                        hintText: 'Add a film or series',
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: _addWatchItem,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _heading(String index, String label) => Row(
        children: [
          Text(index, style: const TextStyle(color: violet, fontSize: 12)),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
        ],
      );

  Future<void> _addWatchItem() async {
    final title = watchInput.text.trim();
    if (title.isEmpty) return;
    setState(() => watchlist.add(WatchItem(title: title)));
    watchInput.clear();
    await _saveAndSyncWatchlist();
  }
}
