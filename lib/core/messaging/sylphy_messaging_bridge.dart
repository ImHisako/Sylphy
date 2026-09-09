import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../native/native_core.dart';
import 'models.dart';
import 'secure_messaging_bridge.dart';

/// Fail-closed adapter for messaging records owned by the Rust core.
///
class SylphyMessagingBridge
    implements
        SecureMessagingBridge,
        GroupMessagingBridge,
        InboxRefreshingBridge,
        InboxRevisionNotifications,
        InboxStorageStatus,
        CachedMessagingBridge {
  SylphyMessagingBridge({required NativeCoreApi core}) : _core = core;

  final NativeCoreApi _core;
  final Map<String, ChatMessage> _messageCache = {};
  final Map<String, List<ChatMessage>> _messageListCache = {};
  final Map<String, Future<List<ChatMessage>>> _messageRefreshes = {};
  final Map<String, bool> _hasOlderMessages = {};
  final Set<String> _expandedHistories = {};
  final Map<String, Future<List<ChatMessage>>> _olderLoads = {};
  List<Conversation>? _conversationCache;
  Future<List<Conversation>>? _conversationRefresh;
  Future<int>? _inboxRefresh;
  int _inboxRevision = 0;
  int _cacheGeneration = 0;
  final ValueNotifier<int> _inboxChanges = ValueNotifier(0);
  @override
  bool inboxStorageFull = false;

  @override
  ValueListenable<int> get inboxChanges => _inboxChanges;

  void clearCachesAfterAccountImport() {
    _cacheGeneration++;
    inboxStorageFull = false;
    _conversationCache = null;
    _messageCache.clear();
    _messageListCache.clear();
    _messageRefreshes.clear();
    _hasOlderMessages.clear();
    _expandedHistories.clear();
    _olderLoads.clear();
    _conversationRefresh = null;
    _inboxRefresh = null;
    _inboxRevision = 0;
    _inboxChanges.value = 0;
  }

  @override
  int get inboxRevision => _inboxRevision;

  @override
  List<Conversation>? get cachedConversations => _conversationCache;

  @override
  List<ChatMessage>? cachedMessages(String conversationId) {
    final cached = _messageListCache.remove(conversationId);
    if (cached != null) _messageListCache[conversationId] = cached;
    return cached;
  }

  Future<void> _waitUntilCoreIsAvailable() {
    // Mutations are queued by NativeCoreClient's persistent priority worker.
    return Future.value();
  }

  @override
  Future<int> refreshInbox() {
    final generation = _cacheGeneration;
    return _inboxRefresh ??= _performInboxRefresh().whenComplete(() {
      if (generation == _cacheGeneration) _inboxRefresh = null;
    });
  }

  Future<int> _performInboxRefresh() async {
    final generation = _cacheGeneration;
    final core = _core;
    if (core is! NativeCoreClient) return _inboxRevision;
    final response = await core.syncInboundInBackground();
    if (generation != _cacheGeneration) return _inboxRevision;
    _requireSuccess(response);
    final revision = response.data['revision'];
    inboxStorageFull = response.data['storage_full'] == true;
    if (revision is! int || revision < 0) {
      throw const SecureMessagingException('invalid_native_response');
    }
    _inboxRevision = revision;
    _inboxChanges.value = revision;
    return revision;
  }

  @override
  List<Conversation> listConversations() {
    return _conversationCache ?? _parseConversations(_core.listConversations());
  }

  @override
  Future<List<Conversation>> refreshConversations() {
    final generation = _cacheGeneration;
    return _conversationRefresh ??= _performConversationRefresh().whenComplete(
      () {
        if (generation == _cacheGeneration) _conversationRefresh = null;
      },
    );
  }

  Future<List<Conversation>> _performConversationRefresh() async {
    final generation = _cacheGeneration;
    final core = _core;
    final response = core is NativeCoreClient
        ? await core.listConversationsInBackground()
        : core.listConversations();
    if (generation != _cacheGeneration) return const [];
    return _parseConversations(response);
  }

  List<Conversation> _parseConversations(NativeCoreResponse response) {
    _requireSuccess(response);
    final records = response.data['conversations'];
    if (records is! List) {
      throw const SecureMessagingException('invalid_native_response');
    }
    final conversations = List<Conversation>.unmodifiable(
      records.map(_parseConversation),
    );
    _conversationCache = conversations;
    return conversations;
  }

  @override
  List<ChatMessage> listMessages(String conversationId) {
    return cachedMessages(conversationId) ??
        _parseMessages(conversationId, _core.listMessages(conversationId));
  }

  @override
  Future<List<ChatMessage>> refreshMessages(
    String conversationId, {
    bool priority = false,
  }) {
    final existing = _messageRefreshes[conversationId];
    if (existing != null) {
      return existing;
    }
    final generation = _cacheGeneration;
    return _messageRefreshes[conversationId] =
        _performMessageRefresh(
          conversationId,
          priority: priority,
        ).whenComplete(() {
          // Do not return the removed Future from this callback: whenComplete
          // would wait on that same Future and create a self-referential deadlock.
          if (generation == _cacheGeneration) {
            _messageRefreshes.remove(conversationId);
          }
        });
  }

  Future<List<ChatMessage>> _performMessageRefresh(
    String conversationId, {
    required bool priority,
  }) async {
    final generation = _cacheGeneration;
    final core = _core;
    final response = core is NativeCoreMessagePageApi
        ? await (core as NativeCoreMessagePageApi).listMessagesInBackground(
            conversationId,
            priority: priority,
          )
        : core.listMessages(conversationId);
    if (generation != _cacheGeneration) return const [];
    _requireSuccess(response);
    if (!_expandedHistories.contains(conversationId)) {
      _hasOlderMessages[conversationId] = response.data['has_more'] == true;
    }
    return _parseMessages(conversationId, response);
  }

  @override
  bool hasOlderMessages(String conversationId) =>
      _hasOlderMessages[conversationId] ?? false;

  @override
  Future<List<ChatMessage>> loadOlderMessages(String conversationId) {
    final generation = _cacheGeneration;
    return _olderLoads[conversationId] ??= _loadOlderMessages(conversationId)
        .whenComplete(() {
          if (generation == _cacheGeneration) {
            _olderLoads.remove(conversationId);
          }
        });
  }

  Future<List<ChatMessage>> _loadOlderMessages(String conversationId) async {
    final generation = _cacheGeneration;
    final current = cachedMessages(conversationId) ?? const <ChatMessage>[];
    if (current.isEmpty || !hasOlderMessages(conversationId)) return current;
    final core = _core;
    if (core is! NativeCoreMessagePageApi) return current;
    final response = await (core as NativeCoreMessagePageApi)
        .listMessagesInBackground(
          conversationId,
          priority: true,
          beforeMs: current.first.sentAt.toUtc().millisecondsSinceEpoch,
          beforeId: current.first.id,
        );
    _requireSuccess(response);
    if (generation != _cacheGeneration) {
      return cachedMessages(conversationId) ?? const <ChatMessage>[];
    }
    final records = response.data['messages'];
    if (records is! List) {
      throw const SecureMessagingException('invalid_native_response');
    }
    _hasOlderMessages[conversationId] = response.data['has_more'] == true;
    final older = records.map(_parseMessage).toList(growable: false);
    _expandedHistories.add(conversationId);
    final merged = _mergeMessages(
      _mergeMessages(older, current),
      cachedMessages(conversationId) ?? const [],
    );
    _messageListCache[conversationId] = merged;
    for (final message in older) {
      _messageCache['$conversationId:${message.id}'] = message;
    }
    return merged;
  }

  List<ChatMessage> _parseMessages(
    String conversationId,
    NativeCoreResponse response,
  ) {
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
    final immutable = _expandedHistories.contains(conversationId)
        ? _mergeMessages(
            _messageListCache[conversationId] ?? const [],
            messages,
          )
        : List<ChatMessage>.unmodifiable(messages);
    _messageListCache.remove(conversationId);
    _messageListCache[conversationId] = immutable;
    while (_messageListCache.length > 24) {
      final evicted = _messageListCache.keys.first;
      _messageListCache.remove(evicted);
      _expandedHistories.remove(evicted);
      _hasOlderMessages.remove(evicted);
      _messageCache.removeWhere((key, _) => key.startsWith('$evicted:'));
    }
    return immutable;
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
    _conversationCache = null;
    return _requiredString(response.data, 'contact_id');
  }

  @override
  Future<String> createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    String description = '',
  }) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    if (core is NativeCoreClient) {
      final response = await core.createGroupInBackground(
        name: name,
        invitationCodes: invitationCodes,
        professional: professional,
        description: description,
      );
      _requireSuccess(response);
      _conversationCache = null;
      return _requiredString(response.data, 'group_id');
    }
    if (core is! NativeCoreGroupApi) {
      throw const SecureMessagingException('unsupported');
    }
    final response = core.createGroup(
      name: name,
      invitationCodes: invitationCodes,
      professional: professional,
      description: description,
    );
    _requireSuccess(response);
    _conversationCache = null;
    return _requiredString(response.data, 'group_id');
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
    _conversationCache = null;
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
    _conversationCache = null;
    _messageListCache.remove(conversationId);
    _expandedHistories.remove(conversationId);
    _hasOlderMessages.remove(conversationId);
    _messageCache.removeWhere((key, _) => key.startsWith('$conversationId:'));
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
    _conversationCache = null;
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
    _conversationCache = null;
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
    _conversationCache = null;
  }
}

List<ChatMessage> _mergeMessages(
  List<ChatMessage> older,
  List<ChatMessage> newer,
) {
  final byId = {for (final message in older) message.id: message};
  for (final message in newer) {
    byId[message.id] = message;
  }
  final merged = byId.values.toList()
    ..sort((a, b) {
      final time = a.sentAt.compareTo(b.sentAt);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
  return List.unmodifiable(merged);
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
    type: _parseConversationType(
      value['conversation_type'],
      isGroup: value['is_group'] == true,
    ),
    memberCount: _optionalInt(value, 'member_count', 2),
    isAdmin: value['is_admin'] == true,
    description: _optionalString(value, 'description', ''),
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

ConversationType _parseConversationType(
  Object? value, {
  required bool isGroup,
}) {
  if (value == null) {
    return isGroup ? ConversationType.group : ConversationType.direct;
  }
  return switch (value) {
    'direct' => ConversationType.direct,
    'group' => ConversationType.group,
    'channel' => ConversationType.channel,
    _ => throw const SecureMessagingException('invalid_native_response'),
  };
}

int _optionalInt(Map<String, dynamic> value, String key, int fallback) {
  final field = value[key];
  if (field == null) {
    return fallback;
  }
  if (field is! int || field < 1) {
    throw const SecureMessagingException('invalid_native_response');
  }
  return field;
}

String _optionalString(
  Map<String, dynamic> value,
  String key,
  String fallback,
) {
  final field = value[key];
  if (field == null) return fallback;
  if (field is! String) {
    throw const SecureMessagingException('invalid_native_response');
  }
  return field;
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
    'queued' => DeliveryState.queued,
    'sent' => DeliveryState.sent,
    'delivered' => DeliveryState.delivered,
    'read' => DeliveryState.read,
    'not_restored' => DeliveryState.notRestored,
    _ => throw const SecureMessagingException('invalid_native_response'),
  };
  if (cached != null &&
      cached.id == id &&
      cached.authorId == authorId &&
      cached.body == body &&
      cached.sentAt == sentAt &&
      cached.isOutgoing == isOutgoing &&
      cached.attachmentName == attachmentName &&
      (cached.attachmentBytes != null) ==
          (value['attachment_base64'] is String &&
              (value['attachment_base64'] as String).isNotEmpty)) {
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
