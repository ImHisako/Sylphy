import 'dart:typed_data';

enum DeliveryState { sent, delivered, read }

enum ContactSafety { verified, pending, refreshRequired }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.authorId,
    required this.body,
    required this.sentAt,
    required this.isOutgoing,
    this.deliveryState = DeliveryState.sent,
    this.attachmentName,
    this.attachmentBytes,
  });

  final String id;
  final String authorId;
  final String body;
  final DateTime sentAt;
  final bool isOutgoing;
  final DeliveryState deliveryState;
  final String? attachmentName;
  final Uint8List? attachmentBytes;

  ChatMessage copyWith({DeliveryState? deliveryState}) {
    return ChatMessage(
      id: id,
      authorId: authorId,
      body: body,
      sentAt: sentAt,
      isOutgoing: isOutgoing,
      deliveryState: deliveryState ?? this.deliveryState,
      attachmentName: attachmentName,
      attachmentBytes: attachmentBytes,
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
    this.avatarBytes,
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
  final Uint8List? avatarBytes;
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
      safety: safety ?? this.safety,
      fingerprint: fingerprint,
      avatarBytes: avatarBytes,
    );
  }
}
