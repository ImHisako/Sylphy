import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/features/messenger/composer_session.dart';

void main() {
  const destination = (conversationId: 'chat', channelId: 'channel');

  test('clearing an account drops drafts and invalidates in-flight sends', () {
    final session = ComposerSession();
    addTearDown(session.dispose);
    session.saveDraft(
      destination,
      const ComposerDraft(value: TextEditingValue(text: 'Bozza privata')),
    );
    final pending = session.beginSend(destination, 'Invio privato', null);
    session.clear();
    // A late completion from the previous account cannot recreate its text.
    session.fail(pending);
    session.remove(pending, stored: true);
    expect(session.draftFor(destination).value.text, isEmpty);
    expect(session.messagesFor('chat'), isEmpty);
    expect(session.contains(pending), isFalse);
    expect(session.storedRevision, 0);
  });

  test('deleting a chat discards only its drafts and failed sends', () {
    final session = ComposerSession();
    addTearDown(session.dispose);
    const retained = (conversationId: 'other', channelId: null);
    for (final target in [destination, retained]) {
      session.saveDraft(
        target,
        const ComposerDraft(value: TextEditingValue(text: 'Bozza')),
      );
      session.fail(session.beginSend(target, 'Invio fallito', null));
    }
    session.retainConversations(['other']);
    expect(session.draftFor(destination).value.text, isEmpty);
    expect(session.messagesFor('chat'), isEmpty);
    expect(session.draftFor(retained).value.text, 'Bozza');
    expect(session.messagesFor('other').single.failed, isTrue);
  });

  test('disposal makes delayed send results harmless', () {
    final session = ComposerSession();
    final pending = session.beginSend(destination, 'Invio', null);
    session.dispose();
    session.fail(pending);
    session.remove(pending, stored: true);
    expect(session.contains(pending), isFalse);
    expect(session.messagesFor('chat'), isEmpty);
  });
}
