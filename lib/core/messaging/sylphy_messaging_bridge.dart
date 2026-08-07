import 'dart:convert';

import '../native/native_core.dart';
import 'models.dart';
import 'secure_messaging_bridge.dart';

/// Fail-closed adapter for messaging records owned by the Rust core.
///
class SylphyMessagingBridge
    implements SecureMessagingBridge, InboxRefreshingBridge {
  SylphyMessagingBridge({required NativeCoreApi core}) : _core = core;

  final NativeCoreApi _core;
  final Map<String, ChatMessage> _messageCache = {};
  Future<int>? _inboxRefresh;
  int _inboxRevision = 0;

  @override
  int get inboxRevision => _inboxRevision;

  Future<void> _waitUntilCoreIsAvailable() {
    // Mutations are queued by NativeCoreClient's persistent priority worker.
    return Future.value();
  }

  @override
  Future<int> refreshInbox() {
    return _inboxRefresh ??= _performInboxRefresh().whenComplete(
      () => _inboxRefresh = null,
    );
  }

  Future<int> _performInboxRefresh() async {
    final core = _core;
    if (core is! NativeCoreClient) return _inboxRevision;
    final response = await core.syncInboundInBackground();
    _requireSuccess(response);
    final revision = response.data['revision'];
    if (revision is! int || revision < 0) {
      throw const SecureMessagingException('invalid_native_response');
    }
    _inboxRevision = revision;
    return revision;
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
    final messages = records
        .map((record) {
          if (record is! Map<String, dynamic>) {
            throw const SecureMessagingException('invalid_native_response');
          }
          final id = _requiredString(record, 'id');
          final cacheKey = '$conversationId:$id';
          final message = _parseMessage(
            record,
            cached: _messageCache[cacheKey],
          );
          _messageCache[cacheKey] = message;
          return message;
        })
        .toList(growable: false);
    if (_messageCache.length > 4096) {
      final staleKeys = _messageCache.keys
          .take(_messageCache.length - 2048)
          .toList(growable: false);
      for (final key in staleKeys) {
        _messageCache.remove(key);
      }
    }
    return List.unmodifiable(messages);
  }

  @override
  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  }) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    final response = core is NativeCoreClient
        ? await core.addContactInBackground(
            displayName: displayName,
            invitationCode: invitationCode,
          )
        : core.addContact(
            displayName: displayName,
            invitationCode: invitationCode,
          );
    _requireSuccess(response);
    return _requiredString(response.data, 'contact_id');
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    _requireSuccess(
      core is NativeCoreClient
          ? await core.markConversationReadInBackground(conversationId)
          : core.markConversationRead(conversationId),
    );
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    _requireSuccess(
      core is NativeCoreClient
          ? await core.deleteConversationInBackground(conversationId)
          : core.deleteConversation(conversationId),
    );
  }

  @override
  Future<void> setContactVerified({
    required String conversationId,
    required bool verified,
  }) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    _requireSuccess(
      core is NativeCoreClient
          ? await core.setContactVerifiedInBackground(
              conversationId: conversationId,
              verified: verified,
            )
          : core.setContactVerified(
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
    final core = _core;
    _requireSuccess(
      core is NativeCoreClient
          ? await core.sendTextInBackground(
              conversationId: conversationId,
              plaintext: plaintext,
            )
          : core.sendText(conversationId: conversationId, plaintext: plaintext),
    );
  }

  @override
  Future<void> sendAttachment({
    required String conversationId,
    required String fileName,
    required List<int> bytes,
  }) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    final encoded = base64Encode(bytes);
    _requireSuccess(
      core is NativeCoreClient
          ? await core.sendAttachmentInBackground(
              conversationId: conversationId,
              fileName: fileName,
              bytesBase64: encoded,
            )
          : core.sendAttachment(
              conversationId: conversationId,
              fileName: fileName,
              bytesBase64: encoded,
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

ChatMessage _parseMessage(Object? value, {ChatMessage? cached}) {
  if (value is! Map<String, dynamic>) {
    throw const SecureMessagingException('invalid_native_response');
  }
  final id = _requiredString(value, 'id');
  final authorId = _requiredString(value, 'author_id');
  final body = _requiredString(value, 'body');
  final sentAt = DateTime.fromMillisecondsSinceEpoch(
    _requiredInt(value, 'sent_at_ms'),
    isUtc: true,
  ).toLocal();
  final isOutgoing = value['is_outgoing'] == true;
  final attachmentName = value['attachment_name'] as String?;
  final deliveryState = switch (_requiredString(value, 'delivery_state')) {
    'sent' => DeliveryState.sent,
    'delivered' => DeliveryState.delivered,
    'read' => DeliveryState.read,
    _ => throw const SecureMessagingException('invalid_native_response'),
  };
  if (cached != null &&
      cached.id == id &&
      cached.authorId == authorId &&
      cached.body == body &&
      cached.sentAt == sentAt &&
      cached.isOutgoing == isOutgoing &&
      cached.attachmentName == attachmentName) {
    return cached.deliveryState == deliveryState
        ? cached
        : cached.copyWith(deliveryState: deliveryState);
  }
  return ChatMessage(
    id: id,
    authorId: authorId,
    body: body,
    sentAt: sentAt,
    isOutgoing: isOutgoing,
    deliveryState: deliveryState,
    attachmentName: attachmentName,
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
