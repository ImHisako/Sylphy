import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';

class MessageNotifications {
  const MessageNotifications();

  static const _channel = MethodChannel('sylphy/platform');

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'notifications',
        action: 'permission_request_failed',
        error: error,
      );
    }
  }

  Future<void> showIncomingMessage() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('showMessageNotification');
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'notifications',
        action: 'display_failed',
        error: error,
      );
    }
  }
}
