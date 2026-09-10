import 'dart:typed_data';

enum DeliveryState { queued, sent, delivered, read, notRestored }

extension DeliveryStateLabel on DeliveryState {
  String get label => switch (this) {
    DeliveryState.queued => 'In attesa di invio · nuovo tentativo automatico',
    DeliveryState.sent => 'Inviato · in attesa del destinatario',
    DeliveryState.delivered => 'Consegnato',
    DeliveryState.read => 'Letto',
    DeliveryState.notRestored =>
      'Invio non recuperabile da questo vecchio backup. Reinvia il messaggio.',
  };
}

enum ContactSafety { verified, pending, refreshRequired }

/// The two supported multi-person conversation styles.
enum ConversationType { direct, group, channel }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.authorId,
    required this.body,
    required this.sentAt,
    DateTime? orderAt,
    required this.isOutgoing,
    this.deliveryState = DeliveryState.sent,
    this.attachmentName,
    this.attachmentBytes,
    this.replyTo,
    this.authorName,
  }) : orderAt = orderAt ?? sentAt;

  final String id;
  final String authorId;
  final String? authorName;
  final String body;
  final DateTime sentAt;
  final DateTime orderAt;
  final bool isOutgoing;
  final DeliveryState deliveryState;
  final String? attachmentName;
  final Uint8List? attachmentBytes;
  final String? replyTo;

  ChatMessage copyWith({DeliveryState? deliveryState}) {
    return ChatMessage(
      id: id,
      authorId: authorId,
      authorName: authorName,
      body: body,
      sentAt: sentAt,
      orderAt: orderAt,
      isOutgoing: isOutgoing,
      deliveryState: deliveryState ?? this.deliveryState,
      attachmentName: attachmentName,
      attachmentBytes: attachmentBytes,
      replyTo: replyTo,
    );
  }
}

class Conversation {
  const Conversation({
    required this.id,
    required this.name,
    required this.initials,
    required this.accentValue,
    required this.lastMessage,
    required this.lastActivity,
    required this.safety,
    required this.fingerprint,
    this.unreadCount = 0,
    this.isOnline = false,
    this.isGroup = false,
    this.type = ConversationType.direct,
    this.memberCount = 2,
    this.isAdmin = false,
    this.description = '',
    this.avatarBytes,
    this.canSendMessages = true,
    this.pinnedMessageIds = const [],
    this.groupRevision = 0,
  });

  final String id;
  final String name;
  final String initials;
  final int accentValue;
  final String lastMessage;
  final DateTime lastActivity;
  final int unreadCount;
  final bool isOnline;
  final bool isGroup;
  final ConversationType type;
  final int memberCount;
  final bool isAdmin;
  final String description;
  final Uint8List? avatarBytes;
  final bool canSendMessages;
  final List<String> pinnedMessageIds;
  final int groupRevision;
  final ContactSafety safety;
  final String fingerprint;

  Conversation copyWith({
    String? lastMessage,
    DateTime? lastActivity,
    int? unreadCount,
    bool? isOnline,
    ContactSafety? safety,
  }) {
    return Conversation(
      id: id,
      name: name,
      initials: initials,
      accentValue: accentValue,
      lastMessage: lastMessage ?? this.lastMessage,
      lastActivity: lastActivity ?? this.lastActivity,
      unreadCount: unreadCount ?? this.unreadCount,
      isOnline: isOnline ?? this.isOnline,
      isGroup: isGroup,
      type: type,
      memberCount: memberCount,
      isAdmin: isAdmin,
      description: description,
      safety: safety ?? this.safety,
      fingerprint: fingerprint,
      avatarBytes: avatarBytes,
      canSendMessages: canSendMessages,
      pinnedMessageIds: pinnedMessageIds,
      groupRevision: groupRevision,
    );
  }
}
