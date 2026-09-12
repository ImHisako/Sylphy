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
        GroupManagementBridge,
        GroupChannelBridge,
        CachedGroupManagementBridge,
        InboxRefreshingBridge,
        InboxRevisionNotifications,
        InboxStorageStatus,
        CachedMessagingBridge {
  SylphyMessagingBridge({required NativeCoreApi core}) : _core = core;

  final NativeCoreApi _core;
  final Map<String, int> _groupRevisions = {};

  @override
  Future<String> joinGroup(String invitationCode) async {
    final response = await _groupCommand({
      'command': 'join_group',
      'invitation_code': invitationCode,
    });
    _conversationCache = null;
    return _requiredString(response.data, 'group_id');
  }

  Future<NativeCoreResponse> _groupCommand(Map<String, dynamic> request) async {
    await _waitUntilCoreIsAvailable();
    final core = _core;
    if (core is! NativeCoreClient) {
      throw const SecureMessagingException('unsupported');
    }
    final response = await core.groupCommandInBackground(request);
    _requireSuccess(response);
    return response;
  }

  @override
  Future<Map<String, dynamic>> groupDetails(String conversationId) {
    final generation = _cacheGeneration;
    return _groupDetailLoads[conversationId] ??=
        _groupCommand({
              'command': 'group_details',
              'conversation_id': conversationId,
            })
            .then((response) {
              if (generation != _cacheGeneration) {
                throw const SecureMessagingException('invalid_input');
              }
              _groupDetailsCache[conversationId] = response.data;
              return response.data;
            })
            .whenComplete(() {
              if (generation == _cacheGeneration) {
                _groupDetailLoads.remove(conversationId);
              }
            });
  }

  final _groupDetailLoads = <String, Future<Map<String, dynamic>>>{};
  final _groupDetailsCache = <String, Map<String, dynamic>>{};
  @override
  Map<String, dynamic>? cachedGroupDetails(String conversationId) =>
      _groupDetailsCache[conversationId];

  @override
  Future<String> groupAction(
    String conversationId,
    Map<String, dynamic> action,
  ) async {
    final response = await _groupCommand({
      'command': 'group_action',
      'conversation_id': conversationId,
      'action': action,
    });
    _conversationCache = null;
    _expandedHistories.remove(conversationId);
    _messageListCache.remove(conversationId);
    return response.data['state'] as String? ?? 'applied';
  }

  @override
  Future<Map<String, dynamic>> searchMessages(
    String conversationId,
    String query, {
    int offset = 0,
  }) async => (await _groupCommand({
    'command': 'search_messages',
    'conversation_id': conversationId,
    'query': query,
    'offset': offset,
  })).data;

  @override
  Future<void> sendReply(
    String conversationId,
    String plaintext,
    String replyTo,
  ) async {
    await _groupCommand({
      'command': 'send_reply',
      'conversation_id': conversationId,
      'plaintext': plaintext,
      'reply_to': replyTo,
    });
    _conversationCache = null;
  }

  @override
  Future<bool> markChannelRead(String conversationId, String? channelId) async {
    final response = await _groupCommand({
      'command': 'mark_channel_read',
      'conversation_id': conversationId,
      if (channelId != null) 'channel_id': channelId,
    });
    _conversationCache = null;
    return response.data['all_read'] == true;
  }

  @override
  Future<void> sendChannelText(
    String conversationId,
    String channelId,
    String text, {
    String? replyTo,
  }) async {
    await _groupCommand({
      'command': 'send_channel_text',
      'conversation_id': conversationId,
      'channel_id': channelId,
      'plaintext': text,
      if (replyTo != null) 'reply_to': replyTo,
    });
    _conversationCache = null;
  }

  @override
  Future<void> sendChannelAttachment(
    String conversationId,
    String channelId,
    String fileName,
    List<int> bytes,
  ) async {
    await _groupCommand({
      'command': 'send_channel_attachment',
      'conversation_id': conversationId,
      'channel_id': channelId,
      'file_name': fileName,
      'bytes_base64': base64Encode(bytes),
    });
    _conversationCache = null;
  }

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
    _groupRevisions.clear();
    _groupDetailLoads.clear();
    _groupDetailsCache.clear();
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
    for (final conversation in conversations.where((item) => item.isGroup)) {
      final known = _groupRevisions[conversation.id];
      if (known != null && conversation.groupRevision < known) continue;
      if (known != conversation.groupRevision) {
        _expandedHistories.remove(conversation.id);
        _messageListCache.remove(conversation.id);
      }
      _groupRevisions[conversation.id] = conversation.groupRevision;
    }
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
    final groupRevision = _groupRevisions[conversationId];
    final current = cachedMessages(conversationId) ?? const <ChatMessage>[];
    if (current.isEmpty || !hasOlderMessages(conversationId)) return current;
    final core = _core;
    if (core is! NativeCoreMessagePageApi) return current;
    final response = await (core as NativeCoreMessagePageApi)
        .listMessagesInBackground(
          conversationId,
          priority: true,
          beforeMs: current.first.orderAt.toUtc().millisecondsSinceEpoch,
          beforeId: current.first.id,
        );
    _requireSuccess(response);
    if (generation != _cacheGeneration ||
        groupRevision != _groupRevisions[conversationId]) {
      return cachedMessages(conversationId) ?? const <ChatMessage>[];
    }
    final responseRevision = response.data['group_revision'];
    if (responseRevision is int && responseRevision != groupRevision) {
      if (responseRevision < (groupRevision ?? 0)) {
        return cachedMessages(conversationId) ?? const <ChatMessage>[];
      }
      // Moderation may have happened before this page was read, even when the
      // conversation refresh has not yet delivered the new revision to Dart.
      _groupRevisions[conversationId] = responseRevision;
      _expandedHistories.remove(conversationId);
      _messageListCache.remove(conversationId);
      return refreshMessages(conversationId, priority: true);
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
    final revision = response.data['group_revision'];
    if (revision is int) {
      final known = _groupRevisions[conversationId] ?? 0;
      if (revision < known) return cachedMessages(conversationId) ?? const [];
      if (revision > known) {
        _expandedHistories.remove(conversationId);
        _messageListCache.remove(conversationId);
      }
      _groupRevisions[conversationId] = revision;
    }
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
    _groupDetailsCache.remove(conversationId);
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
      final time = a.orderAt.compareTo(b.orderAt);
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
    canSendMessages: value['can_send_messages'] != false,
    pinnedMessageIds:
        (value['pinned_message_ids'] as List?)?.cast<String>() ?? const [],
    groupRevision: (value['group_revision'] as num?)?.toInt() ?? 0,
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
  final authorName = value['author_name'] as String?;
  final body = _requiredString(value, 'body');
  final sentAt = DateTime.fromMillisecondsSinceEpoch(
    _requiredInt(value, 'sent_at_ms'),
    isUtc: true,
  ).toLocal();
  final isOutgoing = value['is_outgoing'] == true;
  final orderAt = DateTime.fromMillisecondsSinceEpoch(
    (value['order_at_ms'] as int?) ?? _requiredInt(value, 'sent_at_ms'),
    isUtc: true,
  ).toLocal();
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
      cached.authorName == authorName &&
      cached.body == body &&
      cached.replyTo == value['reply_to'] &&
      cached.channelId == value['channel_id'] &&
      cached.sentAt == sentAt &&
      cached.orderAt == orderAt &&
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
    authorName: authorName,
    body: body,
    replyTo: value['reply_to'] as String?,
    channelId: value['channel_id'] as String?,
    sentAt: sentAt,
    orderAt: orderAt,
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
