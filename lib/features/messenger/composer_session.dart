import 'package:flutter/widgets.dart';

import '../../core/messaging/models.dart';

typedef ComposerDestination = ({String conversationId, String? channelId});

class ComposerDraft {
  const ComposerDraft({this.value = TextEditingValue.empty, this.replyTo});

  final TextEditingValue value;
  final ChatMessage? replyTo;
}

class LocalTextMessage {
  LocalTextMessage({
    required this.destination,
    required this.message,
    this.replyTo,
  });

  final ComposerDestination destination;
  final ChatMessage message;
  final ChatMessage? replyTo;
  bool failed = false;
}

/// Unsaved text belongs to the unlocked account session, never to a route.
/// Nothing here is written to disk or included in diagnostic logs.
class ComposerSession extends ChangeNotifier {
  final _drafts = <ComposerDestination, ComposerDraft>{};
  final _messages = <String, LocalTextMessage>{};
  int _nextId = 0;
  int generation = 0;
  int storedRevision = 0;
  bool _disposed = false;

  ComposerDraft draftFor(ComposerDestination destination) =>
      _drafts[destination] ?? const ComposerDraft();

  void saveDraft(ComposerDestination destination, ComposerDraft draft) {
    if (_disposed) return;
    if (draft.value.text.isEmpty && draft.replyTo == null) {
      _drafts.remove(destination);
    } else {
      _drafts[destination] = draft;
    }
  }

  Iterable<LocalTextMessage> messagesFor(String conversationId) => _messages
      .values
      .where((item) => item.destination.conversationId == conversationId);

  LocalTextMessage? messageFor(String id) => _messages[id];

  bool contains(LocalTextMessage item) =>
      !_disposed && identical(_messages[item.message.id], item);

  LocalTextMessage beginSend(
    ComposerDestination destination,
    String text,
    ChatMessage? replyTo,
  ) {
    final item = LocalTextMessage(
      destination: destination,
      replyTo: replyTo,
      message: ChatMessage(
        id: 'local-send-${_nextId++}',
        authorId: 'me',
        body: text,
        replyTo: replyTo?.id,
        channelId: destination.channelId,
        sentAt: DateTime.now(),
        isOutgoing: true,
        deliveryState: DeliveryState.queued,
      ),
    );
    _messages[item.message.id] = item;
    notifyListeners();
    return item;
  }

  bool retry(LocalTextMessage item) {
    if (!contains(item) || !item.failed) return false;
    item.failed = false;
    notifyListeners();
    return true;
  }

  void fail(LocalTextMessage item) {
    if (!contains(item)) return;
    item.failed = true;
    notifyListeners();
  }

  void remove(LocalTextMessage item, {bool stored = false}) {
    if (!contains(item)) return;
    _messages.remove(item.message.id);
    if (stored) storedRevision++;
    notifyListeners();
  }

  void retainConversations(Iterable<String> ids) {
    final retained = ids.toSet();
    _drafts.removeWhere((key, _) => !retained.contains(key.conversationId));
    final previousCount = _messages.length;
    _messages.removeWhere(
      (_, item) => !retained.contains(item.destination.conversationId),
    );
    if (_messages.length != previousCount) notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    _drafts.clear();
    _messages.clear();
    generation++;
    notifyListeners();
  }

  @override
  void dispose() {
    _drafts.clear();
    _messages.clear();
    _disposed = true;
    super.dispose();
  }
}
