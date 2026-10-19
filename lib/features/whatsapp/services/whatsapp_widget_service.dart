import 'dart:io';

import 'package:flutter/services.dart';

class WhatsAppWidgetService {
  static const _channel = MethodChannel('com.example.localwidgets/whatsapp');

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
