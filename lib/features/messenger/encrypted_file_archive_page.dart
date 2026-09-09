import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/messaging/models.dart';
import '../../core/messaging/secure_messaging_bridge.dart';
import '../../core/platform/attachment_downloads.dart';

class EncryptedFileArchivePage extends StatefulWidget {
  const EncryptedFileArchivePage({
    super.key,
    required this.bridge,
    required this.conversations,
  });

  final SecureMessagingBridge bridge;
  final List<Conversation> conversations;

  @override
  State<EncryptedFileArchivePage> createState() =>
      _EncryptedFileArchivePageState();
}

class _EncryptedFileArchivePageState extends State<EncryptedFileArchivePage> {
  List<_ArchivedAttachment> _attachments = const [];
  bool _loading = true;
  bool _partialFailure = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _partialFailure = false;
      });
    }
    final attachments = <_ArchivedAttachment>[];
    var partialFailure = false;
    for (final conversation in widget.conversations) {
      try {
        final messages = await _allMessages(conversation.id);
        for (final message in messages) {
          if (message.attachmentName != null) {
            attachments.add(
              _ArchivedAttachment(
                conversationId: conversation.id,
                conversationName: conversation.name,
                message: message,
              ),
            );
          }
        }
      } on Object {
        partialFailure = true;
      }
    }
    attachments.sort(
      (left, right) => right.message.sentAt.compareTo(left.message.sentAt),
    );
    if (!mounted) return;
    setState(() {
      _attachments = List.unmodifiable(attachments);
      _partialFailure = partialFailure;
      _loading = false;
    });
  }

  Future<List<ChatMessage>> _allMessages(String conversationId) async {
    final bridge = widget.bridge;
    if (bridge is! CachedMessagingBridge) {
      return bridge.listMessages(conversationId);
    }
    var messages = await bridge.refreshMessages(conversationId, priority: true);
    // The native bridge pages old records. Load every page so this is an
    // archive, rather than merely a view of the most recent chat page.
    while (mounted && bridge.hasOlderMessages(conversationId)) {
      final previousLength = messages.length;
      messages = await bridge.loadOlderMessages(conversationId);
      if (messages.length <= previousLength) {
        throw StateError('Archive pagination made no progress');
      }
    }
    return messages;
  }

  Future<void> _save(_ArchivedAttachment attachment) async {
    final bytes = attachment.message.attachmentBytes;
    final name = attachment.message.attachmentName;
    if (bytes == null || name == null) return;
    try {
      final destination = await const AttachmentDownloads().save(
        fileName: name,
        bytes: bytes,
      );
      if (!mounted || destination == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('File salvato: $destination')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Non è stato possibile salvare il file.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('encrypted-files-page'),
      appBar: AppBar(
        title: const Text('File cifrati'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna archivio',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _attachments.isEmpty
          ? _EmptyArchive(partialFailure: _partialFailure)
          : Column(
              children: [
                if (_partialFailure)
                  const MaterialBanner(
                    content: Text(
                      'Alcune conversazioni non sono state lette. Riprova quando il vault è disponibile.',
                    ),
                    actions: [SizedBox.shrink()],
                  ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                    itemCount: _attachments.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final attachment = _attachments[index];
                      final message = attachment.message;
                      final available = message.attachmentBytes != null;
                      return Card(
                        child: ListTile(
                          key: ValueKey(
                            'encrypted-file-${attachment.conversationId}-${message.id}',
                          ),
                          leading: Icon(
                            _fileIcon(message.attachmentName!),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(
                            message.attachmentName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${attachment.conversationName} · ${_dateLabel(message.sentAt)}'
                            '${available ? ' · ${_sizeLabel(message.attachmentBytes!.length)}' : ' · non disponibile offline'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: available
                                ? 'Salva file'
                                : 'File non disponibile',
                            onPressed: available
                                ? () => _save(attachment)
                                : null,
                            icon: const Icon(Icons.download_rounded),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _EmptyArchive extends StatelessWidget {
  const _EmptyArchive({required this.partialFailure});

  final bool partialFailure;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_copy_outlined,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                partialFailure
                    ? 'Archivio temporaneamente non disponibile'
                    : 'Nessun file cifrato',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                partialFailure
                    ? 'Riprova quando il vault nativo ha completato l’avvio.'
                    : 'Gli allegati delle conversazioni appariranno qui.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArchivedAttachment {
  const _ArchivedAttachment({
    required this.conversationId,
    required this.conversationName,
    required this.message,
  });

  final String conversationId;
  final String conversationName;
  final ChatMessage message;
}

IconData _fileIcon(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.gif')) {
    return Icons.image_outlined;
  }
  if (lower.endsWith('.mp4') || lower.endsWith('.webm')) {
    return Icons.movie_outlined;
  }
  if (lower.endsWith('.mp3') || lower.endsWith('.wav')) {
    return Icons.audio_file_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

String _dateLabel(DateTime value) {
  final local = value.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  return '$day/$month/${local.year}';
}

String _sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
