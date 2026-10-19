import 'dart:io';

import 'package:flutter/services.dart';

class SpotifyWidgetService {
  static const _channel = MethodChannel('com.example.localwidgets/spotify');

  Future<bool> hasNotificationAccess() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('hasNotificationAccess') ?? false;
  }

  Future<void> openNotificationAccess() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openNotificationAccess');
    }
  }

  Future<bool> requestPinWidget() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('requestPinWidget') ?? false;
  }
}
