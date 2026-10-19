import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PhotoRepository {
  static const _photosKey = 'photos';
  static const _rotationKey = 'rotate_photos';

  Future<List<String>> readPhotos() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getStringList(_photosKey) ?? [];
  }

  Future<bool> readRotation() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_rotationKey) ?? true;
  }

  Future<List<String>> importPhotos() async {
    final optimizeForIosExtension = Platform.isIOS;
    final selected = await ImagePicker().pickMultiImage(
      // Android keeps the original bytes. The native widget decodes only the
      // pixels it needs, so quality is preserved without a camera-sized bitmap
      // ever entering Flutter memory. iOS needs a shared App Group copy, so it
      // gets a still-high-resolution bound before that export step.
      imageQuality: optimizeForIosExtension ? 96 : null,
      maxWidth: optimizeForIosExtension ? 3840 : null,
      maxHeight: optimizeForIosExtension ? 3840 : null,
    );
    final current = await readPhotos();
    if (selected.isEmpty) return current;

    final root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'photos'),
    );
    await root.create(recursive: true);
    final batchId = DateTime.now().microsecondsSinceEpoch;
    final copied = await Future.wait([
      for (var index = 0; index < selected.length; index++)
        _copySelectedFile(selected[index], root, batchId, index),
    ]);
    final updated = [...current, ...copied];
    await savePhotos(updated);
    return updated;
  }

  Future<String> _copySelectedFile(
    XFile selected,
    Directory root,
    int batchId,
    int index,
  ) async {
    final extension = p.extension(selected.path).toLowerCase();
    final safeExtension = extension.isEmpty ? '.jpg' : extension;
    final destination = p.join(root.path, '${batchId}_$index$safeExtension');
    return (await File(selected.path).copy(destination)).path;
  }

  Future<void> savePhotos(List<String> photos) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_photosKey, photos);
  }

  Future<void> saveRotation(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_rotationKey, enabled);
  }

  Future<void> deletePhoto(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
