import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../diagnostics/app_log.dart';

class MessageNotifications {
  const MessageNotifications();

  static const _channel = MethodChannel('sylphy/platform');
  static final Map<Object, String? Function()> _visibleConversations = {};

  static void trackConversation(Object owner, String? Function() visibleId) {
    _visibleConversations[owner] = visibleId;
  }

  static void untrackConversation(Object owner) {
    _visibleConversations.remove(owner);
  }

  static bool isConversationVisible(String conversationId) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    return _visibleConversations.values.any(
      (visibleId) => visibleId() == conversationId,
    );
  }

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
      await _channel.invokeMethod<void>('startBackgroundMessaging');
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'notifications',
        action: 'permission_request_failed',
        error: error,
      );
    }
  }

  Future<void> clearConversation(String conversationId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearConversationNotification', {
        'conversation_id': conversationId,
      });
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'notifications',
        action: 'clear_failed',
        error: error,
      );
    }
  }

  Future<void> clearSummaryIfRead({required bool hasUnreadMessages}) async {
    if (!Platform.isAndroid || hasUnreadMessages) return;
    try {
      await _channel.invokeMethod<void>('clearMessageSummary');
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'notifications',
        action: 'summary_clear_failed',
        error: error,
      );
    }
  }

  Future<void> showIncomingMessage({
    bool pinned = false,
    required String conversationId,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('showMessageNotification', {
        'pinned': pinned,
        'conversation_id': conversationId,
      });
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'notifications',
        action: 'display_failed',
        error: error,
      );
    }
  }
}
