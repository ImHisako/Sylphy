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
}

class SecureMessagingException implements Exception {
  const SecureMessagingException(this.code);

  final String code;

  @override
  String toString() => code;
}
