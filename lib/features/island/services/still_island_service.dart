import 'dart:io';

import 'package:flutter/services.dart';

class StillIslandService {
  static const _channel = MethodChannel('com.example.localwidgets/island');

  Future<bool> hasOverlayPermission() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
  }

  Future<void> openOverlayPermission() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openOverlayPermission');
    }
  }

  Future<bool> isEnabled() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isEnabled') ?? false;
  }

  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>(
          'setEnabled',
          <String, bool>{'enabled': enabled},
        ) ??
        false;
  }
}
