import 'package:flutter/material.dart';

import '../../../core/theme/still_theme.dart';
import '../data/bible_repository.dart';

class BibleLibraryPage extends StatefulWidget {
  const BibleLibraryPage({required this.repository, super.key});

  final BibleRepository repository;

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
        query: input.text,
        topic: topic,
        favoritesOnly: favoritesOnly,
      );
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
        appBar: AppBar(
          title: const Text('Offline Bible Library'),
          actions: [
            IconButton(
              tooltip: 'Read by book and chapter',
              icon: const Icon(Icons.auto_stories_outlined),
              onPressed: () async {
                final selected = await Navigator.of(context).push<BibleVerse>(
                  MaterialPageRoute(
                    builder: (_) =>
                        BibleReaderPage(repository: widget.repository),
                  ),
                );
                if (selected != null && context.mounted) {
                  Navigator.pop(context, selected);
                }
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: TextField(
                controller: input,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Search a phrase or John 3:16',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _search,
                  ),
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
                    },
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Favorites'),
                    selected: favoritesOnly,
                    onSelected: (_) {
                      favoritesOnly = !favoritesOnly;
                      topic = '';
                      _search();
                    },
                  ),
                  const SizedBox(width: 8),
                  for (final name in const [
                    'peace',
                    'hope',
                    'faith',
                    'love',
                    'strength',
                    'wisdom',
                    'gratitude',
                    'purpose',
                  ]) ...[
                    FilterChip(
                      label: Text(name),
                      selected: topic == name,
                      onSelected: (_) {
                        topic = topic == name ? '' : name;
                        favoritesOnly = false;
                        _search();
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      verse.reference,
                                      style: const TextStyle(
                                        color: violet,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      verse.text,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        height: 1.45,
                                      ),
                                    ),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        IconButton(
                                          tooltip: 'Toggle favorite',
                                          icon: Icon(
                                            verse.isFavorite
                                                ? Icons.bookmark
                                                : Icons.bookmark_outline,
                                          ),
                                          onPressed: () async {
                                            await widget.repository
                                                .toggleFavorite(verse);
                                            await _search();
                                          },
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, verse),
                                          child: const Text('Pin to widget'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      );
}

class BibleReaderPage extends StatefulWidget {
  const BibleReaderPage({required this.repository, super.key});

  final BibleRepository repository;

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
        body: Column(
          children: [
            if (books.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: selectedBook,
                        items: books
                            .map((name) => DropdownMenuItem(
                                  value: name,
                                  child: Text(name),
                                ))
                            .toList(),
                        onChanged: (name) {
                          if (name != null) _selectBook(name);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      value: chapter,
                      items: List.generate(
                        chapters,
                        (index) => DropdownMenuItem(
                          value: index + 1,
                          child: Text('Chapter ${index + 1}'),
                        ),
                      ),
                      onChanged: (value) {
                        if (value != null) {
                          chapter = value;
                          _loadChapter();
                        }
                      },
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: verses.length,
                itemBuilder: (_, index) {
                  final verse = verses[index];
                  return ListTile(
                    title: Text(verse.text),
                    subtitle: Text(
                      verse.reference,
                      style: const TextStyle(color: violet),
                    ),
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
                          value: 'pin',
                          child: Text('Pin to widget'),
                        ),
                        PopupMenuItem(
                          value: 'favorite',
                          child: Text(
                            verse.isFavorite
                                ? 'Remove favorite'
                                : 'Add favorite',
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
}
