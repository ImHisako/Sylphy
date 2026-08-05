import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/diagnostics/app_log.dart';
import 'package:sylphy/core/messaging/models.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/main.dart';

void main() {
  testWidgets('uses readable text in floating notifications', (tester) async {
    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    final snackBarTheme = Theme.of(context).snackBarTheme;

    expect(snackBarTheme.backgroundColor, const Color(0xFF252B34));
    expect(snackBarTheme.contentTextStyle?.color, const Color(0xFFF4F7F2));
    expect(snackBarTheme.actionTextColor, const Color(0xFFCFF36A));
  });

  testWidgets('opens Developer Options and exposes diagnostic logs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => AppLog.instance.setVerboseEnabled(false));
    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Impostazioni'), findsOneWidget);
    expect(find.text('DEVELOPER OPTIONS'), findsOneWidget);
    expect(find.byKey(const ValueKey('developer-log-viewer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('developer-logging-switch')));
    await tester.pump();
    expect(AppLog.instance.verboseEnabled, isTrue);
  });

  testWidgets('starts closed without demonstration conversations', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    expect(find.text('Sylphy'), findsOneWidget);
    expect(find.text('Nessuna conversazione sicura'), findsAtLeastNWidgets(1));
    expect(find.text('Lina Moretti'), findsNothing);
    expect(find.byKey(const ValueKey('message-composer')), findsNothing);
    expect(find.text('Nessun dato dimostrativo caricato'), findsOneWidget);
  });

  testWidgets('renders explicitly injected test conversations', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();

    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'Messaggio di prova',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();

    expect(find.text('Messaggio di prova'), findsAtLeastNWidgets(1));
  });

  testWidgets('keeps the real empty state readable on a mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    expect(find.text('Core Veilid non incluso'), findsAtLeastNWidgets(1));
    expect(find.text('Nessuna conversazione sicura'), findsOneWidget);
    expect(find.text('Aggiungi contatto'), findsOneWidget);
    await tester.tap(find.byTooltip('Stato protezione'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy di Sylphy'), findsOneWidget);
    expect(find.textContaining('conversazioni dimostrative'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks for a name on first launch and accepts no photo', (
    tester,
  ) async {
    final store = _MemoryProfileStore();

    await tester.pumpWidget(SylphyApp(profileStore: store));
    await tester.pumpAndSettle();

    expect(find.text('Crea il tuo profilo'), findsOneWidget);
    expect(find.textContaining('non è obbligatoria'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Ada Lovelace',
    );
    await tester.tap(find.byKey(const ValueKey('complete-onboarding')));
    await tester.pumpAndSettle();

    expect(store.profile?.displayName, 'Ada Lovelace');
    expect(store.profile?.photoBytes, isNull);
    expect(
      find.byKey(const ValueKey('current-profile-avatar')),
      findsOneWidget,
    );
    expect(find.text('Nessuna conversazione sicura'), findsAtLeastNWidgets(1));
  });

  testWidgets('opens the add-contact flow from the mobile home', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mobile-add-contact')));
    await tester.pumpAndSettle();

    expect(find.text('Aggiungi una persona'), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-name')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('contact-invitation-code')),
      findsOneWidget,
    );
  });

  testWidgets('opens the own profile and changes the display name', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _completedProfileStore();
    await tester.pumpWidget(SylphyApp(profileStore: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Il mio profilo'), findsOneWidget);
    expect(find.text('Profilo Test'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Modifica il tuo profilo'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Nuovo Nome',
    );
    await tester.tap(find.byKey(const ValueKey('complete-onboarding')));
    await tester.pumpAndSettle();

    expect(store.profile?.displayName, 'Nuovo Nome');
    await tester.tap(find.byKey(const ValueKey('open-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Nuovo Nome'), findsOneWidget);
  });
}

_MemoryProfileStore _completedProfileStore() =>
    _MemoryProfileStore(const UserProfile(displayName: 'Profilo Test'));

class _MemoryProfileStore implements UserProfileStore {
  _MemoryProfileStore([this.profile]);

  UserProfile? profile;

  @override
  Future<UserProfile?> load() async => profile;

  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async {
    return profile = UserProfile(
      displayName: displayName.trim(),
      photoBytes: photoBytes,
    );
  }
}

class _TestMessagingBridge implements SecureMessagingBridge {
  _TestMessagingBridge()
    : _conversation = Conversation(
        id: 'test-contact',
        name: 'Contatto di test',
        initials: 'CT',
        accentValue: 0xFFA5E5D3,
        lastMessage: '',
        lastActivity: DateTime(2026),
        safety: ContactSafety.verified,
        fingerprint: 'TEST',
      );

  Conversation _conversation;
  final List<ChatMessage> _messages = [];

  @override
  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  }) async => 'test-contact';

  @override
  List<Conversation> listConversations() => [_conversation];

  @override
  List<ChatMessage> listMessages(String conversationId) => _messages;

  @override
  Future<void> markConversationRead(String conversationId) async {}

  @override
  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  }) async {
    final now = DateTime(2026, 1, 1, 12);
    _messages.add(
      ChatMessage(
        id: 'test-message',
        authorId: 'me',
        body: plaintext,
        sentAt: now,
        isOutgoing: true,
      ),
    );
    _conversation = _conversation.copyWith(
      lastMessage: plaintext,
      lastActivity: now,
    );
  }
}
