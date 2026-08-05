import 'dart:convert';

import '../native/native_core.dart';
import 'models.dart';
import 'secure_messaging_bridge.dart';

/// Fail-closed adapter for messaging records owned by the Rust core.
///
class SylphyMessagingBridge implements SecureMessagingBridge {
  SylphyMessagingBridge({required NativeCoreApi core}) : _core = core;

  final NativeCoreApi _core;

  Future<void> _waitUntilCoreIsAvailable() {
    final core = _core;
    return core is NativeCoreClient
        ? core.waitUntilAvailable()
        : Future.value();
  }

  @override
  List<Conversation> listConversations() {
    final response = _core.listConversations();
    _requireSuccess(response);
    final records = response.data['conversations'];
    if (records is! List) {
      throw const SecureMessagingException('invalid_native_response');
    }
    return List.unmodifiable(records.map(_parseConversation));
  }

  @override
  List<ChatMessage> listMessages(String conversationId) {
    final response = _core.listMessages(conversationId);
    _requireSuccess(response);
    final records = response.data['messages'];
    if (records is! List) {
      throw const SecureMessagingException('invalid_native_response');
    }
    return List.unmodifiable(records.map(_parseMessage));
  }

  @override
  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  }) async {
    await _waitUntilCoreIsAvailable();
    final response = _core.addContact(
      displayName: displayName,
      invitationCode: invitationCode,
    );
    _requireSuccess(response);
    return _requiredString(response.data, 'contact_id');
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    await _waitUntilCoreIsAvailable();
    _requireSuccess(_core.markConversationRead(conversationId));
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    await _waitUntilCoreIsAvailable();
    _requireSuccess(_core.deleteConversation(conversationId));
  }

  @override
  Future<void> setContactVerified({
    required String conversationId,
    required bool verified,
  }) async {
    await _waitUntilCoreIsAvailable();
    _requireSuccess(
      _core.setContactVerified(
        conversationId: conversationId,
        verified: verified,
      ),
    );
  }

  @override
  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  }) async {
    await _waitUntilCoreIsAvailable();
    _requireSuccess(
      _core.sendText(conversationId: conversationId, plaintext: plaintext),
    );
  }

  @override
  Future<void> sendAttachment({
    required String conversationId,
    required String fileName,
    required List<int> bytes,
  }) async {
    await _waitUntilCoreIsAvailable();
    _requireSuccess(
      _core.sendAttachment(
        conversationId: conversationId,
        fileName: fileName,
        bytesBase64: base64Encode(bytes),
      ),
    );
  }
}

void _requireSuccess(NativeCoreResponse response) {
  if (!response.ok) {
    throw SecureMessagingException(response.code);
  }
}

Conversation _parseConversation(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const SecureMessagingException('invalid_native_response');
  }
  final id = _requiredString(value, 'id');
  final name = _requiredString(value, 'name');
  return Conversation(
    id: id,
    name: name,
    initials: _requiredString(value, 'initials'),
    accentValue: _requiredInt(value, 'accent_value'),
    lastMessage: _requiredString(value, 'last_message'),
    lastActivity: DateTime.fromMillisecondsSinceEpoch(
      _requiredInt(value, 'last_activity_ms'),
      isUtc: true,
    ).toLocal(),
    unreadCount: _requiredInt(value, 'unread_count'),
    isOnline: value['is_online'] == true,
    isGroup: value['is_group'] == true,
    safety: switch (_requiredString(value, 'safety')) {
      'verified' => ContactSafety.verified,
      'pending' => ContactSafety.pending,
      'refresh_required' => ContactSafety.refreshRequired,
      _ => throw const SecureMessagingException('invalid_native_response'),
    },
    fingerprint: _requiredString(value, 'fingerprint'),
    avatarBytes: switch (value['avatar_base64']) {
      final String encoded when encoded.isNotEmpty => base64Decode(encoded),
      _ => null,
    },
  );
}

ChatMessage _parseMessage(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const SecureMessagingException('invalid_native_response');
  }
  return ChatMessage(
    id: _requiredString(value, 'id'),
    authorId: _requiredString(value, 'author_id'),
    body: _requiredString(value, 'body'),
    sentAt: DateTime.fromMillisecondsSinceEpoch(
      _requiredInt(value, 'sent_at_ms'),
      isUtc: true,
    ).toLocal(),
    isOutgoing: value['is_outgoing'] == true,
    deliveryState: switch (_requiredString(value, 'delivery_state')) {
      'sent' => DeliveryState.sent,
      'delivered' => DeliveryState.delivered,
      'read' => DeliveryState.read,
      _ => throw const SecureMessagingException('invalid_native_response'),
    },
    attachmentName: value['attachment_name'] as String?,
    attachmentBytes: switch (value['attachment_base64']) {
      final String encoded when encoded.isNotEmpty => base64Decode(encoded),
      _ => null,
    },
  );
}

String _requiredString(Map<String, dynamic> value, String key) {
  final field = value[key];
  if (field is! String || field.isEmpty) {
    throw const SecureMessagingException('invalid_native_response');
  }
  return field;
}

int _requiredInt(Map<String, dynamic> value, String key) {
  final field = value[key];
  if (field is! int) {
    throw const SecureMessagingException('invalid_native_response');
  }
  return field;
}
