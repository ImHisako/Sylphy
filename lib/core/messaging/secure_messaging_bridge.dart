import 'dart:collection';

import 'models.dart';

abstract class SecureMessagingBridge {
  List<Conversation> listConversations();

  List<ChatMessage> listMessages(String conversationId);

  Future<void> markConversationRead(String conversationId);

  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  });
}

class LocalDemoMessagingBridge implements SecureMessagingBridge {
  LocalDemoMessagingBridge._({
    required List<Conversation> conversations,
    required Map<String, List<ChatMessage>> messages,
  }) : _conversations = conversations,
       _messages = messages;

  final List<Conversation> _conversations;
  final Map<String, List<ChatMessage>> _messages;

  factory LocalDemoMessagingBridge.seeded() {
    final now = DateTime.now();
    return LocalDemoMessagingBridge._(
      conversations: [
        Conversation(
          id: 'lina',
          name: 'Lina Moretti',
          initials: 'LM',
          accentValue: 0xFFA5E5D3,
          lastMessage: 'Perfetto, ci sentiamo dopo.',
          lastActivity: now.subtract(const Duration(minutes: 2)),
          unreadCount: 0,
          isOnline: true,
          safety: ContactSafety.verified,
          fingerprint: 'A9F2 71C8 4E3D B6A0',
        ),
        Conversation(
          id: 'maya',
          name: 'Maya Ricci',
          initials: 'MR',
          accentValue: 0xFFD5B4FF,
          lastMessage: 'Ti invio il riferimento cifrato.',
          lastActivity: now.subtract(const Duration(minutes: 18)),
          unreadCount: 2,
          safety: ContactSafety.verified,
          fingerprint: 'E731 4A6B 0D2F 9C88',
        ),
        Conversation(
          id: 'dario',
          name: 'Dario Neri',
          initials: 'DN',
          accentValue: 0xFFFFC98A,
          lastMessage: 'Chiave di sicurezza aggiornata.',
          lastActivity: now.subtract(const Duration(hours: 1)),
          safety: ContactSafety.refreshRequired,
          fingerprint: '6CB1 D5E2 8830 1A7F',
        ),
        Conversation(
          id: 'team',
          name: 'Team Sylphy',
          initials: 'TS',
          accentValue: 0xFF93C5FD,
          lastMessage: 'Arianna: stand-up alle 10:00',
          lastActivity: now.subtract(const Duration(hours: 3)),
          unreadCount: 4,
          isGroup: true,
          safety: ContactSafety.pending,
          fingerprint: 'Gruppo · 4 dispositivi',
        ),
      ],
      messages: {
        'lina': [
          ChatMessage(
            id: 'lina-1',
            authorId: 'lina',
            body: 'Ciao! Ho appena controllato il nuovo flusso.',
            sentAt: now.subtract(const Duration(minutes: 31)),
            isOutgoing: false,
            deliveryState: DeliveryState.read,
          ),
          ChatMessage(
            id: 'lina-2',
            authorId: 'me',
            body: 'Ottimo. La schermata è molto più chiara anche su mobile.',
            sentAt: now.subtract(const Duration(minutes: 17)),
            isOutgoing: true,
            deliveryState: DeliveryState.read,
          ),
          ChatMessage(
            id: 'lina-3',
            authorId: 'lina',
            body: 'Perfetto, ci sentiamo dopo.',
            sentAt: now.subtract(const Duration(minutes: 2)),
            isOutgoing: false,
            deliveryState: DeliveryState.delivered,
          ),
        ],
        'maya': [
          ChatMessage(
            id: 'maya-1',
            authorId: 'maya',
            body: 'Ti invio il riferimento cifrato.',
            sentAt: now.subtract(const Duration(minutes: 18)),
            isOutgoing: false,
          ),
        ],
        'dario': [
          ChatMessage(
            id: 'dario-1',
            authorId: 'dario',
            body:
                'La mia chiave di sicurezza è cambiata: verifichiamola prima di proseguire.',
            sentAt: now.subtract(const Duration(hours: 1)),
            isOutgoing: false,
          ),
        ],
        'team': [
          ChatMessage(
            id: 'team-1',
            authorId: 'arianna',
            body: 'Stand-up alle 10:00, stessa stanza privata.',
            sentAt: now.subtract(const Duration(hours: 3)),
            isOutgoing: false,
          ),
        ],
      },
    );
  }

  @override
  List<Conversation> listConversations() {
    final ordered = List<Conversation>.from(_conversations)
      ..sort(
        (first, second) => second.lastActivity.compareTo(first.lastActivity),
      );
    return List.unmodifiable(ordered);
  }

  @override
  List<ChatMessage> listMessages(String conversationId) {
    return UnmodifiableListView(_messages[conversationId] ?? const []);
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    final index = _conversations.indexWhere(
      (conversation) => conversation.id == conversationId,
    );
    if (index >= 0 && _conversations[index].unreadCount > 0) {
      _conversations[index] = _conversations[index].copyWith(unreadCount: 0);
    }
  }

  @override
  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  }) async {
    final body = plaintext.trim();
    if (body.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final messages = _messages.putIfAbsent(conversationId, () => []);
    messages.add(
      ChatMessage(
        id: 'local-${now.microsecondsSinceEpoch}',
        authorId: 'me',
        body: body,
        sentAt: now,
        isOutgoing: true,
        deliveryState: DeliveryState.sent,
      ),
    );
    final conversationIndex = _conversations.indexWhere(
      (conversation) => conversation.id == conversationId,
    );
    if (conversationIndex >= 0) {
      _conversations[conversationIndex] = _conversations[conversationIndex]
          .copyWith(lastMessage: body, lastActivity: now, unreadCount: 0);
    }
  }
}
