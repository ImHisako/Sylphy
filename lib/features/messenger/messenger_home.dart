import 'package:flutter/material.dart';

import '../../core/messaging/models.dart';
import '../../core/messaging/secure_messaging_bridge.dart';
import '../../core/native/native_core.dart';
import '../../core/identity/identity_service.dart';
import '../../core/profile/user_profile.dart';
import '../../core/veilid/veilid_service.dart';
import '../profile/profile_sheet.dart';

class MessengerHome extends StatefulWidget {
  const MessengerHome({
    super.key,
    required this.bridge,
    required this.veilidService,
    required this.profile,
    required this.identityService,
    required this.onEditProfile,
    this.nativeCore,
  });

  final SecureMessagingBridge bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;
  final UserProfile profile;
  final IdentityService identityService;
  final VoidCallback onEditProfile;

  @override
  State<MessengerHome> createState() => _MessengerHomeState();
}

class _MessengerHomeState extends State<MessengerHome> {
  String? _activeConversationId;

  @override
  void initState() {
    super.initState();
    final conversations = widget.bridge.listConversations();
    _activeConversationId = conversations.isEmpty
        ? null
        : conversations.first.id;
  }

  Future<void> _selectConversation(String conversationId) async {
    try {
      await widget.bridge.markConversationRead(conversationId);
    } on SecureMessagingException {
      // A newly imported contact has no authenticated session yet, but its
      // safety details must remain inspectable from the UI.
    }
    if (!mounted) {
      return;
    }
    setState(() => _activeConversationId = conversationId);
  }

  Future<void> _addContact() async {
    final draft = await showDialog<_ContactDraft>(
      context: context,
      builder: (context) => const _AddContactDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }
    try {
      final contactId = await widget.bridge.addContact(
        displayName: draft.displayName,
        invitationCode: draft.invitationCode,
      );
      if (!mounted) {
        return;
      }
      setState(() => _activeConversationId = contactId);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${draft.displayName} è stato aggiunto. Verifica il fingerprint prima di scrivere.',
          ),
        ),
      );
    } on SecureMessagingException catch (error) {
      if (!mounted) {
        return;
      }
      final message = switch (error.code) {
        'native_core_unavailable' =>
          'Il core nativo non è disponibile: ricompila l’app con ABI 4.',
        'feature_unavailable' =>
          'Lo storage nativo non è ancora pronto. Attendi l’avvio del nodo e riprova.',
        'verification_failed' =>
          'Codice già importato, scaduto oppure firma non valida.',
        'limit_exceeded' => 'Rubrica piena oppure codice troppo grande.',
        _ => 'Codice invito non valido.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  void _openProfile() {
    showProfileSheet(
      context: context,
      profile: widget.profile,
      identityService: widget.identityService,
      onEditProfile: widget.onEditProfile,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final conversations = widget.bridge.listConversations();
        Conversation? activeConversation;
        for (final conversation in conversations) {
          if (conversation.id == _activeConversationId) {
            activeConversation = conversation;
            break;
          }
        }
        activeConversation ??= conversations.isEmpty
            ? null
            : conversations.first;
        if (constraints.maxWidth >= 900) {
          return _DesktopMessenger(
            bridge: widget.bridge,
            nativeCore: widget.nativeCore,
            veilidService: widget.veilidService,
            profile: widget.profile,
            conversations: conversations,
            activeConversation: activeConversation,
            onConversationSelected: _selectConversation,
            onChanged: _refresh,
            onAddContact: _addContact,
            onProfilePressed: _openProfile,
            showDetails: constraints.maxWidth >= 1180,
          );
        }
        return _MobileConversationList(
          bridge: widget.bridge,
          nativeCore: widget.nativeCore,
          veilidService: widget.veilidService,
          profile: widget.profile,
          conversations: conversations,
          onConversationSelected: _selectConversation,
          onChanged: _refresh,
          onAddContact: _addContact,
          onProfilePressed: _openProfile,
        );
      },
    );
  }
}

class _DesktopMessenger extends StatelessWidget {
  const _DesktopMessenger({
    required this.bridge,
    required this.nativeCore,
    required this.veilidService,
    required this.profile,
    required this.conversations,
    required this.activeConversation,
    required this.onConversationSelected,
    required this.onChanged,
    required this.onAddContact,
    required this.onProfilePressed,
    required this.showDetails,
  });

  final SecureMessagingBridge bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;
  final UserProfile profile;
  final List<Conversation> conversations;
  final Conversation? activeConversation;
  final Future<void> Function(String conversationId) onConversationSelected;
  final VoidCallback onChanged;
  final VoidCallback onAddContact;
  final VoidCallback onProfilePressed;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _DesktopAppRail(
              snapshot: veilidService.snapshot,
              profile: profile,
              onAddContact: onAddContact,
              onProfilePressed: onProfilePressed,
              onPrivacyPressed: () =>
                  _showPrivacyOverview(context, nativeCore, veilidService),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 328,
              child: _ConversationSidebar(
                veilidSnapshot: veilidService.snapshot,
                conversations: conversations,
                activeConversationId: activeConversation?.id,
                onConversationSelected: onConversationSelected,
                onAddContact: onAddContact,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: activeConversation == null
                  ? _EmptyInbox(
                      snapshot: veilidService.snapshot,
                      hasNativeCore: nativeCore != null,
                    )
                  : _ChatPane(
                      bridge: bridge,
                      conversation: activeConversation!,
                      onChanged: onChanged,
                      showHeader: true,
                    ),
            ),
            if (showDetails && activeConversation != null) ...[
              const VerticalDivider(width: 1),
              SizedBox(
                width: 292,
                child: _ConversationDetails(
                  conversation: activeConversation!,
                  veilidSnapshot: veilidService.snapshot,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox({
    required this.snapshot,
    required this.hasNativeCore,
    this.compact = false,
  });

  final VeilidSnapshot snapshot;
  final bool hasNativeCore;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 54 : 68,
          height: compact ? 54 : 68,
          decoration: BoxDecoration(
            color: _networkColor(snapshot.phase).withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.mark_chat_unread_outlined,
            size: compact ? 26 : 32,
            color: _networkColor(snapshot.phase),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Nessuna conversazione sicura',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          hasNativeCore
              ? 'Il bridge nativo è attivo. Le conversazioni appariranno solo dopo la creazione del vault e la verifica di un contatto.'
              : 'Installa il core nativo per creare un’identità e collegarti alla rete Veilid.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFAEB7C3), height: 1.4),
        ),
        const SizedBox(height: 12),
        Text(
          snapshot.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _networkColor(snapshot.phase),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );

    if (compact) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: content,
        ),
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF11151B), Color(0xFF0C0F14)],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(padding: const EdgeInsets.all(32), child: content),
        ),
      ),
    );
  }
}

class _DesktopAppRail extends StatelessWidget {
  const _DesktopAppRail({
    required this.snapshot,
    required this.profile,
    required this.onAddContact,
    required this.onProfilePressed,
    required this.onPrivacyPressed,
  });

  final VeilidSnapshot snapshot;
  final UserProfile profile;
  final VoidCallback onAddContact;
  final VoidCallback onProfilePressed;
  final VoidCallback onPrivacyPressed;

  @override
  Widget build(BuildContext context) {
    final networkColor = _networkColor(snapshot.phase);
    return ColoredBox(
      color: const Color(0xFF090C11),
      child: SizedBox(
        width: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
              const SizedBox(height: 30),
              const _RailButton(
                icon: Icons.forum_rounded,
                tooltip: 'Conversazioni',
                selected: true,
              ),
              _RailButton(
                icon: Icons.person_add_alt_1_rounded,
                tooltip: 'Aggiungi contatto',
                onPressed: onAddContact,
              ),
              _RailButton(
                icon: Icons.folder_copy_outlined,
                tooltip: 'File cifrati',
                onPressed: () =>
                    _showNotReadyNotice(context, 'Archivio cifrato'),
              ),
              const Spacer(),
              Tooltip(
                message: snapshot.detail,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: networkColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF090C11),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: networkColor.withValues(alpha: 0.35),
                        blurRadius: 9,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _RailButton(
                icon: Icons.shield_outlined,
                tooltip: 'Privacy e rete',
                onPressed: onPrivacyPressed,
              ),
              const SizedBox(height: 8),
              _ProfileAvatar(
                profile: profile,
                radius: 18,
                onPressed: onProfilePressed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.tooltip,
    this.selected = false,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed ?? () {},
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.primary
              : const Color(0xFF8C96A5),
        ),
        icon: Icon(icon),
      ),
    );
  }
}

class _ConversationSidebar extends StatefulWidget {
  const _ConversationSidebar({
    required this.conversations,
    required this.veilidSnapshot,
    required this.activeConversationId,
    required this.onConversationSelected,
    required this.onAddContact,
  });

  final List<Conversation> conversations;
  final VeilidSnapshot veilidSnapshot;
  final String? activeConversationId;
  final Future<void> Function(String conversationId) onConversationSelected;
  final VoidCallback onAddContact;

  @override
  State<_ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<_ConversationSidebar> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final conversations = widget.conversations
        .where(
          (conversation) =>
              conversation.name.toLowerCase().contains(normalizedQuery) ||
              conversation.lastMessage.toLowerCase().contains(normalizedQuery),
        )
        .toList();
    return ColoredBox(
      color: const Color(0xFF15181E),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 12, 12),
            child: Row(
              children: [
                const Expanded(child: _BrandMark()),
                IconButton(
                  key: const ValueKey('desktop-add-contact'),
                  tooltip: 'Aggiungi contatto',
                  onPressed: widget.onAddContact,
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Cerca conversazioni',
                prefixIcon: Icon(Icons.search_rounded),
                contentPadding: EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 10),
            child: Row(
              children: [
                Text(
                  'CONVERSAZIONI',
                  style: TextStyle(
                    color: Color(0xFF9299A5),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                Spacer(),
                Icon(Icons.tune_rounded, size: 18, color: Color(0xFF9299A5)),
              ],
            ),
          ),
          Expanded(
            child: conversations.isEmpty
                ? const Center(
                    child: Text(
                      'Nessuna conversazione trovata',
                      style: TextStyle(color: Color(0xFF9299A5)),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: conversations.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      return _ConversationTile(
                        conversation: conversation,
                        isSelected:
                            conversation.id == widget.activeConversationId,
                        onTap: () =>
                            widget.onConversationSelected(conversation.id),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: _VaultStatusCard(veilidSnapshot: widget.veilidSnapshot),
          ),
        ],
      ),
    );
  }
}

class _MobileConversationList extends StatelessWidget {
  const _MobileConversationList({
    required this.bridge,
    required this.nativeCore,
    required this.veilidService,
    required this.profile,
    required this.conversations,
    required this.onConversationSelected,
    required this.onChanged,
    required this.onAddContact,
    required this.onProfilePressed,
  });

  final SecureMessagingBridge bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;
  final UserProfile profile;
  final List<Conversation> conversations;
  final Future<void> Function(String conversationId) onConversationSelected;
  final VoidCallback onChanged;
  final VoidCallback onAddContact;
  final VoidCallback onProfilePressed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const _BrandMark(compact: true),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _ProfileAvatar(
              profile: profile,
              radius: 18,
              onPressed: onProfilePressed,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Stato protezione',
            onPressed: () =>
                _showPrivacyOverview(context, nativeCore, veilidService),
            icon: const Icon(Icons.shield_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          itemCount: conversations.isEmpty ? 3 : conversations.length + 2,
          separatorBuilder: (context, index) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _MobileNetworkStatus(
                snapshot: veilidService.snapshot,
                onRetry: veilidService.retry,
              );
            }
            if (index == 1) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(4, 14, 4, 4),
                child: Text(
                  'CONVERSAZIONI',
                  style: TextStyle(
                    color: Color(0xFF9299A5),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              );
            }
            if (conversations.isEmpty) {
              return _EmptyInbox(
                snapshot: veilidService.snapshot,
                hasNativeCore: nativeCore != null,
                compact: true,
              );
            }
            final conversation = conversations[index - 2];
            return _ConversationTile(
              conversation: conversation,
              onTap: () async {
                await onConversationSelected(conversation.id);
                if (!context.mounted) {
                  return;
                }
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (context) => _MobileChatScreen(
                      bridge: bridge,
                      conversationId: conversation.id,
                      onChanged: onChanged,
                    ),
                  ),
                );
                onChanged();
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('mobile-add-contact'),
        onPressed: onAddContact,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        icon: const Icon(Icons.edit_square),
        label: const Text('Aggiungi contatto'),
      ),
    );
  }
}

class _MobileChatScreen extends StatelessWidget {
  const _MobileChatScreen({
    required this.bridge,
    required this.conversationId,
    required this.onChanged,
  });

  final SecureMessagingBridge bridge;
  final String conversationId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final conversation = bridge.listConversations().firstWhere(
      (item) => item.id == conversationId,
    );
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            _ContactAvatar(conversation: conversation, radius: 17),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _presenceLabel(conversation),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9DA5B2),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sicurezza conversazione',
            onPressed: () => _showSecuritySheet(context, conversation),
            icon: const Icon(Icons.verified_user_outlined),
          ),
        ],
      ),
      body: _ChatPane(
        bridge: bridge,
        conversation: conversation,
        onChanged: onChanged,
        showHeader: false,
      ),
    );
  }
}

class _ChatPane extends StatefulWidget {
  const _ChatPane({
    required this.bridge,
    required this.conversation,
    required this.onChanged,
    required this.showHeader,
  });

  final SecureMessagingBridge bridge;
  final Conversation conversation;
  final VoidCallback onChanged;
  final bool showHeader;

  @override
  State<_ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<_ChatPane> {
  final TextEditingController _composerController = TextEditingController();

  @override
  void didUpdateWidget(covariant _ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id) {
      _composerController.clear();
    }
  }

  @override
  void dispose() {
    _composerController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _composerController.text;
    if (text.trim().isEmpty) {
      return;
    }
    try {
      await widget.bridge.sendText(
        conversationId: widget.conversation.id,
        plaintext: text,
      );
    } on SecureMessagingException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Invio bloccato: vault e sessione verificata non disponibili.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    _composerController.clear();
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.bridge.listMessages(widget.conversation.id);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF11151B), Color(0xFF0C0F14)],
        ),
      ),
      child: Column(
        children: [
          if (widget.showHeader) _ChatHeader(conversation: widget.conversation),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
              itemCount: messages.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return const _DaySeparator();
                }
                final message = messages[index - 1];
                return _MessageBubble(message: message);
              },
            ),
          ),
          _Composer(
            controller: _composerController,
            onSend: _sendMessage,
            onAttachmentPressed: () =>
                _showNotReadyNotice(context, 'Allegati cifrati'),
          ),
        ],
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          _ContactAvatar(conversation: conversation, radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _presenceLabel(conversation),
                  style: const TextStyle(
                    color: Color(0xFF9DA5B2),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          _SafetyBadge(safety: conversation.safety),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Sicurezza conversazione',
            onPressed: () => _showSecuritySheet(context, conversation),
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttachmentPressed,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttachmentPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      decoration: BoxDecoration(
        color: const Color(0xFF15181E),
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Allega file',
              onPressed: onAttachmentPressed,
              icon: const Icon(Icons.add_circle_outline_rounded),
              color: const Color(0xFFB5BDC9),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                key: const ValueKey('message-composer'),
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Scrivi un messaggio privato…',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const ValueKey('send-message'),
              tooltip: 'Invia messaggio',
              onPressed: onSend,
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationDetails extends StatelessWidget {
  const _ConversationDetails({
    required this.conversation,
    required this.veilidSnapshot,
  });

  final Conversation conversation;
  final VeilidSnapshot veilidSnapshot;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF15181E),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'DETTAGLI',
              style: TextStyle(
                color: Color(0xFF9299A5),
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: _ContactAvatar(conversation: conversation, radius: 42),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                conversation.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(child: _SafetyBadge(safety: conversation.safety)),
            const SizedBox(height: 30),
            const _DetailLabel('SICUREZZA SESSIONE'),
            const SizedBox(height: 9),
            _InfoCard(
              icon: Icons.key_outlined,
              title: 'Fingerprint',
              subtitle: conversation.fingerprint,
            ),
            const SizedBox(height: 10),
            _InfoCard(
              icon: Icons.hub_outlined,
              title: 'Trasporto',
              subtitle: veilidSnapshot.title,
            ),
            const Spacer(),
            _VaultStatusCard(veilidSnapshot: veilidSnapshot, compact: true),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
    this.isSelected = false,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = isSelected
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
        : Colors.transparent;
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              _ContactAvatar(conversation: conversation, radius: 23),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: conversation.unreadCount > 0
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _relativeTime(conversation.lastActivity),
                          style: const TextStyle(
                            color: Color(0xFF9299A5),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (conversation.safety ==
                            ContactSafety.refreshRequired)
                          const Padding(
                            padding: EdgeInsets.only(right: 5),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 15,
                              color: Color(0xFFFFC56B),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            conversation.lastMessage,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: conversation.unreadCount > 0
                                  ? const Color(0xFFE6E8EB)
                                  : const Color(0xFF9299A5),
                              fontSize: 13,
                              fontWeight: conversation.unreadCount > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (conversation.unreadCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            constraints: const BoxConstraints(minWidth: 20),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${conversation.unreadCount}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final outgoing = message.isOutgoing;
    final background = outgoing
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFF242933);
    final foreground = outgoing
        ? Theme.of(context).colorScheme.onPrimary
        : const Color(0xFFF2F3F5);
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(outgoing ? 18 : 4),
            bottomRight: Radius.circular(outgoing ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              message.body,
              style: TextStyle(color: foreground, fontSize: 15, height: 1.3),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _clockTime(message.sentAt),
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.65),
                    fontSize: 10,
                  ),
                ),
                if (outgoing) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.deliveryState == DeliveryState.read
                        ? Icons.done_all_rounded
                        : Icons.done_rounded,
                    size: 14,
                    color: foreground.withValues(alpha: 0.72),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactAvatar extends StatelessWidget {
  const _ContactAvatar({required this.conversation, required this.radius});

  final Conversation conversation;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: Color(
            conversation.accentValue,
          ).withValues(alpha: 0.22),
          child: Text(
            conversation.initials,
            style: TextStyle(
              color: Color(conversation.accentValue),
              fontSize: radius * 0.48,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (conversation.isOnline)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: radius * 0.48,
              height: radius * 0.48,
              decoration: BoxDecoration(
                color: const Color(0xFF81E6A3),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF15181E), width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class _SafetyBadge extends StatelessWidget {
  const _SafetyBadge({required this.safety});

  final ContactSafety safety;

  @override
  Widget build(BuildContext context) {
    final details = switch (safety) {
      ContactSafety.verified => (
        'Verificato',
        Icons.verified_rounded,
        const Color(0xFF9DE4B6),
      ),
      ContactSafety.pending => (
        'Da verificare',
        Icons.shield_outlined,
        const Color(0xFFFFD27B),
      ),
      ContactSafety.refreshRequired => (
        'Chiave aggiornata',
        Icons.key_rounded,
        const Color(0xFFFFBE7A),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: details.$3.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(details.$2, size: 14, color: details.$3),
          const SizedBox(width: 4),
          Text(
            details.$1,
            style: TextStyle(
              color: details.$3,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Container(
          width: compact ? 32 : 36,
          height: compact ? 32 : 36,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            Icons.auto_awesome_rounded,
            size: compact ? 19 : 22,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'Sylphy',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
      ],
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.profile,
    required this.radius,
    this.onPressed,
  });

  final UserProfile profile;
  final double radius;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: profile.displayName,
      child: InkWell(
        key: const ValueKey('open-profile'),
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: CircleAvatar(
          key: const ValueKey('current-profile-avatar'),
          radius: radius,
          backgroundColor: const Color(0xFF2A313B),
          backgroundImage: profile.photoBytes == null
              ? null
              : MemoryImage(profile.photoBytes!),
          child: profile.photoBytes == null
              ? Text(
                  profile.initials,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: radius * 0.72,
                    fontWeight: FontWeight.w900,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _ContactDraft {
  const _ContactDraft({
    required this.displayName,
    required this.invitationCode,
  });

  final String displayName;
  final String invitationCode;
}

class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _invitationController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _invitationController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    var invitationCode = _invitationController.text.trim();
    if (invitationCode.toLowerCase().startsWith('sylphy:')) {
      invitationCode = invitationCode.substring('sylphy:'.length).trim();
    }
    Navigator.of(context).pop(
      _ContactDraft(
        displayName: _nameController.text.trim(),
        invitationCode: invitationCode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.person_add_alt_1_rounded),
          SizedBox(width: 12),
          Flexible(child: Text('Aggiungi una persona')),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chiedi alla persona il suo codice invito Sylphy. Il core nativo controllerà identità, firme e scadenza prima di aggiungerla.',
                  style: TextStyle(color: Color(0xFFB8C1CC), height: 1.4),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const ValueKey('contact-name'),
                  controller: _nameController,
                  autofocus: true,
                  maxLength: 64,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nome contatto',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Inserisci un nome.'
                      : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const ValueKey('contact-invitation-code'),
                  controller: _invitationController,
                  minLines: 3,
                  maxLines: 6,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Codice invito',
                    hintText: 'sylphy:…',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.qr_code_2_rounded),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Incolla il codice invito.'
                      : null,
                ),
                const SizedBox(height: 12),
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: Color(0xFFCFF36A),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Il contatto resterà in attesa finché non confronterai il fingerprint di sicurezza.',
                        style: TextStyle(
                          color: Color(0xFF9299A5),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        FilledButton.icon(
          key: const ValueKey('confirm-add-contact'),
          onPressed: _submit,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Aggiungi'),
        ),
      ],
    );
  }
}

class _VaultStatusCard extends StatelessWidget {
  const _VaultStatusCard({required this.veilidSnapshot, this.compact = false});

  final VeilidSnapshot veilidSnapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2221),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF34463A)),
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 32 : 36,
            height: compact ? 32 : 36,
            decoration: const BoxDecoration(
              color: Color(0xFF2A3D2F),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_rounded,
              color: Color(0xFFA5E5B7),
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  veilidSnapshot.phase == VeilidPhase.unavailable
                      ? 'Core nativo non disponibile'
                      : 'Core di sicurezza',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  veilidSnapshot.phase == VeilidPhase.unavailable
                      ? 'Nessun dato dimostrativo caricato'
                      : 'Bridge Rust + Veilid disponibile',
                  style: const TextStyle(
                    color: Color(0xFFAEB7C3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileNetworkStatus extends StatelessWidget {
  const _MobileNetworkStatus({required this.snapshot, required this.onRetry});

  final VeilidSnapshot snapshot;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2027),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _networkColor(snapshot.phase).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              snapshot.phase == VeilidPhase.connecting
                  ? Icons.sync_rounded
                  : Icons.hub_rounded,
              color: _networkColor(snapshot.phase),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  snapshot.detail,
                  style: const TextStyle(
                    color: Color(0xFFB2BAC5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (snapshot.phase == VeilidPhase.error ||
              snapshot.phase == VeilidPhase.offline)
            IconButton(
              tooltip: 'Riprova',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF20252E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'OGGI',
          style: TextStyle(
            color: Color(0xFFAEB7C3),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

class _DetailLabel extends StatelessWidget {
  const _DetailLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: Color(0xFF9299A5),
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF1D222A),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFB8C1CC), size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFAEB7C3),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _presenceLabel(Conversation conversation) {
  if (conversation.isOnline) {
    return 'Online · sessione verificata';
  }
  if (conversation.safety == ContactSafety.refreshRequired) {
    return 'Verifica la nuova chiave';
  }
  if (conversation.isGroup) {
    return 'Gruppo protetto';
  }
  return 'Ultima attività ${_relativeTime(conversation.lastActivity)}';
}

String _relativeTime(DateTime value) {
  final difference = DateTime.now().difference(value);
  if (difference.inMinutes < 1) {
    return 'ora';
  }
  if (difference.inMinutes < 60) {
    return '${difference.inMinutes} min';
  }
  if (difference.inHours < 24) {
    return '${difference.inHours} h';
  }
  return '${value.day}/${value.month}';
}

String _clockTime(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

void _showNotReadyNotice(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        '$feature: disponibile quando il bridge nativo è collegato.',
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

void _showPrivacyOverview(
  BuildContext context,
  NativeCoreApi? nativeCore,
  VeilidService veilidService,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1E25),
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.86,
      ),
      child: _PrivacyOverviewSheet(
        nativeCore: nativeCore,
        veilidService: veilidService,
      ),
    ),
  );
}

class _PrivacyOverviewSheet extends StatefulWidget {
  const _PrivacyOverviewSheet({
    required this.nativeCore,
    required this.veilidService,
  });

  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;

  @override
  State<_PrivacyOverviewSheet> createState() => _PrivacyOverviewSheetState();
}

class _PrivacyOverviewSheetState extends State<_PrivacyOverviewSheet> {
  NativeCoreResponse? _response;
  bool _isChecking = false;

  Future<void> _checkNativeCore() async {
    final nativeCore = widget.nativeCore;
    if (nativeCore == null) {
      return;
    }
    setState(() => _isChecking = true);
    try {
      final hybridResponse = nativeCore.verifyHybridPrimitives();
      final response = hybridResponse.ok
          ? nativeCore.verifyDoubleRatchet()
          : hybridResponse;
      if (mounted) {
        setState(() => _response = response);
      }
    } on NativeCoreException {
      if (mounted) {
        setState(
          () => _response = const NativeCoreResponse(
            ok: false,
            code: 'core_unavailable',
            data: {},
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final coreLoaded = widget.nativeCore != null;
    final resultText = _response == null
        ? null
        : _response!.ok
        ? 'Profilo ibrido e Double Ratchet verificati'
        : 'Verifica non riuscita: ${_response!.code}';
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Privacy di Sylphy',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                coreLoaded
                    ? 'Il bridge Rust è caricato. Il nodo Veilid usa storage isolato e accetta soltanto envelope applicativi opachi.'
                    : 'La libreria Rust non è disponibile. Sylphy resta chiuso e non mostra conversazioni dimostrative.',
                style: const TextStyle(color: Color(0xFFC1C8D2), height: 1.45),
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: widget.veilidService,
                builder: (context, _) {
                  final snapshot = widget.veilidService.snapshot;
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141920),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF303741)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.hub_rounded,
                          color: _networkColor(snapshot.phase),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                snapshot.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                snapshot.detail,
                                style: const TextStyle(
                                  color: Color(0xFFAEB7C3),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (snapshot.phase == VeilidPhase.error ||
                            snapshot.phase == VeilidPhase.offline)
                          IconButton(
                            tooltip: 'Riprova connessione',
                            onPressed: widget.veilidService.retry,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 18),
              const _PrivacyLine(
                Icons.lock_outline_rounded,
                'Vault Argon2id + XChaCha20-Poly1305',
              ),
              const SizedBox(height: 12),
              const _PrivacyLine(
                Icons.key_outlined,
                'X25519 + ML-KEM-768 nel core nativo',
              ),
              const SizedBox(height: 12),
              const _PrivacyLine(
                Icons.sync_lock_rounded,
                'Double Ratchet Signal con chiavi per messaggio',
              ),
              const SizedBox(height: 12),
              const _PrivacyLine(
                Icons.hub_outlined,
                'Envelope opachi per il trasporto',
              ),
              if (coreLoaded) ...[
                const SizedBox(height: 22),
                OutlinedButton.icon(
                  onPressed: _isChecking ? null : _checkNativeCore,
                  icon: _isChecking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  label: const Text('Verifica crittografia'),
                ),
                if (resultText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    resultText,
                    style: TextStyle(
                      color: _response!.ok
                          ? const Color(0xFF9DE4B6)
                          : const Color(0xFFFFBE7A),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void _showSecuritySheet(BuildContext context, Conversation conversation) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1E25),
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sicurezza con ${conversation.name}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            _SafetyBadge(safety: conversation.safety),
            const SizedBox(height: 20),
            const Text(
              'FINGERPRINT',
              style: TextStyle(
                color: Color(0xFF9299A5),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 7),
            SelectableText(
              conversation.fingerprint,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Il bridge di produzione deve verificare l’identità, inizializzare la sessione ibrida e cifrare l’envelope prima dell’invio.',
              style: TextStyle(color: Color(0xFFC1C8D2), height: 1.45),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PrivacyLine extends StatelessWidget {
  const _PrivacyLine(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 4),
        Icon(icon, size: 19, color: Color(0xFFD4F66A)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

Color _networkColor(VeilidPhase phase) => switch (phase) {
  VeilidPhase.attached => const Color(0xFF8CE6AC),
  VeilidPhase.connecting => const Color(0xFFCFF36A),
  VeilidPhase.degraded => const Color(0xFFFFC56B),
  VeilidPhase.offline => const Color(0xFF95A0AF),
  VeilidPhase.unavailable => const Color(0xFF77818F),
  VeilidPhase.error => const Color(0xFFFF8F86),
};
