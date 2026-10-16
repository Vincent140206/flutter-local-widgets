class WatchItem {
  WatchItem({required this.title, this.watched = false});

  String title;
  bool watched;

  WatchItem copy() => WatchItem(title: title, watched: watched);

  Map<String, dynamic> toJson() => {'title': title, 'watched': watched};

  factory WatchItem.fromJson(Map<String, dynamic> data) => WatchItem(
        title: data['title'] as String? ?? '',
        watched: data['watched'] as bool? ?? false,
      );
}
