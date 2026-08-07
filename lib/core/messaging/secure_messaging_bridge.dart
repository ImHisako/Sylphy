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

/// Optional fast-path used by the UI to render local data immediately while
/// disk/network refreshes continue on the native worker isolate.
abstract interface class CachedMessagingBridge
    implements SecureMessagingBridge {
  List<Conversation>? get cachedConversations;

  List<ChatMessage>? cachedMessages(String conversationId);

  Future<List<Conversation>> refreshConversations();

  Future<List<ChatMessage>> refreshMessages(String conversationId);
}

class UnavailableMessagingBridge implements SecureMessagingBridge {
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
