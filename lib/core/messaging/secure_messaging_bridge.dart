import 'package:flutter/foundation.dart';

import 'models.dart';

abstract class SecureMessagingBridge {
  List<Conversation> listConversations();

  List<ChatMessage> listMessages(String conversationId);

  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  });

  Future<void> markConversationRead(String conversationId);

  Future<void> deleteConversation(String conversationId);

  Future<void> setContactVerified({
    required String conversationId,
    required bool verified,
  });

  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  });

  Future<void> sendAttachment({
    required String conversationId,
    required String fileName,
    required List<int> bytes,
  });
}

abstract interface class InboxRefreshingBridge {
  int get inboxRevision;

  /// Pulls and persists pending network envelopes without blocking rendering.
  Future<int> refreshInbox();
}

/// Shares completed inbox changes with open chats without another network poll.
abstract interface class InboxRevisionNotifications {
  ValueListenable<int> get inboxChanges;
}

abstract interface class InboxStorageStatus {
  bool get inboxStorageFull;
}

/// Optional capability so existing integrations can keep implementing the
/// direct messaging bridge without a breaking API change.
abstract interface class GroupMessagingBridge {
  Future<String> createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    String description = '',
  });
}

abstract interface class GroupChannelBridge {
  Future<bool> markChannelRead(String conversationId, String? channelId);
  Future<void> sendChannelText(
    String conversationId,
    String channelId,
    String text, {
    String? replyTo,
  });
  Future<void> sendChannelAttachment(
    String conversationId,
    String channelId,
    String fileName,
    List<int> bytes,
  );
}

abstract interface class GroupManagementBridge {
  Future<String> joinGroup(String invitationCode);
  Future<Map<String, dynamic>> groupDetails(String conversationId);
  Future<String> groupAction(
    String conversationId,
    Map<String, dynamic> action,
  );
  Future<Map<String, dynamic>> searchMessages(
    String conversationId,
    String query, {
    int offset = 0,
  });
  Future<void> sendReply(
    String conversationId,
    String plaintext,
    String replyTo,
  );
}

/// Convenience API for callers that only hold the original direct bridge
/// type. Capability detection remains explicit at runtime for older fakes and
/// integrations.
extension GroupMessagingOperations on SecureMessagingBridge {
  Future<String> createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    String description = '',
  }) {
    final capability = this;
    if (capability is GroupMessagingBridge) {
      return capability.createGroup(
        name: name,
        invitationCodes: invitationCodes,
        professional: professional,
        description: description,
      );
    }
    return Future<String>.error(const SecureMessagingException('unsupported'));
  }
}

/// Optional fast-path used by the UI to render local data immediately while
/// disk/network refreshes continue on the native worker isolate.
abstract interface class CachedGroupManagementBridge {
  Map<String, dynamic>? cachedGroupDetails(String conversationId);
}

abstract interface class CachedMessagingBridge
    implements SecureMessagingBridge {
  List<Conversation>? get cachedConversations;

  List<ChatMessage>? cachedMessages(String conversationId);

  Future<List<Conversation>> refreshConversations();

  Future<List<ChatMessage>> refreshMessages(
    String conversationId, {
    bool priority = false,
  });

  bool hasOlderMessages(String conversationId);

  Future<List<ChatMessage>> loadOlderMessages(String conversationId);
}

class UnavailableMessagingBridge
    implements SecureMessagingBridge, GroupMessagingBridge {
  const UnavailableMessagingBridge();

  @override
  List<Conversation> listConversations() => const [];

  @override
  List<ChatMessage> listMessages(String conversationId) => const [];

  @override
  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  }) async {
    throw const SecureMessagingException('native_core_unavailable');
  }

  @override
  Future<String> createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    String description = '',
  }) async {
    throw const SecureMessagingException('native_core_unavailable');
  }

  @override
  Future<void> markConversationRead(String conversationId) async {}

  @override
  Future<void> deleteConversation(String conversationId) async {
    throw const SecureMessagingException('native_core_unavailable');
  }

  @override
  Future<void> setContactVerified({
    required String conversationId,
    required bool verified,
  }) async {
    throw const SecureMessagingException('native_core_unavailable');
  }

  @override
  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  }) async {
    throw const SecureMessagingException('native_core_unavailable');
  }

  @override
  Future<void> sendAttachment({
    required String conversationId,
    required String fileName,
    required List<int> bytes,
  }) async {
    throw const SecureMessagingException('native_core_unavailable');
  }
}

class SecureMessagingException implements Exception {
  const SecureMessagingException(this.code);

  final String code;

  @override
  String toString() => code;
}
