import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sylphy/core/messaging/models.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/features/messenger/safe_attachment_image.dart';
import 'package:sylphy/main.dart';

void main() {
  // Image decoding uses one shared queue. Keep these widget cases in one fake
  // async zone, so engine callbacks cannot be left in an earlier test's zone.
  testWidgets(
    'profile photos survive refreshes and still honor changes and removal',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bytes = _photo(4, 4);
      Widget avatar(Uint8List value) => MaterialApp(
        home: SafeAttachmentImage(
          bytes: value,
          previewEdge: 128,
          fallback: const Icon(Icons.person_outline),
        ),
      );
      await tester.pumpWidget(avatar(bytes));
      await _finishImageDecodes(tester);
      final decoded = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(decoded, isNotNull);
      for (var refresh = 0; refresh < 3; refresh++) {
        await tester.pumpWidget(avatar(Uint8List.fromList(bytes)));
        expect(find.byIcon(Icons.person_outline), findsNothing);
        expect(
          tester.widget<RawImage>(find.byType(RawImage)).image,
          same(decoded),
        );
      }
      await tester.pumpWidget(avatar(_photo(8, 4)));
      // A different photo must not keep a previous person's bitmap on screen.
      expect(find.byType(RawImage), findsNothing);
      await _finishImageDecodes(tester);
      final updated = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(updated, isNot(same(decoded)));
      expect(updated.width, 8);
      await tester.pumpWidget(avatar(Uint8List.fromList([1, 2, 3])));
      await _finishImageDecodes(tester);
      expect(find.byType(RawImage), findsNothing);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _finishImageDecodes(tester);

      for (final width in [390.0, 1280.0]) {
        await tester.binding.setSurfaceSize(Size(width, 844));
        final bridge = _AvatarBridge()..photo = bytes;
        await tester.pumpWidget(
          SylphyApp(bridge: bridge, profileStore: _AvatarProfileStore()),
        );
        await tester.pumpAndSettle();
        if (width < 900) {
          await tester.tap(
            find.byKey(const ValueKey('conversation-tile-avatar-contact')),
          );
          await tester.pumpAndSettle();
        }
        await _finishImageDecodes(tester);
        final previews = find.descendant(
          of: find.byType(SafeAttachmentImage),
          matching: find.byType(RawImage),
        );
        final previous = tester
            .widgetList<RawImage>(previews)
            .map((widget) => widget.image)
            .toList();
        expect(previous, isNotEmpty);
        for (var refresh = 0; refresh < 3; refresh++) {
          bridge.injectIncoming();
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          expect(
            find.descendant(
              of: find.byType(SafeAttachmentImage),
              matching: find.byIcon(Icons.person_outline),
            ),
            findsNothing,
          );
          expect(
            tester.widgetList<RawImage>(previews).map((widget) => widget.image),
            orderedEquals(previous),
          );
        }
        bridge.photo = null;
        bridge.injectIncoming();
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        expect(find.byType(SafeAttachmentImage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await _finishImageDecodes(tester);
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
}

Uint8List _photo(int width, int height) =>
    Uint8List.fromList(img.encodePng(img.Image(width: width, height: height)));

// Wait for the serialized decoder, pumping the widget test's microtasks between
// engine callbacks instead of assuming that one fixed delay finishes decoding.
Future<void> _finishImageDecodes(WidgetTester tester) async {
  var finished = false;
  Object? failure;
  unawaited(
    decodeAttachmentImage(_photo(1, 1)).then<void>(
      (image) {
        image.dispose();
        finished = true;
      },
      onError: (Object error, StackTrace _) {
        failure = error;
        finished = true;
      },
    ),
  );
  for (var attempt = 0; !finished && attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(finished, isTrue, reason: 'The image decoding queue did not finish');
  expect(failure, isNull);
  await tester.pump();
}

class _AvatarBridge extends Fake
    implements SecureMessagingBridge, InboxRefreshingBridge {
  Uint8List? photo;
  int _revision = 0;
  void injectIncoming() => _revision++;
  @override
  int get inboxRevision => _revision;
  @override
  Future<int> refreshInbox() async => _revision;
  @override
  List<Conversation> listConversations() => [
    Conversation(
      id: 'avatar-contact',
      name: 'Contatto con foto',
      initials: 'CF',
      accentValue: 0xFFA5E5D3,
      lastMessage: 'Messaggio $_revision',
      lastActivity: DateTime(2026, 1, 1, 12, _revision),
      unreadCount: _revision,
      safety: ContactSafety.verified,
      fingerprint: 'TEST',
      avatarBytes: photo == null ? null : Uint8List.fromList(photo!),
    ),
  ];
  @override
  List<ChatMessage> listMessages(String conversationId) => [
    if (_revision > 0)
      ChatMessage(
        id: 'incoming-$_revision',
        authorId: 'avatar-contact',
        body: 'Messaggio $_revision',
        sentAt: DateTime(2026, 1, 1, 12, _revision),
        isOutgoing: false,
      ),
  ];
  @override
  Future<void> markConversationRead(String conversationId) async {}
}

class _AvatarProfileStore extends Fake implements UserProfileStore {
  @override
  Future<UserProfile?> load() async => const UserProfile(displayName: 'Test');
}
