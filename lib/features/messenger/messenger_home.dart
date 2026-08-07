import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:emojis/emoji.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/messaging/models.dart';
import '../../core/messaging/secure_messaging_bridge.dart';
import '../../core/native/native_core.dart';
import '../../core/identity/identity_service.dart';
import '../../core/profile/user_profile.dart';
import '../../core/privacy/privacy_settings.dart';
import '../../core/platform/message_notifications.dart';
import '../../core/platform/attachment_downloads.dart';
import '../../core/veilid/veilid_service.dart';
import '../profile/profile_sheet.dart';
import '../settings/settings_page.dart';

class MessengerHome extends StatefulWidget {
  const MessengerHome({
    super.key,
    required this.bridge,
    required this.veilidService,
    required this.profile,
    required this.identityService,
    required this.privacySettings,
    required this.onEditProfile,
    required this.servicesReady,
    required this.servicesGeneration,
    required this.onAccountImported,
    this.nativeCore,
  });

  final SecureMessagingBridge bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;
  final UserProfile profile;
  final IdentityService identityService;
  final PrivacySettingsController privacySettings;
  final VoidCallback onEditProfile;
  final bool servicesReady;
  final int servicesGeneration;
  final ValueChanged<UserProfile> onAccountImported;

  @override
  State<MessengerHome> createState() => _MessengerHomeState();
}

class _MessengerHomeState extends State<MessengerHome>
    with WidgetsBindingObserver {
  String? _activeConversationId;
  Timer? _inboxTimer;
  List<Conversation> _conversations = const [];
  String _conversationSignature = '';
  Map<String, int> _unreadCounts = const {};
  bool _isRefreshingInbox = false;
  bool _forceRefreshAfterCurrent = false;
  int _lastInboxRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.identityService.addListener(_onIdentityChanged);
    _conversations = _readConversations();
    _conversationSignature = _signatureForConversations(_conversations);
    _unreadCounts = {
      for (final conversation in _conversations)
        conversation.id: conversation.unreadCount,
    };
    _activeConversationId = _conversations.isEmpty
        ? null
        : _conversations.first.id;
    final bridge = widget.bridge;
    if (bridge is InboxRefreshingBridge) {
      _lastInboxRevision = (bridge as InboxRefreshingBridge).inboxRevision;
    }
    _inboxTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshInbox(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshInbox(force: true));
    });
  }

  @override
  void didUpdateWidget(covariant MessengerHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityService != widget.identityService) {
      oldWidget.identityService.removeListener(_onIdentityChanged);
      widget.identityService.addListener(_onIdentityChanged);
    }
    if ((!oldWidget.servicesReady && widget.servicesReady) ||
        oldWidget.servicesGeneration != widget.servicesGeneration) {
      unawaited(_refreshInbox(force: true));
    }
  }

  void _onIdentityChanged() {
    if (widget.identityService.snapshot.phase == IdentityPhase.ready) {
      unawaited(_refreshInbox(force: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshInbox(force: true));
    }
  }

  List<Conversation> _readConversations() {
    try {
      return widget.bridge.listConversations();
    } on Object {
      return _conversations;
    }
  }

  Future<void> _refreshInbox({bool force = false}) async {
    if (!mounted) return;
    if (_isRefreshingInbox) {
      _forceRefreshAfterCurrent |= force;
      return;
    }
    _isRefreshingInbox = true;
    var revisionChanged = false;
    try {
      final bridge = widget.bridge;
      if (bridge is InboxRefreshingBridge) {
        final revision = await (bridge as InboxRefreshingBridge).refreshInbox();
        revisionChanged = revision != _lastInboxRevision;
        _lastInboxRevision = revision;
      }
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'inbox_refresh_failed',
        error: error,
      );
    } finally {
      _isRefreshingInbox = false;
      if (_forceRefreshAfterCurrent) {
        _forceRefreshAfterCurrent = false;
        scheduleMicrotask(() => _refreshInbox(force: true));
      }
    }
    if (!mounted) return;
    if (!force && !revisionChanged) return;
    final conversations = _readConversations();
    final signature = _signatureForConversations(conversations);
    if (!force && signature == _conversationSignature) return;
    final hasNewMessage = conversations.any(
      (conversation) =>
          conversation.unreadCount > (_unreadCounts[conversation.id] ?? 0),
    );
    if (hasNewMessage) {
      unawaited(const MessageNotifications().showIncomingMessage());
    }
    setState(() {
      _conversations = conversations;
      _conversationSignature = signature;
      _unreadCounts = {
        for (final conversation in conversations)
          conversation.id: conversation.unreadCount,
      };
      if (_activeConversationId != null &&
          !conversations.any((item) => item.id == _activeConversationId)) {
        _activeConversationId = conversations.isEmpty
            ? null
            : conversations.first.id;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.identityService.removeListener(_onIdentityChanged);
    _inboxTimer?.cancel();
    super.dispose();
  }

  Future<void> _selectConversation(String conversationId) async {
    AppLog.instance.record(
      category: 'messenger',
      action: 'conversation_selected',
      verbose: true,
    );
    try {
      await widget.bridge.markConversationRead(conversationId);
    } on Object catch (error) {
      // A newly imported contact has no authenticated session yet, but its
      // safety details must remain inspectable from the UI.
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'mark_read_failed',
        error: error,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() => _activeConversationId = conversationId);
    unawaited(_refreshInbox(force: true));
  }

  Future<void> _addContact() async {
    AppLog.instance.record(
      category: 'contacts',
      action: 'add_dialog_opened',
      verbose: true,
    );
    final draft = await showDialog<_ContactDraft>(
      context: context,
      builder: (context) => const _AddContactDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }
    try {
      final contactId = await widget.bridge.addContact(
        // The signed public profile is authoritative. The empty legacy field
        // keeps the Dart/native ABI compatible with older cores.
        displayName: '',
        invitationCode: draft.invitationCode,
      );
      if (!mounted) {
        return;
      }
      await _refreshInbox(force: true);
      if (!mounted) return;
      setState(() => _activeConversationId = contactId);
      AppLog.instance.record(
        category: 'contacts',
        action: 'contact_added',
        verbose: true,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Persona aggiunta con il nome del suo profilo Sylphy. Puoi scrivere subito; la verifica del fingerprint è facoltativa.',
          ),
        ),
      );
    } on SecureMessagingException catch (error) {
      AppLog.instance.record(
        category: 'contacts',
        action: 'contact_add_failed',
        level: AppLogLevel.warning,
        result: error.code,
        force: true,
      );
      if (!mounted) {
        return;
      }
      final message = switch (error.code) {
        'native_core_unavailable' =>
          'Il core nativo non è disponibile: ricompila l’app con ABI 8.',
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

  void _refresh() => unawaited(_refreshInbox(force: true));

  void _openProfile() {
    AppLog.instance.record(
      category: 'profile',
      action: 'sheet_opened',
      verbose: true,
    );
    showProfileSheet(
      context: context,
      profile: widget.profile,
      identityService: widget.identityService,
      onEditProfile: widget.onEditProfile,
    );
  }

  void _openSettings() {
    AppLog.instance.record(
      category: 'settings',
      action: 'opened',
      verbose: true,
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/settings'),
        builder: (context) => SettingsPage(
          nativeCore: widget.nativeCore,
          veilidService: widget.veilidService,
          privacySettings: widget.privacySettings,
          profile: widget.profile,
          onAccountImported: widget.onAccountImported,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final conversations = _conversations;
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
            onSettingsPressed: _openSettings,
            privacySettings: widget.privacySettings,
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
          onSettingsPressed: _openSettings,
          privacySettings: widget.privacySettings,
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
    required this.onSettingsPressed,
    required this.privacySettings,
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
  final VoidCallback onSettingsPressed;
  final PrivacySettingsController privacySettings;
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
              onSettingsPressed: onSettingsPressed,
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
                      privacySettings: privacySettings,
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
    required this.onSettingsPressed,
  });

  final VeilidSnapshot snapshot;
  final UserProfile profile;
  final VoidCallback onAddContact;
  final VoidCallback onProfilePressed;
  final VoidCallback onPrivacyPressed;
  final VoidCallback onSettingsPressed;

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
              _RailButton(
                key: const ValueKey('open-settings'),
                icon: Icons.settings_outlined,
                tooltip: 'Impostazioni',
                onPressed: onSettingsPressed,
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
    super.key,
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
    required this.onSettingsPressed,
    required this.privacySettings,
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
  final VoidCallback onSettingsPressed;
  final PrivacySettingsController privacySettings;

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
          IconButton(
            key: const ValueKey('open-settings'),
            tooltip: 'Impostazioni',
            onPressed: onSettingsPressed,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
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
                      privacySettings: privacySettings,
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
    required this.privacySettings,
  });

  final SecureMessagingBridge bridge;
  final String conversationId;
  final VoidCallback onChanged;
  final PrivacySettingsController privacySettings;

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
            onPressed: () =>
                _showSecuritySheet(context, conversation, bridge, onChanged),
            icon: const Icon(Icons.verified_user_outlined),
          ),
          IconButton(
            key: const ValueKey('delete-conversation-mobile'),
            tooltip: 'Cancella chat',
            onPressed: () async {
              final deleted = await _confirmDeleteConversation(
                context,
                bridge,
                conversation,
              );
              if (deleted && context.mounted) {
                Navigator.of(context).pop();
                onChanged();
              }
            },
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: _ChatPane(
        bridge: bridge,
        conversation: conversation,
        onChanged: onChanged,
        showHeader: false,
        privacySettings: privacySettings,
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
    required this.privacySettings,
  });

  final SecureMessagingBridge bridge;
  final Conversation conversation;
  final VoidCallback onChanged;
  final bool showHeader;
  final PrivacySettingsController privacySettings;

  @override
  State<_ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<_ChatPane> {
  final TextEditingController _composerController = TextEditingController();
  Timer? _messageTimer;
  List<ChatMessage> _messages = const [];
  String _messageSignature = '';
  bool _isSendingAttachment = false;
  final List<ChatMessage> _optimisticMessages = [];
  String? _lastAcknowledgedIncomingId;
  int _lastInboxRevision = 0;
  bool _isRefreshingMessages = false;

  @override
  void initState() {
    super.initState();
    _reloadMessages(force: true);
    final bridge = widget.bridge;
    if (bridge is InboxRefreshingBridge) {
      _lastInboxRevision = (bridge as InboxRefreshingBridge).inboxRevision;
      if (!widget.showHeader) {
        _messageTimer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => _refreshMessagesFromNetwork(),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant _ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id) {
      _composerController.clear();
      _messages = const [];
      _optimisticMessages.clear();
      _messageSignature = '';
      _lastAcknowledgedIncomingId = null;
      _reloadMessages(force: true);
    } else if (oldWidget.conversation.lastActivity !=
            widget.conversation.lastActivity ||
        oldWidget.conversation.unreadCount != widget.conversation.unreadCount ||
        oldWidget.conversation.lastMessage != widget.conversation.lastMessage) {
      _reloadMessages(force: true);
    }
  }

  Future<void> _refreshMessagesFromNetwork() async {
    if (!mounted || _isRefreshingMessages) return;
    final bridge = widget.bridge;
    if (bridge is! InboxRefreshingBridge) return;
    _isRefreshingMessages = true;
    try {
      final revision = await (bridge as InboxRefreshingBridge).refreshInbox();
      if (!mounted || revision == _lastInboxRevision) return;
      _lastInboxRevision = revision;
      _reloadMessages(force: true);
      widget.onChanged();
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'message_refresh_failed',
        error: error,
      );
    } finally {
      _isRefreshingMessages = false;
    }
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _composerController.dispose();
    super.dispose();
  }

  void _reloadMessages({bool force = false}) {
    if (!mounted) return;
    List<ChatMessage> messages;
    try {
      messages = widget.bridge.listMessages(widget.conversation.id);
    } on Object {
      return;
    }
    final signature = _signatureForMessages(messages);
    if (!force && signature == _messageSignature) return;
    setState(() {
      _messages = messages;
      _messageSignature = signature;
    });
    String? latestIncomingId;
    for (final message in messages.reversed) {
      if (!message.isOutgoing) {
        latestIncomingId = message.id;
        break;
      }
    }
    if (latestIncomingId != null &&
        latestIncomingId != _lastAcknowledgedIncomingId) {
      _lastAcknowledgedIncomingId = latestIncomingId;
      unawaited(_markConversationReadSafely());
    }
  }

  Future<void> _markConversationReadSafely() async {
    try {
      await widget.bridge.markConversationRead(widget.conversation.id);
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'mark_read_failed',
        error: error,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _composerController.text.trim();
    if (text.isEmpty) {
      return;
    }
    final conversationId = widget.conversation.id;
    _composerController.clear();
    final optimistic = ChatMessage(
      id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      authorId: 'me',
      body: text,
      sentAt: DateTime.now(),
      isOutgoing: true,
      deliveryState: DeliveryState.sent,
    );
    setState(() => _optimisticMessages.add(optimistic));
    AppLog.instance.record(
      category: 'messenger',
      action: 'send_requested',
      verbose: true,
    );
    try {
      await widget.bridge.sendText(
        conversationId: conversationId,
        plaintext: text,
      );
    } on Object catch (error) {
      final code = error is SecureMessagingException
          ? error.code
          : 'native_call_failed';
      AppLog.instance.record(
        category: 'messenger',
        action: 'send_blocked',
        level: AppLogLevel.warning,
        result: code,
        force: true,
      );
      if (mounted) {
        setState(() => _optimisticMessages.remove(optimistic));
        if (widget.conversation.id == conversationId) {
          _composerController.text = text;
          _composerController.selection = TextSelection.collapsed(
            offset: _composerController.text.length,
          );
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (code) {
              'network_attach_failed' || 'network_startup_failed' =>
                'Invio non riuscito: il destinatario non è raggiungibile.',
              'feature_unavailable' =>
                'Questo contatto usa un vecchio ID. Chiedi il nuovo ID Sylphy breve.',
              'limit_exceeded' =>
                'Il messaggio è troppo lungo per l’invio sicuro. Accorcialo e riprova.',
              _ => 'Invio sicuro non riuscito ($code).',
            }),
          ),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _optimisticMessages.remove(optimistic));
    if (widget.conversation.id == conversationId) {
      _reloadMessages(force: true);
    }
    widget.onChanged();
    AppLog.instance.record(
      category: 'messenger',
      action: 'send_completed',
      verbose: true,
    );
  }

  Future<void> _pickAndSendAttachment() async {
    if (_isSendingAttachment) return;
    final conversationId = widget.conversation.id;
    final file = await openFile();
    if (file == null || !mounted) return;
    final size = await file.length();
    if (!mounted) return;
    if (widget.conversation.id != conversationId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'La conversazione è cambiata: seleziona nuovamente l’allegato.',
          ),
        ),
      );
      return;
    }
    if (size <= 0 || size > 700 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Il file deve avere una dimensione massima di 700 KB.',
            ),
          ),
        );
      }
      return;
    }
    setState(() => _isSendingAttachment = true);
    try {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await widget.bridge.sendAttachment(
        conversationId: conversationId,
        fileName: file.name,
        bytes: bytes,
      );
      if (!mounted) return;
      _reloadMessages(force: true);
      widget.onChanged();
    } on Object catch (error) {
      final code = error is SecureMessagingException
          ? error.code
          : 'native_call_failed';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              code == 'limit_exceeded'
                  ? 'Allegato troppo grande per l’archivio cifrato.'
                  : 'Invio dell’allegato non riuscito ($code).',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSendingAttachment = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleMessages = [..._messages, ..._optimisticMessages]
      ..sort((left, right) => left.sentAt.compareTo(right.sentAt));
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
          if (widget.showHeader)
            _ChatHeader(
              conversation: widget.conversation,
              bridge: widget.bridge,
              onChanged: widget.onChanged,
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
              itemCount: visibleMessages.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return const _DaySeparator();
                }
                final message = visibleMessages[index - 1];
                return _MessageBubble(
                  message: message,
                  showReceipt: widget.privacySettings.value.showReadReceipts,
                );
              },
            ),
          ),
          _Composer(
            controller: _composerController,
            onSend: _sendMessage,
            isSendingAttachment: _isSendingAttachment,
            onAttachmentPressed: _pickAndSendAttachment,
          ),
        ],
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.conversation,
    required this.bridge,
    required this.onChanged,
  });

  final Conversation conversation;
  final SecureMessagingBridge bridge;
  final VoidCallback onChanged;

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
          PopupMenuButton<String>(
            key: const ValueKey('conversation-menu'),
            tooltip: 'Azioni conversazione',
            onSelected: (value) async {
              if (value == 'security') {
                await _showSecuritySheet(
                  context,
                  conversation,
                  bridge,
                  onChanged,
                );
              } else if (value == 'delete') {
                final deleted = await _confirmDeleteConversation(
                  context,
                  bridge,
                  conversation,
                );
                if (deleted) {
                  onChanged();
                }
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'security',
                child: ListTile(
                  leading: Icon(Icons.verified_user_outlined),
                  title: Text('Sicurezza'),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline_rounded),
                  title: Text('Cancella chat'),
                ),
              ),
            ],
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }
}

enum _EmojiCategory {
  recent('Recenti', Icons.access_time_rounded),
  smileys(
    'Faccine ed emozioni',
    Icons.emoji_emotions_outlined,
    EmojiGroup.smileysEmotion,
  ),
  people('Persone', Icons.people_alt_outlined, EmojiGroup.peopleBody),
  animals('Animali e natura', Icons.pets_outlined, EmojiGroup.animalsNature),
  food('Cibo e bevande', Icons.restaurant_outlined, EmojiGroup.foodDrink),
  travel(
    'Viaggi e luoghi',
    Icons.directions_car_outlined,
    EmojiGroup.travelPlaces,
  ),
  activities('Attività', Icons.sports_soccer_outlined, EmojiGroup.activities),
  objects('Oggetti', Icons.lightbulb_outline_rounded, EmojiGroup.objects),
  symbols('Simboli', Icons.tag_rounded, EmojiGroup.symbols),
  flags('Bandiere', Icons.flag_outlined, EmojiGroup.flags);

  const _EmojiCategory(this.label, this.icon, [this.group]);

  final String label;
  final IconData icon;
  final EmojiGroup? group;
}

class _EmojiCategoryPicker extends StatefulWidget {
  const _EmojiCategoryPicker({
    required this.recentEmoji,
    required this.onSelected,
  });

  final List<Emoji> recentEmoji;
  final ValueChanged<Emoji> onSelected;

  @override
  State<_EmojiCategoryPicker> createState() => _EmojiCategoryPickerState();
}

class _EmojiCategoryPickerState extends State<_EmojiCategoryPicker> {
  static final Map<EmojiGroup, List<Emoji>> _emojiByGroup = {};

  late _EmojiCategory _selected = widget.recentEmoji.isEmpty
      ? _EmojiCategory.smileys
      : _EmojiCategory.recent;

  List<Emoji> get _visibleEmoji {
    final group = _selected.group;
    return group == null
        ? widget.recentEmoji
        : _emojiByGroup.putIfAbsent(
            group,
            () => Emoji.byGroup(group).toList(growable: false),
          );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final emoji = _visibleEmoji;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            scrollDirection: Axis.horizontal,
            children: [
              for (final category in _EmojiCategory.values)
                Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: category == _selected
                            ? colorScheme.primary
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Tooltip(
                    message: category.label,
                    child: IconButton(
                      key: ValueKey('emoji-category-${category.name}'),
                      isSelected: category == _selected,
                      color: colorScheme.onSurfaceVariant,
                      selectedIcon: Icon(
                        category.icon,
                        color: colorScheme.primary,
                      ),
                      icon: Icon(category.icon),
                      onPressed: () => setState(() => _selected = category),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(
            _selected.label,
            key: const ValueKey('emoji-category-title'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: emoji.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Le emoji usate di recente appariranno qui.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 54,
                  ),
                  itemCount: emoji.length,
                  itemBuilder: (context, index) {
                    final item = emoji[index];
                    return Tooltip(
                      message: item.name,
                      child: TextButton(
                        key: ValueKey('emoji-${item.char}'),
                        onPressed: () => widget.onSelected(item),
                        child: Text(
                          item.char,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttachmentPressed,
    required this.isSendingAttachment,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttachmentPressed;
  final bool isSendingAttachment;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final List<Emoji> _recentEmoji = [];

  static const _kaomoji = <String>[
    '(＾▽＾)',
    '(づ｡◕‿‿◕｡)づ',
    '¯\\_(ツ)_/¯',
    '(ง •̀_•́)ง',
    '(｡♥‿♥｡)',
    '(≧▽≦)',
    '(￣▽￣)ノ',
    '(；一_一)',
    '(╥﹏╥)',
    '(ノಠ益ಠ)ノ彡┻━┻',
    '┬─┬ノ( º _ ºノ)',
    '(☞ﾟヮﾟ)☞',
    'ฅ^•ﻌ•^ฅ',
    'ʕ•ᴥ•ʔ',
    '(•̀ᴗ•́)و ̑̑',
    '٩(◕‿◕｡)۶',
    '(っ˘ω˘ς )',
    'ヽ(・∀・)ﾉ',
  ];

  void _insert(String value) {
    final controller = widget.controller;
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : controller.text.length;
    controller.value = controller.value.copyWith(
      text: controller.text.replaceRange(start, end, value),
      selection: TextSelection.collapsed(offset: start + value.length),
      composing: TextRange.empty,
    );
  }

  void _selectEmoji(BuildContext sheetContext, Emoji emoji) {
    setState(() {
      _recentEmoji.removeWhere((item) => item.char == emoji.char);
      _recentEmoji.insert(0, emoji);
      if (_recentEmoji.length > 32) {
        _recentEmoji.removeLast();
      }
    });
    _insert(emoji.char);
    Navigator.pop(sheetContext);
  }

  Future<void> _showExpressions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DefaultTabController(
        length: 2,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 390,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Emoji'),
                    Tab(text: 'Kaomoji'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _EmojiCategoryPicker(
                        recentEmoji: List.unmodifiable(_recentEmoji),
                        onSelected: (emoji) =>
                            _selectEmoji(sheetContext, emoji),
                      ),
                      ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _kaomoji.length,
                        itemBuilder: (context, index) => ListTile(
                          dense: true,
                          title: Text(_kaomoji[index]),
                          onTap: () {
                            _insert(_kaomoji[index]);
                            Navigator.pop(sheetContext);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(6, 6, 6, 8)
          : const EdgeInsets.fromLTRB(16, 12, 16, 18),
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
              visualDensity: compact ? VisualDensity.compact : null,
              onPressed: widget.isSendingAttachment
                  ? null
                  : widget.onAttachmentPressed,
              icon: widget.isSendingAttachment
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_circle_outline_rounded),
              color: const Color(0xFFB5BDC9),
            ),
            IconButton(
              key: const ValueKey('open-expression-picker'),
              tooltip: 'Emoji e kaomoji',
              visualDensity: compact ? VisualDensity.compact : null,
              onPressed: _showExpressions,
              icon: const Icon(Icons.emoji_emotions_outlined),
              color: const Color(0xFFB5BDC9),
            ),
            SizedBox(width: compact ? 1 : 4),
            Expanded(
              child: TextField(
                key: const ValueKey('message-composer'),
                controller: widget.controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: _usesDesktopKeyboard
                    ? TextInputAction.send
                    : TextInputAction.newline,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: _usesDesktopKeyboard
                    ? (_) => widget.onSend()
                    : null,
                decoration: InputDecoration(
                  hintText: 'Scrivi un messaggio privato…',
                  isDense: compact,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: compact ? 12 : 16,
                    vertical: compact ? 9 : 12,
                  ),
                ),
              ),
            ),
            SizedBox(width: compact ? 4 : 8),
            IconButton.filled(
              key: const ValueKey('send-message'),
              tooltip: 'Invia messaggio',
              visualDensity: compact ? VisualDensity.compact : null,
              onPressed: widget.onSend,
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
  const _MessageBubble({required this.message, required this.showReceipt});

  final ChatMessage message;
  final bool showReceipt;

  bool get _isImageAttachment {
    final name = message.attachmentName?.toLowerCase();
    return name != null &&
        (name.endsWith('.jpg') ||
            name.endsWith('.jpeg') ||
            name.endsWith('.png') ||
            name.endsWith('.webp') ||
            name.endsWith('.gif') ||
            name.endsWith('.bmp'));
  }

  Future<void> _downloadAttachment(BuildContext context) async {
    final bytes = message.attachmentBytes;
    final name = message.attachmentName;
    if (bytes == null || name == null) return;
    try {
      final location = await const AttachmentDownloads().save(
        fileName: name,
        bytes: bytes,
      );
      if (!context.mounted || location == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('File salvato: $location')));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Non è stato possibile salvare il file.')),
      );
    }
  }

  void _showImage(BuildContext context) {
    final bytes = message.attachmentBytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0C0F14),
        insetPadding: const EdgeInsets.all(20),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined, size: 48),
                        SizedBox(height: 12),
                        Text('Impossibile visualizzare questa immagine.'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 6,
              child: IconButton.filledTonal(
                tooltip: 'Chiudi',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
            if (message.attachmentName case final fileName?)
              Container(
                constraints: const BoxConstraints(minWidth: 210),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isImageAttachment &&
                        message.attachmentBytes != null) ...[
                      GestureDetector(
                        onTap: () => _showImage(context),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: Image.memory(
                            message.attachmentBytes!,
                            width: 300,
                            height: 220,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => SizedBox(
                              width: 300,
                              height: 120,
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: foreground,
                                size: 42,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isImageAttachment
                              ? Icons.image_rounded
                              : Icons.insert_drive_file_rounded,
                          color: foreground,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fileName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: foreground,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _fileSizeLabel(
                                  message.attachmentBytes?.length ?? 0,
                                ),
                                style: TextStyle(
                                  color: foreground.withValues(alpha: 0.68),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (message.attachmentBytes != null)
                          IconButton(
                            tooltip: 'Scarica file',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _downloadAttachment(context),
                            icon: Icon(
                              Icons.download_rounded,
                              color: foreground,
                            ),
                          ),
                        Icon(Icons.lock_rounded, size: 16, color: foreground),
                      ],
                    ),
                  ],
                ),
              )
            else
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
                if (outgoing && showReceipt) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.deliveryState == DeliveryState.sent
                        ? Icons.done_rounded
                        : Icons.done_all_rounded,
                    size: 14,
                    color: message.deliveryState == DeliveryState.read
                        ? const Color(0xFF2F6FED)
                        : foreground.withValues(alpha: 0.72),
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
          backgroundImage: conversation.avatarBytes == null
              ? null
              : MemoryImage(conversation.avatarBytes!),
          child: conversation.avatarBytes != null
              ? null
              : Text(
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
  const _ContactDraft({required this.invitationCode});

  final String invitationCode;
}

class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _formKey = GlobalKey<FormState>();
  final _invitationController = TextEditingController();

  @override
  void dispose() {
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
    Navigator.of(context).pop(_ContactDraft(invitationCode: invitationCode));
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
                  key: const ValueKey('contact-invitation-code'),
                  controller: _invitationController,
                  autofocus: true,
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
                        'Puoi ricevere e inviare subito. Verifica il fingerprint solo se vuoi contrassegnare questa persona come sicura.',
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

String _fileSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
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

Future<void> _showSecuritySheet(
  BuildContext context,
  Conversation conversation,
  SecureMessagingBridge bridge,
  VoidCallback onChanged,
) {
  return showModalBottomSheet<void>(
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
              'I messaggi sono visibili subito. La verifica è facoltativa e serve a confermare, confrontando il fingerprint fuori da Sylphy, che stai parlando con la persona giusta.',
              style: TextStyle(color: Color(0xFFC1C8D2), height: 1.45),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey('toggle-contact-verification'),
              onPressed: () async {
                try {
                  await bridge.setContactVerified(
                    conversationId: conversation.id,
                    verified: conversation.safety != ContactSafety.verified,
                  );
                  onChanged();
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                } on SecureMessagingException catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Impossibile aggiornare la verifica (${error.code}).',
                        ),
                      ),
                    );
                  }
                }
              },
              icon: Icon(
                conversation.safety == ContactSafety.verified
                    ? Icons.remove_moderator_outlined
                    : Icons.verified_user_outlined,
              ),
              label: Text(
                conversation.safety == ContactSafety.verified
                    ? 'Rimuovi verifica'
                    : 'Segna come verificato',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> _confirmDeleteConversation(
  BuildContext context,
  SecureMessagingBridge bridge,
  Conversation conversation,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Cancellare la chat?'),
      content: Text(
        'Verranno eliminati dal dispositivo la conversazione con ${conversation.name}, i messaggi e il contatto. Questa operazione non cancella le copie sull’altro dispositivo.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const ValueKey('confirm-delete-conversation'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Cancella'),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    return false;
  }
  try {
    await bridge.deleteConversation(conversation.id);
    return true;
  } on SecureMessagingException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cancellazione non riuscita (${error.code}).')),
      );
    }
    return false;
  }
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

bool get _usesDesktopKeyboard =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

String _signatureForConversations(
  List<Conversation> conversations,
) => conversations
    .map(
      (item) =>
          '${item.id}|${item.lastActivity.microsecondsSinceEpoch}|${item.lastMessage}|${item.unreadCount}|${item.safety.name}|${item.isOnline}',
    )
    .join('\n');

String _signatureForMessages(List<ChatMessage> messages) => messages
    .map(
      (item) =>
          '${item.id}|${item.sentAt.microsecondsSinceEpoch}|${item.deliveryState.name}',
    )
    .join('\n');
