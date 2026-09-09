// Regressions found during the September 2026 code review.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/messaging/models.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/main.dart';

void main() {
  testWidgets('ignores late history from a previous conversation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _ReviewBridge();
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _Profile()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carica messaggi precedenti'));
    await tester.pump();
    await tester.tap(find.text('Chat B').first);
    await tester.pumpAndSettle();
    expect(find.text('Messaggio B'), findsOneWidget);
    bridge.older.complete([_message('old-a', 'Cronologia privata A')]);
    await tester.pumpAndSettle();
    // A late response must not change the visible conversation.
    expect(find.text('Chat B'), findsWidgets);
    expect(find.text('Cronologia privata A'), findsNothing);
    expect(find.text('Messaggio B'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('preserves the next draft when an earlier send fails', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _ReviewBridge();
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _Profile()),
    );
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('message-composer'));
    await tester.enterText(composer, 'Primo messaggio');
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    await tester.enterText(composer, 'Nuova bozza da conservare');
    bridge.send.completeError(
      const SecureMessagingException('network_attach_failed'),
    );
    await tester.pumpAndSettle();
    // Keep text written after the first send.
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Nuova bozza da conservare',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

ChatMessage _message(String id, String body) => ChatMessage(
  id: id,
  authorId: 'me',
  body: body,
  sentAt: DateTime(2026),
  isOutgoing: true,
);

class _Profile implements UserProfileStore {
  @override
  Future<UserProfile?> load() async => const UserProfile(displayName: 'Review');
  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async => UserProfile(displayName: displayName, photoBytes: photoBytes);
}

class _ReviewBridge implements SecureMessagingBridge, CachedMessagingBridge {
  final older = Completer<List<ChatMessage>>();
  final send = Completer<void>();
  final conversations = [
    for (final id in ['A', 'B'])
      Conversation(
        id: id,
        name: 'Chat $id',
        initials: id,
        accentValue: 0xFFA5E5D3,
        lastMessage: '',
        lastActivity: DateTime(2026),
        safety: ContactSafety.verified,
        fingerprint: 'REVIEW',
      ),
  ];
  @override
  List<Conversation> get cachedConversations => conversations;
  @override
  List<Conversation> listConversations() => conversations;
  @override
  Future<List<Conversation>> refreshConversations() async => conversations;
  @override
  List<ChatMessage> cachedMessages(String conversationId) =>
      listMessages(conversationId);
  @override
  List<ChatMessage> listMessages(String conversationId) => [
    _message(conversationId, 'Messaggio $conversationId'),
  ];
  @override
  Future<List<ChatMessage>> refreshMessages(
    String conversationId, {
    bool priority = false,
  }) async => listMessages(conversationId);
  @override
  bool hasOlderMessages(String conversationId) => conversationId == 'A';
  @override
  Future<List<ChatMessage>> loadOlderMessages(String conversationId) =>
      older.future;
  @override
  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  }) => send.future;
  @override
  Future<void> markConversationRead(String conversationId) async {}
  @override
  Future<void> deleteConversation(String conversationId) async {}
  @override
  Future<void> setContactVerified({
    required String conversationId,
    required bool verified,
  }) async {}
  @override
  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  }) async => 'A';
  @override
  Future<void> sendAttachment({
    required String conversationId,
    required String fileName,
    required List<int> bytes,
  }) async {}
}
