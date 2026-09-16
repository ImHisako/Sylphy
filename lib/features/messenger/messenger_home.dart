import '../../core/privacy/app_palette.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:emojis/emoji.dart';

import '../../core/branding/sylphy_logo.dart';
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
import 'encrypted_file_archive_page.dart';
import 'group_management_page.dart';
import 'message_text.dart';
import 'safe_attachment_image.dart';

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
  int _conversationSelectionRevision = 0;
  Timer? _inboxTimer;
  List<Conversation> _conversations = const [];
  final _conversationUpdates = ValueNotifier<List<Conversation>>([]);
  String _conversationSignature = '';
  bool _storageWarningShown = false;
  Map<String, int> _unreadCounts = const {};
  bool _isRefreshingInbox = false;
  bool _isLoadingConversations = false;
  bool _forceRefreshAfterCurrent = false;
  int _lastInboxRevision = 0;

  bool get _androidBackground =>
      defaultTargetPlatform == TargetPlatform.android &&
      WidgetsBinding.instance.lifecycleState != null &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  void _configureInboxTimer() {
    _inboxTimer?.cancel();
    _inboxTimer = _androidBackground
        ? null
        : Timer.periodic(Duration(seconds: 3), (_) => _refreshInbox());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.identityService.addListener(_onIdentityChanged);
    final cachedBridge = widget.bridge;
    if (cachedBridge is CachedMessagingBridge) {
      _conversations = cachedBridge.cachedConversations ?? [];
      _isLoadingConversations = cachedBridge.cachedConversations == null;
    } else {
      _conversations = _readConversations();
    }
    _conversationSignature = _signatureForConversations(_conversations);
    _conversationUpdates.value = _conversations;
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
    _configureInboxTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialRefresh());
    });
  }

  Future<void> _initialRefresh() async {
    await _loadConversations(force: true);
    if (mounted) await _refreshInbox(force: true);
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
    _configureInboxTimer();
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

  Future<void> _loadConversations({bool force = false}) async {
    List<Conversation> conversations;
    try {
      final bridge = widget.bridge;
      conversations = bridge is CachedMessagingBridge
          ? await bridge.refreshConversations()
          : _readConversations();
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'conversation_load_failed',
        error: error,
      );
      if (mounted && _isLoadingConversations) {
        setState(() => _isLoadingConversations = false);
      }
      return;
    }
    if (!mounted) return;
    final signature = _signatureForConversations(conversations);
    if (!force && signature == _conversationSignature) {
      if (_isLoadingConversations) {
        setState(() => _isLoadingConversations = false);
      }
      return;
    }
    setState(() {
      _conversations = conversations;
      _conversationUpdates.value = conversations;
      _conversationSignature = signature;
      _isLoadingConversations = false;
      _unreadCounts = {
        for (final conversation in conversations)
          conversation.id: conversation.unreadCount,
      };
      if (_activeConversationId == null ||
          !conversations.any((item) => item.id == _activeConversationId)) {
        _activeConversationId = conversations.isEmpty
            ? null
            : conversations.first.id;
      }
    });
  }

  Future<void> _refreshInbox({bool force = false}) async {
    if (!mounted || _androidBackground) return;
    if (_isRefreshingInbox) {
      _forceRefreshAfterCurrent |= force;
      return;
    }
    _isRefreshingInbox = true;
    var revisionChanged = false;
    try {
      final bridge = widget.bridge;
      // A local conversation refresh is still useful while offline, but the
      // native inbox command requires a running Veilid node. Avoid turning an
      // expected offline/startup state into an error every three seconds.
      if (bridge is InboxRefreshingBridge &&
          (widget.nativeCore == null ||
              widget.veilidService.snapshot.isAttached)) {
        final revision = await (bridge as InboxRefreshingBridge).refreshInbox();
        revisionChanged = revision != _lastInboxRevision;
        _lastInboxRevision = revision;
        final storageFull =
            bridge is InboxStorageStatus &&
            (bridge as InboxStorageStatus).inboxStorageFull;
        if (mounted && storageFull && !_storageWarningShown) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Archivio dei messaggi pieno. Libera spazio per riprendere la ricezione; i messaggi in attesa non sono stati scartati.',
              ),
            ),
          );
        }
        _storageWarningShown = storageFull;
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
    List<Conversation> conversations;
    try {
      final bridge = widget.bridge;
      conversations = bridge is CachedMessagingBridge
          ? await bridge.refreshConversations()
          : _readConversations();
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'conversation_refresh_failed',
        error: error,
      );
      return;
    }
    final signature = _signatureForConversations(conversations);
    if (!force && signature == _conversationSignature) return;
    final hasNewMessage = conversations.any(
      (conversation) =>
          !MessageNotifications.isConversationVisible(conversation.id) &&
          conversation.unreadCount > (_unreadCounts[conversation.id] ?? 0),
    );
    final newPin = conversations.any(
      (conversation) =>
          !MessageNotifications.isConversationVisible(conversation.id) &&
          conversation.pinnedMessageIds.any(
            (id) => !_conversations
                .where((old) => old.id == conversation.id)
                .any((old) => old.pinnedMessageIds.contains(id)),
          ),
    );
    if (hasNewMessage || newPin) {
      for (final conversation in conversations) {
        final pin = conversation.pinnedMessageIds.any(
          (id) => !_conversations
              .where((old) => old.id == conversation.id)
              .any((old) => old.pinnedMessageIds.contains(id)),
        );
        if (!MessageNotifications.isConversationVisible(conversation.id) &&
            (conversation.unreadCount > (_unreadCounts[conversation.id] ?? 0) ||
                pin)) {
          unawaited(
            const MessageNotifications().showIncomingMessage(
              pinned: pin,
              conversationId: conversation.id,
            ),
          );
        }
      }
    }
    unawaited(
      const MessageNotifications().clearSummaryIfRead(
        hasUnreadMessages: conversations.any(
          (conversation) => conversation.unreadCount > 0,
        ),
      ),
    );
    if (newPin && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Un messaggio è stato fissato in un gruppo.')),
      );
    }
    setState(() {
      _conversations = conversations;
      _conversationUpdates.value = conversations;
      _conversationSignature = signature;
      _isLoadingConversations = false;
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
    _conversationUpdates.dispose();
    widget.identityService.removeListener(_onIdentityChanged);
    _inboxTimer?.cancel();
    super.dispose();
  }

  bool _detailsVisible = true;

  Future<void> _selectConversation(String conversationId) async {
    AppLog.instance.record(
      category: 'messenger',
      action: 'conversation_selected',
      verbose: true,
    );
    if (mounted) {
      setState(() {
        _activeConversationId = conversationId;
        _conversationSelectionRevision++;
      });
    }
    if (!(widget.bridge is GroupChannelBridge &&
        _conversations.any(
          (item) => item.id == conversationId && item.isGroup,
        ))) {
      unawaited(_markConversationRead(conversationId));
    }
  }

  Future<void> _markConversationRead(String conversationId) async {
    try {
      await widget.bridge.markConversationRead(conversationId);
      await const MessageNotifications().clearConversation(conversationId);
    } on Object catch (error) {
      // A newly imported contact has no authenticated session yet, but its
      // safety details must remain inspectable from the UI.
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'mark_read_failed',
        error: error,
      );
    }
    if (mounted) unawaited(_refreshInbox(force: true));
  }

  Future<void> _addContact() async {
    AppLog.instance.record(
      category: 'contacts',
      action: 'add_dialog_opened',
      verbose: true,
    );
    final draft = await showDialog<_ContactDraft>(
      context: context,
      builder: (context) => _AddContactDialog(),
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
          'Il servizio di messaggistica non è disponibile: aggiorna Sylphy.',
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

  Future<void> _createGroup() async {
    final draft = await showDialog<_GroupDraft>(
      context: context,
      builder: (context) => _CreateGroupDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      final capability = widget.bridge;
      if (draft.joinLink != null && capability is GroupManagementBridge) {
        final id = await (capability as GroupManagementBridge).joinGroup(
          draft.joinLink!,
        );
        await _refreshInbox(force: true);
        if (mounted) {
          setState(() => _activeConversationId = id);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Richiesta di ingresso inviata. Attendi che il proprietario sia online.',
              ),
            ),
          );
        }
        return;
      }
      if (capability is! GroupMessagingBridge) {
        throw SecureMessagingException('unsupported');
      }
      final groupBridge = capability as GroupMessagingBridge;
      final id = await groupBridge.createGroup(
        name: draft.name,
        invitationCodes: draft.invitationCodes,
        professional: draft.professional,
        description: draft.description,
      );
      await _refreshInbox(force: true);
      if (mounted) setState(() => _activeConversationId = id);
    } on SecureMessagingException catch (error) {
      if (!mounted) return;
      final message = switch (error.code) {
        'feature_unavailable' => 'Lo storage sicuro non è ancora pronto.',
        'limit_exceeded' => 'Troppi membri oppure gruppo troppo grande.',
        'unsupported_version' =>
          'Per creare il gruppo, tutti i partecipanti devono aggiornare Sylphy e riaprire l’app sui dispositivi collegati.',
        'network_attach_failed' || 'network_startup_failed' =>
          'Impossibile pubblicare l’invito del gruppo. Controlla la connessione e riprova.',
        'verification_failed' =>
          'Uno dei codici invito non è valido o è duplicato.',
        _ => 'Impossibile creare il gruppo.',
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
        settings: RouteSettings(name: '/settings'),
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
    if (_isLoadingConversations && _conversations.isEmpty) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
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
            selectionRevision: _conversationSelectionRevision,
            bridge: widget.bridge,
            nativeCore: widget.nativeCore,
            veilidService: widget.veilidService,
            profile: widget.profile,
            conversations: conversations,
            activeConversation: activeConversation,
            onConversationSelected: _selectConversation,
            onChanged: _refresh,
            onAddContact: _addContact,
            onCreateGroup: _createGroup,
            onProfilePressed: _openProfile,
            onSettingsPressed: _openSettings,
            privacySettings: widget.privacySettings,
            showDetails: constraints.maxWidth >= 1180 && _detailsVisible,
            canShowDetails: constraints.maxWidth >= 1180,
            onToggleDetails: () =>
                setState(() => _detailsVisible = !_detailsVisible),
          );
        }
        return _MobileConversationList(
          conversationUpdates: _conversationUpdates,
          bridge: widget.bridge,
          nativeCore: widget.nativeCore,
          veilidService: widget.veilidService,
          profile: widget.profile,
          conversations: conversations,
          onConversationSelected: _selectConversation,
          onChanged: _refresh,
          onAddContact: _addContact,
          onCreateGroup: _createGroup,
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
    required this.selectionRevision,
    required this.bridge,
    required this.nativeCore,
    required this.veilidService,
    required this.profile,
    required this.conversations,
    required this.activeConversation,
    required this.onConversationSelected,
    required this.onChanged,
    required this.onAddContact,
    required this.onCreateGroup,
    required this.onProfilePressed,
    required this.onSettingsPressed,
    required this.privacySettings,
    required this.showDetails,
    required this.canShowDetails,
    required this.onToggleDetails,
  });

  final SecureMessagingBridge bridge;
  final int selectionRevision;
  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;
  final UserProfile profile;
  final List<Conversation> conversations;
  final Conversation? activeConversation;
  final Future<void> Function(String conversationId) onConversationSelected;
  final VoidCallback onChanged;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final VoidCallback onProfilePressed;
  final VoidCallback onSettingsPressed;
  final PrivacySettingsController privacySettings;
  final bool showDetails;
  final bool canShowDetails;
  final VoidCallback onToggleDetails;

  @override
  Widget build(BuildContext context) {
    final compactConversations =
        activeConversation?.isGroup == true && bridge is GroupChannelBridge;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _DesktopAppRail(
              snapshot: veilidService.snapshot,
              profile: profile,
              onAddContact: onAddContact,
              onCreateGroup: onCreateGroup,
              onProfilePressed: onProfilePressed,
              onPrivacyPressed: () =>
                  _showPrivacyOverview(context, nativeCore, veilidService),
              onFilesPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (context) => EncryptedFileArchivePage(
                    bridge: bridge,
                    conversations: conversations,
                  ),
                ),
              ),
              onSettingsPressed: onSettingsPressed,
            ),
            VerticalDivider(width: 1),
            SizedBox(
              width: compactConversations ? 76 : 328,
              child: compactConversations
                  ? _ConversationRail(
                      conversations: conversations,
                      activeConversationId: activeConversation?.id,
                      onSelected: onConversationSelected,
                    )
                  : _ConversationSidebar(
                      veilidSnapshot: veilidService.snapshot,
                      conversations: conversations,
                      activeConversationId: activeConversation?.id,
                      onConversationSelected: onConversationSelected,
                      onAddContact: onAddContact,
                    ),
            ),
            VerticalDivider(width: 1),
            Expanded(
              child: activeConversation == null
                  ? _EmptyInbox(
                      snapshot: veilidService.snapshot,
                      hasNativeCore: nativeCore != null,
                    )
                  : _ChatPane(
                      selectionRevision: selectionRevision,
                      bridge: bridge,
                      conversation: activeConversation!,
                      onChanged: onChanged,
                      showHeader: true,
                      onToggleDetails: canShowDetails && !compactConversations
                          ? onToggleDetails
                          : null,
                      privacySettings: privacySettings,
                    ),
            ),
            if (showDetails &&
                activeConversation != null &&
                !compactConversations) ...[
              VerticalDivider(width: 1),
              SizedBox(
                width: 292,
                child: _ConversationDetails(
                  conversation: activeConversation!,
                  onClose: onToggleDetails,
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
        SizedBox(height: 18),
        Text(
          'Nessuna conversazione sicura',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        SizedBox(height: 8),
        Text(
          hasNativeCore
              ? 'Il bridge nativo è attivo. Le conversazioni appariranno solo dopo la creazione del vault e la verifica di un contatto.'
              : 'Installa il core nativo per creare un’identità e collegarti alla rete Veilid.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppPalette.color(0xFFAEB7C3), height: 1.4),
        ),
        SizedBox(height: 12),
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
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: content,
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.color(0xFF11151B), AppPalette.color(0xFF0C0F14)],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 460),
          child: Padding(padding: EdgeInsets.all(32), child: content),
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
    required this.onCreateGroup,
    required this.onProfilePressed,
    required this.onPrivacyPressed,
    required this.onFilesPressed,
    required this.onSettingsPressed,
  });

  final VeilidSnapshot snapshot;
  final UserProfile profile;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final VoidCallback onProfilePressed;
  final VoidCallback onPrivacyPressed;
  final VoidCallback onFilesPressed;
  final VoidCallback onSettingsPressed;

  @override
  Widget build(BuildContext context) {
    final networkColor = _networkColor(snapshot.phase);
    return ColoredBox(
      color: AppPalette.color(0xFF090C11),
      child: SizedBox(
        width: 72,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
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
              SizedBox(height: 30),
              _RailButton(
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
                icon: Icons.groups_2_outlined,
                tooltip: 'Crea gruppo o canale',
                onPressed: onCreateGroup,
              ),
              _RailButton(
                key: ValueKey('open-encrypted-files'),
                icon: Icons.folder_copy_outlined,
                tooltip: 'File cifrati',
                onPressed: onFilesPressed,
              ),
              Spacer(),
              Tooltip(
                message: snapshot.detail,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: networkColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppPalette.color(0xFF090C11),
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
              SizedBox(height: 14),
              _RailButton(
                icon: Icons.shield_outlined,
                tooltip: 'Privacy e rete',
                onPressed: onPrivacyPressed,
              ),
              _RailButton(
                key: ValueKey('open-settings'),
                icon: Icons.settings_outlined,
                tooltip: 'Impostazioni',
                onPressed: onSettingsPressed,
              ),
              SizedBox(height: 8),
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
      padding: EdgeInsets.only(bottom: 8),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed ?? () {},
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.primary
              : AppPalette.color(0xFF8C96A5),
        ),
        icon: Icon(icon),
      ),
    );
  }
}

class _ConversationRail extends StatelessWidget {
  const _ConversationRail({
    required this.conversations,
    required this.activeConversationId,
    required this.onSelected,
  });

  final List<Conversation> conversations;
  final String? activeConversationId;
  final Future<void> Function(String) onSelected;

  @override
  Widget build(BuildContext context) => Material(
    key: ValueKey('conversation-rail'),
    color: AppPalette.color(0xFF15181E),
    child: ListView.builder(
      padding: EdgeInsets.symmetric(vertical: 8),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        final selected = conversation.id == activeConversationId;
        return Tooltip(
          message: conversation.name,
          child: Semantics(
            label: conversation.name,
            selected: selected,
            button: true,
            child: InkWell(
              key: ValueKey('conversation-rail-${conversation.id}'),
              onTap: () => onSelected(conversation.id),
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12)
                      : null,
                  border: Border(
                    left: BorderSide(
                      width: 3,
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                    ),
                  ),
                ),
                child: Center(
                  child: Badge(
                    isLabelVisible: conversation.unreadCount > 0,
                    label: Text(
                      conversation.unreadCount > 99
                          ? '99+'
                          : '${conversation.unreadCount}',
                    ),
                    child: _ContactAvatar(
                      conversation: conversation,
                      radius: 23,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
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
      color: AppPalette.color(0xFF15181E),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(24, 18, 12, 12),
            child: Row(
              children: [
                Expanded(child: _BrandMark()),
                IconButton(
                  key: ValueKey('desktop-add-contact'),
                  tooltip: 'Aggiungi contatto',
                  onPressed: widget.onAddContact,
                  icon: Icon(Icons.person_add_alt_1_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Cerca conversazioni',
                prefixIcon: Icon(Icons.search_rounded),
                contentPadding: EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 10),
            child: Row(
              children: [
                Text(
                  'CONVERSAZIONI',
                  style: TextStyle(
                    color: AppPalette.color(0xFF9299A5),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                Spacer(),
                Icon(
                  Icons.tune_rounded,
                  size: 18,
                  color: AppPalette.color(0xFF9299A5),
                ),
              ],
            ),
          ),
          Expanded(
            child: conversations.isEmpty
                ? Center(
                    child: Text(
                      'Nessuna conversazione trovata',
                      style: TextStyle(color: AppPalette.color(0xFF9299A5)),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    itemCount: conversations.length,
                    separatorBuilder: (context, index) => SizedBox(height: 4),
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
            padding: EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: _VaultStatusCard(veilidSnapshot: widget.veilidSnapshot),
          ),
        ],
      ),
    );
  }
}

class _MobileConversationList extends StatelessWidget {
  const _MobileConversationList({
    required this.conversationUpdates,
    required this.bridge,
    required this.nativeCore,
    required this.veilidService,
    required this.profile,
    required this.conversations,
    required this.onConversationSelected,
    required this.onChanged,
    required this.onAddContact,
    required this.onCreateGroup,
    required this.onProfilePressed,
    required this.onSettingsPressed,
    required this.privacySettings,
  });

  final SecureMessagingBridge bridge;
  final ValueListenable<List<Conversation>> conversationUpdates;
  final NativeCoreApi? nativeCore;
  final VeilidService veilidService;
  final UserProfile profile;
  final List<Conversation> conversations;
  final Future<void> Function(String conversationId) onConversationSelected;
  final VoidCallback onChanged;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final VoidCallback onProfilePressed;
  final VoidCallback onSettingsPressed;
  final PrivacySettingsController privacySettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _BrandMark(compact: true),
        actions: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: _ProfileAvatar(
              profile: profile,
              radius: 18,
              onPressed: onProfilePressed,
            ),
          ),
          SizedBox(width: 4),
          IconButton(
            tooltip: 'Stato protezione',
            onPressed: () =>
                _showPrivacyOverview(context, nativeCore, veilidService),
            icon: Icon(Icons.shield_outlined),
          ),
          IconButton(
            key: ValueKey('open-encrypted-files'),
            tooltip: 'File cifrati',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (context) => EncryptedFileArchivePage(
                  bridge: bridge,
                  conversations: conversations,
                ),
              ),
            ),
            icon: Icon(Icons.folder_copy_outlined),
          ),
          IconButton(
            key: ValueKey('open-settings'),
            tooltip: 'Impostazioni',
            onPressed: onSettingsPressed,
            icon: Icon(Icons.settings_outlined),
          ),
          SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView.separated(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 100),
          itemCount: conversations.isEmpty ? 3 : conversations.length + 2,
          separatorBuilder: (context, index) => SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _MobileNetworkStatus(
                snapshot: veilidService.snapshot,
                onRetry: veilidService.retry,
              );
            }
            if (index == 1) {
              return Padding(
                padding: EdgeInsets.fromLTRB(4, 14, 4, 4),
                child: Text(
                  'CONVERSAZIONI',
                  style: TextStyle(
                    color: AppPalette.color(0xFF9299A5),
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
              onTap: () {
                unawaited(onConversationSelected(conversation.id));
                Navigator.of(context)
                    .push<void>(
                      MaterialPageRoute(
                        builder: (context) =>
                            ValueListenableBuilder<List<Conversation>>(
                              valueListenable: conversationUpdates,
                              builder: (context, currentConversations, _) =>
                                  _MobileChatScreen(
                                    bridge: bridge,
                                    conversation: conversation,
                                    conversations: currentConversations,
                                    onConversationSelected:
                                        onConversationSelected,
                                    onChanged: onChanged,
                                    privacySettings: privacySettings,
                                  ),
                            ),
                      ),
                    )
                    .then((_) => onChanged());
              },
            );
          },
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'mobile-create-group',
            tooltip: 'Crea gruppo o canale',
            onPressed: onCreateGroup,
            child: Icon(Icons.groups_2_outlined),
          ),
          SizedBox(height: 10),
          FloatingActionButton.extended(
            key: ValueKey('mobile-add-contact'),
            heroTag: 'mobile-add-contact',
            onPressed: onAddContact,
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            icon: Icon(Icons.edit_square),
            label: Text('Aggiungi contatto'),
          ),
        ],
      ),
    );
  }
}

class _MobileChatScreen extends StatefulWidget {
  const _MobileChatScreen({
    required this.bridge,
    required this.conversation,
    required this.onChanged,
    required this.privacySettings,
    required this.conversations,
    required this.onConversationSelected,
  });

  final SecureMessagingBridge bridge;
  final Conversation conversation;
  final VoidCallback onChanged;
  final PrivacySettingsController privacySettings;
  final List<Conversation> conversations;
  final Future<void> Function(String) onConversationSelected;

  @override
  State<_MobileChatScreen> createState() => _MobileChatScreenState();
}

class _MobileChatScreenState extends State<_MobileChatScreen> {
  final _chatPaneKey = GlobalKey<_ChatPaneState>();
  String? _selectedConversationId;

  @override
  Widget build(BuildContext context) {
    final bridge = widget.bridge;
    final conversation = widget.conversations.firstWhere(
      (item) => item.id == (_selectedConversationId ?? widget.conversation.id),
      orElse: () => widget.conversation,
    );
    final onChanged = widget.onChanged;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _GroupHeaderButton(
          onTap: conversation.isGroup && bridge is GroupManagementBridge
              ? () => _chatPaneKey.currentState?._manageGroup()
              : () => _showContactProfile(
                  context,
                  conversation,
                  bridge,
                  onChanged,
                ),
          child: Row(
            children: [
              _ContactAvatar(conversation: conversation, radius: 17),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conversation.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _presenceLabel(conversation),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.color(0xFF9DA5B2),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Sicurezza conversazione',
            onPressed: () =>
                _showSecuritySheet(context, conversation, bridge, onChanged),
            icon: Icon(Icons.verified_user_outlined),
          ),
          IconButton(
            key: ValueKey('delete-conversation-mobile'),
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
            icon: Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: _ChatPane(
        key: _chatPaneKey,
        bridge: bridge,
        conversation: conversation,
        onChanged: onChanged,
        showHeader: false,
        conversationRail: _ConversationRail(
          conversations: widget.conversations,
          activeConversationId: conversation.id,
          onSelected: (id) async {
            if (id == conversation.id) {
              _chatPaneKey.currentState?._returnToChannels();
            } else {
              setState(() => _selectedConversationId = id);
            }
            await widget.onConversationSelected(id);
          },
        ),
        privacySettings: widget.privacySettings,
      ),
    );
  }
}

class _ChatPane extends StatefulWidget {
  const _ChatPane({
    super.key,
    required this.bridge,
    required this.conversation,
    required this.onChanged,
    required this.showHeader,
    this.onToggleDetails,
    this.conversationRail,
    this.selectionRevision = 0,
    required this.privacySettings,
  });

  final SecureMessagingBridge bridge;
  final Conversation conversation;
  final VoidCallback onChanged;
  final bool showHeader;
  final VoidCallback? onToggleDetails;
  final Widget? conversationRail;
  final int selectionRevision;
  final PrivacySettingsController privacySettings;

  @override
  State<_ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<_ChatPane> with WidgetsBindingObserver {
  ChatMessage? _replyTo;
  final Set<String> _pendingMessageActions = {};
  List<Map> _channels = [];
  String? _channelId;
  bool _channelsLoaded = false;
  bool _channelSelected = false;
  bool _channelLoadFailed = false;
  int _channelLoadGeneration = 0;
  final _channelListController = ScrollController();
  final Map<String?, String> _channelDrafts = {};
  Map<String, dynamic>? _groupDetails;

  bool get _supportsChannels =>
      widget.conversation.isGroup &&
      _management != null &&
      widget.bridge is GroupChannelBridge;
  bool get _hasChannelList => _supportsChannels && _channels.isNotEmpty;
  bool get _isShowingMessages =>
      !_supportsChannels ||
      (_channelsLoaded && (!_hasChannelList || _channelSelected));

  bool get _canSendMessages =>
      _groupDetails?['can_send'] as bool? ??
      widget.conversation.canSendMessages;
  List<String> get _pinnedMessageIds =>
      (_groupDetails?['pinned'] as List?)?.cast<String>() ??
      widget.conversation.pinnedMessageIds;
  bool _actionPending(String id) =>
      _pendingMessageActions.contains(id) ||
      (_groupDetails?['pending_actions'] as List? ?? []).any(
        (action) => action['message_id'] == id,
      );

  Future<void> _loadChannels() async {
    if (!_supportsChannels) return;
    final id = widget.conversation.id;
    final generation = ++_channelLoadGeneration;
    try {
      final details = await _management!.groupDetails(id);
      if (!mounted ||
          widget.conversation.id != id ||
          generation != _channelLoadGeneration) {
        return;
      }
      setState(() {
        // A channel added while General is open must not discard its draft or
        // interrupt the conversation. New group visits still start at the list.
        if (_channelsLoaded && _channels.isEmpty) _channelSelected = true;
        _groupDetails = details;
        _channels = (details['channels'] as List? ?? []).cast<Map>();
        if (_channelId != null &&
            !_channels.any((channel) => channel['id'] == _channelId)) {
          _channelId = null;
          _channelSelected = false;
          _composerController.clear();
          _replyTo = null;
        }
        _channelsLoaded = true;
        _channelLoadFailed = false;
      });
      if (_isShowingMessages) unawaited(_markConversationReadSafely());
    } on Object catch (error) {
      if (mounted &&
          widget.conversation.id == id &&
          generation == _channelLoadGeneration) {
        setState(() => _channelLoadFailed = true);
      }
      AppLog.instance.record(
        category: 'messenger',
        action: 'channels_load_failed',
        level: AppLogLevel.error,
        result: error is SecureMessagingException
            ? error.code
            : error.runtimeType.toString(),
        force: true,
      );
    }
  }

  void _selectChannel(String? id) {
    setState(() {
      if (_isShowingMessages) {
        _channelDrafts[_channelId] = _composerController.text;
      }
      _channelId = id;
      _channelSelected = true;
      _composerController.text = _channelDrafts[id] ?? '';
      _replyTo = null;
      _lastAcknowledgedIncomingId = null;
    });
    unawaited(_markConversationReadSafely());
    _scheduleScrollToBottom();
  }

  void _returnToChannels() {
    if (!_hasChannelList || !_channelSelected) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _channelDrafts[_channelId] = _composerController.text;
      _composerController.clear();
      _replyTo = null;
      _channelSelected = false;
      _lastAcknowledgedIncomingId = null;
    });
  }

  GroupManagementBridge? get _management =>
      widget.bridge is GroupManagementBridge
      ? widget.bridge as GroupManagementBridge
      : null;

  Future<void> _manageGroup() async {
    final bridge = _management;
    if (bridge == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GroupManagementPage(
          bridge: bridge,
          conversationId: widget.conversation.id,
        ),
      ),
    );
    if (mounted) {
      widget.onChanged();
      await _reloadMessagesAsync(force: true);
      await _loadChannels();
    }
  }

  Future<void> _searchChat([String initial = '', List<String>? pins]) async {
    final bridge = _management;
    if (bridge == null) return;
    final id = widget.conversation.id;
    final result = await Navigator.of(context).push<Map>(
      MaterialPageRoute(
        builder: (_) => ChatSearchPage(
          bridge: bridge,
          conversationId: id,
          initialQuery: initial,
          pinnedMessageIds: pins,
        ),
      ),
    );
    if (result != null && mounted && widget.conversation.id == id) {
      _selectChannel(result['channel_id'] as String?);
      setState(
        () => _replyTo = ChatMessage(
          id: result['id'] as String,
          authorId: result['author_id'] as String,
          authorName: result['author_name'] as String?,
          body: result['body'] as String,
          channelId: result['channel_id'] as String?,
          sentAt: DateTime.fromMillisecondsSinceEpoch(
            result['sent_at_ms'] as int,
          ),
          isOutgoing: result['is_outgoing'] == true,
        ),
      );
    }
  }

  Future<void> _mentionMember() async {
    final bridge = _management;
    if (bridge == null) return;
    final id = widget.conversation.id;
    try {
      final details = await bridge.groupDetails(id);
      if (!mounted || widget.conversation.id != id) return;
      final member = await showModalBottomSheet<Map>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text('Menziona un membro')),
              for (final member in (details['members'] as List).cast<Map>())
                ListTile(
                  title: Text(member['name'] as String),
                  onTap: () => Navigator.pop(context, member),
                ),
            ],
          ),
        ),
      );
      if (!mounted || member == null || widget.conversation.id != id) return;
      final mention = memberMention(member['name'] as String);
      _composerController.text = '${_composerController.text}$mention ';
      _composerController.selection = TextSelection.collapsed(
        offset: _composerController.text.length,
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(groupError(error))));
      }
    }
  }

  bool _mentionOpen = false;

  Future<void> _openMention(String mention) async {
    if (_mentionOpen) return;
    _mentionOpen = true;
    final conversation = widget.conversation;
    try {
      final List<Map> members;
      if (conversation.isGroup) {
        final bridge = _management;
        if (bridge == null) return;
        final details = await bridge
            .groupDetails(conversation.id)
            .timeout(Duration(seconds: 15));
        members = (details['members'] as List? ?? []).cast<Map>();
      } else {
        members = [
          {'id': conversation.id, 'name': conversation.name},
        ];
      }
      if (!mounted || widget.conversation.id != conversation.id) return;
      final matches = members
          .where(
            (member) =>
                memberMention(member['name'] as String).toLowerCase() ==
                mention.toLowerCase(),
          )
          .toList();
      if (matches.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Persona non trovata tra i membri attuali.')),
        );
        return;
      }
      final member = matches.length == 1
          ? matches.single
          : await showModalBottomSheet<Map>(
              context: context,
              builder: (context) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(title: Text('Scegli la persona menzionata')),
                    for (final member in matches)
                      ListTile(
                        title: Text(member['name'] as String),
                        subtitle: Text(member['id'] as String),
                        onTap: () => Navigator.pop(context, member),
                      ),
                  ],
                ),
              ),
            );
      if (member == null ||
          !mounted ||
          widget.conversation.id != conversation.id) {
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Icon(Icons.person_rounded)),
                  title: Text(member['name'] as String),
                  subtitle: Text(
                    conversation.isGroup
                        ? member['is_owner'] == true
                              ? 'Proprietario del gruppo'
                              : member['is_admin'] == true
                              ? 'Amministratore del gruppo'
                              : 'Membro del gruppo'
                        : 'Contatto',
                  ),
                ),
                SizedBox(height: 12),
                Text('Identificativo'),
                SelectableText(member['id'] as String),
              ],
            ),
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted && widget.conversation.id == conversation.id) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(groupError(error))));
      }
    } finally {
      _mentionOpen = false;
    }
  }

  Future<void> _messageActions(ChatMessage message) async {
    final bridge = _management;
    if (bridge == null || _messageActionsOpen || _actionPending(message.id)) {
      return;
    }
    _messageActionsOpen = true;
    final conversationId = widget.conversation.id;
    try {
      final details = widget.conversation.isGroup
          ? bridge.groupDetails(conversationId)
          : Future<Map<String, dynamic>>.value({});
      var pinned = _pinnedMessageIds.contains(message.id);
      var selectionMade = false;
      Map? targetMember;
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => FutureBuilder<Map<String, dynamic>>(
          future: details,
          builder: (context, snapshot) {
            final permissions = snapshot.data?['permissions'] as Map? ?? {};
            final pending = (snapshot.data?['pending_actions'] as List? ?? [])
                .any((action) => action['message_id'] == message.id);
            targetMember = (snapshot.data?['members'] as List? ?? [])
                .cast<Map>()
                .where((member) => member['id'] == message.authorId)
                .firstOrNull;
            if (snapshot.data?['pinned'] case final List ids) {
              pinned = ids.contains(message.id);
            }
            void choose(String action) {
              if (selectionMade) return;
              selectionMade = true;
              Navigator.pop(context, action);
            }

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.reply),
                    title: Text('Rispondi'),
                    onTap: () => choose('reply'),
                  ),
                  if (snapshot.connectionState != ConnectionState.done)
                    LinearProgressIndicator(),
                  if (snapshot.hasError)
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(groupError(snapshot.error!)),
                    ),
                  if (pending)
                    ListTile(
                      title: Text(
                        'Modifica già richiesta, in attesa di conferma',
                      ),
                    ),
                  if (!pending && permissions['pin_messages'] == true)
                    ListTile(
                      leading: Icon(Icons.push_pin_outlined),
                      title: Text(
                        pinned ? 'Rimuovi dai fissati' : 'Fissa per tutti',
                      ),
                      onTap: () => choose('pin'),
                    ),
                  if (!pending && permissions['delete_messages'] == true)
                    ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Elimina messaggio per tutti'),
                      onTap: () => choose('delete'),
                    ),
                  if (!message.isOutgoing &&
                      messageContainsLink(message.body) &&
                      permissions['manage_members'] == true &&
                      targetMember != null &&
                      targetMember!['is_owner'] != true &&
                      targetMember!['permissions'] == null &&
                      (targetMember!['restriction'] as Map?)?['send_links'] !=
                          false)
                    ListTile(
                      leading: Icon(Icons.link_off),
                      title: Text('Blocca i link di questo membro'),
                      onTap: () => choose('block_links'),
                    ),
                ],
              ),
            );
          },
        ),
      );
      if (!mounted ||
          conversationId != widget.conversation.id ||
          action == null) {
        return;
      }
      if (action == 'reply') {
        setState(() => _replyTo = message);
        return;
      }
      if (action == 'delete') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Elimina messaggio per tutti?'),
            content: Text(
              'Il comando sarà consegnato anche ai membri offline quando torneranno online.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Annulla'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Elimina'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      setState(() => _pendingMessageActions.add(message.id));
      final result = await bridge.groupAction(
        conversationId,
        action == 'block_links'
            ? {
                'kind': 'restrict',
                'member_id': message.authorId,
                'policy': {
                  ...?(targetMember?['restriction'] as Map?),
                  'send_links': false,
                },
              }
            : {
                'kind': action == 'pin' ? 'pin' : 'delete_message',
                'message_id': message.id,
                if (action == 'pin') 'pinned': !pinned,
              },
      );
      if (!mounted) return;
      if (result != 'pending_owner') {
        setState(() => _pendingMessageActions.remove(message.id));
      }
      if (result == 'pending_owner') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Richiesta inviata al proprietario del gruppo.'),
          ),
        );
      } else if (action == 'block_links') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invio di link bloccato per questo membro.')),
        );
      }
      widget.onChanged();
      await _reloadMessagesAsync(force: true);
      await _loadChannels();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(groupError(error))));
      }
    } finally {
      _messageActionsOpen = false;
      if (mounted) setState(() => _pendingMessageActions.remove(message.id));
    }
  }

  bool _messageActionsOpen = false;

  final TextEditingController _composerController = TextEditingController();
  final ScrollController _messageScrollController = ScrollController();
  Timer? _messageTimer;
  List<ChatMessage> _messages = const [];
  String _messageSignature = '';
  String? _latestMessageId;
  bool _isSendingAttachment = false;
  final List<ChatMessage> _optimisticMessages = [];
  String? _lastAcknowledgedIncomingId;
  int _lastInboxRevision = 0;
  bool _isRefreshingMessages = false;
  bool _isLoadingMessages = false;
  bool _isLoadingOlder = false;
  int _messageLoadGeneration = 0;
  int _conversationGeneration = 0;
  ValueListenable<int>? _inboxChanges;
  ModalRoute<dynamic>? _chatRoute;

  bool get _androidBackground =>
      defaultTargetPlatform == TargetPlatform.android &&
      WidgetsBinding.instance.lifecycleState != null &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _configureInboxUpdates();
    if (state == AppLifecycleState.resumed) {
      unawaited(_reloadMessagesAsync(force: true));
      unawaited(_loadChannels());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chatRoute = ModalRoute.of(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MessageNotifications.trackConversation(
      this,
      () => mounted && _chatRoute?.isCurrent == true && _isShowingMessages
          ? widget.conversation.id
          : null,
    );
    final bridge = widget.bridge;
    if (bridge is CachedMessagingBridge) {
      final cached = bridge.cachedMessages(widget.conversation.id);
      if (cached == null) {
        _isLoadingMessages = true;
      } else {
        _messages = cached;
        _messageSignature = _signatureForMessages(cached);
        _latestMessageId = cached.isEmpty ? null : cached.last.id;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToBottom();
          unawaited(_reloadMessagesAsync(force: true));
        }
      });
    } else {
      _reloadMessages(force: true);
    }
    _configureInboxUpdates();
    unawaited(_loadChannels());
  }

  void _configureInboxUpdates() {
    _messageTimer?.cancel();
    _messageTimer = null;
    _inboxChanges?.removeListener(_onInboxRevisionChanged);
    _inboxChanges = null;
    final bridge = widget.bridge;
    if (bridge is InboxRefreshingBridge) {
      _lastInboxRevision = (bridge as InboxRefreshingBridge).inboxRevision;
      if (bridge is InboxRevisionNotifications) {
        _inboxChanges = (bridge as InboxRevisionNotifications).inboxChanges;
        _inboxChanges!.addListener(_onInboxRevisionChanged);
      } else if (!widget.showHeader && !_androidBackground) {
        _messageTimer = Timer.periodic(
          Duration(seconds: 3),
          (_) => _refreshMessagesFromNetwork(),
        );
      }
    }
  }

  void _onInboxRevisionChanged() {
    final revision = _inboxChanges?.value;
    if (!mounted || revision == null || revision == _lastInboxRevision) return;
    _lastInboxRevision = revision;
    unawaited(_reloadMessagesAsync());
    unawaited(_loadChannels());
  }

  @override
  void didUpdateWidget(covariant _ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id == widget.conversation.id &&
        oldWidget.selectionRevision != widget.selectionRevision) {
      _returnToChannels();
    }
    if (oldWidget.conversation.groupRevision !=
        widget.conversation.groupRevision) {
      unawaited(_loadChannels());
    }
    if (oldWidget.bridge != widget.bridge ||
        oldWidget.showHeader != widget.showHeader) {
      _configureInboxUpdates();
    }
    if (oldWidget.conversation.id != widget.conversation.id ||
        oldWidget.bridge != widget.bridge) {
      _messageLoadGeneration++;
      _conversationGeneration++;
      _channels = [];
      _channelsLoaded = false;
      _channelSelected = false;
      _channelLoadFailed = false;
      _channelDrafts.clear();
      _groupDetails = null;
      _channelId = null;
      unawaited(_loadChannels());
      _composerController.clear();
      _replyTo = null;
      _optimisticMessages.clear();
      _lastAcknowledgedIncomingId = null;
      _isLoadingOlder = false;
      final bridge = widget.bridge;
      if (bridge is CachedMessagingBridge) {
        final cached = bridge.cachedMessages(widget.conversation.id);
        _messages = cached ?? [];
        _messageSignature = cached == null ? '' : _signatureForMessages(cached);
        _latestMessageId = cached == null || cached.isEmpty
            ? null
            : cached.last.id;
        _isLoadingMessages = cached == null;
        _scheduleScrollToBottom();
        unawaited(_reloadMessagesAsync(force: true));
      } else {
        _messages = const [];
        _messageSignature = '';
        _latestMessageId = null;
        _reloadMessages(force: true);
      }
    } else if (oldWidget.conversation.lastActivity !=
            widget.conversation.lastActivity ||
        oldWidget.conversation.unreadCount != widget.conversation.unreadCount ||
        oldWidget.conversation.lastMessage != widget.conversation.lastMessage) {
      final bridge = widget.bridge;
      if (bridge is CachedMessagingBridge) {
        unawaited(_reloadMessagesAsync(force: true));
      } else {
        _reloadMessages(force: true);
      }
    }
  }

  Future<void> _refreshMessagesFromNetwork() async {
    if (!mounted || _androidBackground || _isRefreshingMessages) return;
    final bridge = widget.bridge;
    if (bridge is! InboxRefreshingBridge) return;
    _isRefreshingMessages = true;
    try {
      final revision = await (bridge as InboxRefreshingBridge).refreshInbox();
      if (!mounted || revision == _lastInboxRevision) return;
      _lastInboxRevision = revision;
      await _reloadMessagesAsync(force: true);
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
    WidgetsBinding.instance.removeObserver(this);
    MessageNotifications.untrackConversation(this);
    _channelListController.dispose();
    _messageTimer?.cancel();
    _inboxChanges?.removeListener(_onInboxRevisionChanged);
    _messageScrollController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (!mounted || !_messageScrollController.hasClients) return;
    unawaited(
      _messageScrollController.animateTo(
        0,
        duration: Duration(milliseconds: 220),
        curve: Curves.easeOut,
      ),
    );
  }

  void _reloadMessages({bool force = false}) {
    if (!mounted) return;
    List<ChatMessage> messages;
    try {
      messages = widget.bridge.listMessages(widget.conversation.id);
    } on Object {
      return;
    }
    _applyMessages(messages, force: force);
  }

  Future<void> _loadOlderMessages() async {
    final bridge = widget.bridge;
    if (bridge is! CachedMessagingBridge || _isLoadingOlder) return;
    final conversationId = widget.conversation.id;
    final generation = _conversationGeneration;
    setState(() => _isLoadingOlder = true);
    try {
      final messages = await bridge.loadOlderMessages(conversationId);
      if (mounted &&
          widget.bridge == bridge &&
          widget.conversation.id == conversationId &&
          generation == _conversationGeneration) {
        _applyMessages(messages, force: true);
      }
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'older_messages_load_failed',
        error: error,
      );
    } finally {
      if (mounted &&
          widget.bridge == bridge &&
          widget.conversation.id == conversationId &&
          generation == _conversationGeneration) {
        setState(() => _isLoadingOlder = false);
      }
    }
  }

  Future<void> _reloadMessagesAsync({bool force = false}) async {
    final bridge = widget.bridge;
    if (bridge is! CachedMessagingBridge) {
      _reloadMessages(force: force);
      return;
    }
    final conversationId = widget.conversation.id;
    final generation = ++_messageLoadGeneration;
    final cached = bridge.cachedMessages(conversationId);
    if (cached != null) {
      _applyMessages(cached, force: force);
    } else if (_messages.isEmpty && mounted && !_isLoadingMessages) {
      setState(() => _isLoadingMessages = true);
    }
    try {
      final messages = await bridge.refreshMessages(
        conversationId,
        priority: true,
      );
      if (!mounted ||
          generation != _messageLoadGeneration ||
          widget.conversation.id != conversationId) {
        return;
      }
      _applyMessages(messages, force: force);
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'message_load_failed',
        error: error,
      );
      if (mounted && generation == _messageLoadGeneration) {
        setState(() => _isLoadingMessages = false);
      }
    }
  }

  void _applyMessages(List<ChatMessage> messages, {required bool force}) {
    if (!mounted) return;
    final signature = _signatureForMessages(messages);
    if (!force && signature == _messageSignature) return;
    final previousLatestId = _latestMessageId;
    final latestId = messages.isEmpty ? null : messages.last.id;
    setState(() {
      _messages = messages;
      _messageSignature = signature;
      _latestMessageId = latestId;
      _isLoadingMessages = false;
    });
    if (latestId != null && latestId != previousLatestId) {
      _scheduleScrollToBottom();
    }
    String? latestIncomingId;
    for (final message in messages.reversed) {
      if (!message.isOutgoing && message.channelId == _channelId) {
        latestIncomingId = message.id;
        break;
      }
    }
    if (latestIncomingId != null &&
        latestIncomingId != _lastAcknowledgedIncomingId) {
      _lastAcknowledgedIncomingId = latestIncomingId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_markConversationReadSafely());
      });
    }
  }

  Future<void> _markConversationReadSafely() async {
    if (!_isShowingMessages ||
        !MessageNotifications.isConversationVisible(widget.conversation.id)) {
      _lastAcknowledgedIncomingId = null;
      return;
    }
    try {
      final bridge = widget.bridge;
      var allRead = true;
      if (widget.conversation.isGroup && bridge is GroupChannelBridge) {
        allRead = await (bridge as GroupChannelBridge).markChannelRead(
          widget.conversation.id,
          _channelId,
        );
      } else {
        await bridge.markConversationRead(widget.conversation.id);
      }
      if (allRead) {
        await const MessageNotifications().clearConversation(
          widget.conversation.id,
        );
      }
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'messenger',
        action: 'mark_read_failed',
        error: error,
      );
    }
  }

  Future<void> _sendMessage() async {
    if (!_canSendMessages) return;
    final text = _composerController.text.trim();
    if (text.isEmpty) {
      return;
    }
    final conversationId = widget.conversation.id;
    final reply = _replyTo;
    final channelId = _channelId;
    setState(() => _replyTo = null);
    _composerController.clear();
    final optimistic = ChatMessage(
      id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      authorId: 'me',
      body: text,
      replyTo: reply?.id,
      channelId: channelId,
      sentAt: DateTime.now(),
      isOutgoing: true,
      deliveryState: DeliveryState.queued,
    );
    setState(() => _optimisticMessages.add(optimistic));
    _scheduleScrollToBottom();
    AppLog.instance.record(
      category: 'messenger',
      action: 'send_requested',
      verbose: true,
    );
    try {
      if (channelId != null && widget.bridge is GroupChannelBridge) {
        await (widget.bridge as GroupChannelBridge).sendChannelText(
          conversationId,
          channelId,
          text,
          replyTo: reply?.id,
        );
      } else if (reply != null && _management != null) {
        await _management!.sendReply(conversationId, text, reply.id);
      } else {
        await widget.bridge.sendText(
          conversationId: conversationId,
          plaintext: text,
        );
      }
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
        if (widget.conversation.id == conversationId &&
            _composerController.text.isEmpty) {
          _composerController.text = text;
          setState(() => _replyTo = reply);
          _composerController.selection = TextSelection.collapsed(
            offset: _composerController.text.length,
          );
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (code) {
              'group_permission_denied' ||
              'group_closed' ||
              'slow_mode_active' ||
              'spam_rejected' => groupError(error),
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
    if (widget.conversation.id == conversationId) {
      final bridge = widget.bridge;
      if (bridge is CachedMessagingBridge) {
        await _reloadMessagesAsync(force: true);
      } else {
        _reloadMessages(force: true);
      }
    }
    if (mounted) {
      setState(() => _optimisticMessages.remove(optimistic));
    }
    widget.onChanged();
    AppLog.instance.record(
      category: 'messenger',
      action: 'send_completed',
      verbose: true,
    );
  }

  Future<void> _retrieveAttachment(
    ChatMessage message, {
    required bool cancel,
  }) async {
    final bridge = widget.bridge;
    if (bridge is! AttachmentRetrievalBridge) return;
    final conversationId = widget.conversation.id;
    try {
      await (bridge as AttachmentRetrievalBridge).requestAttachment(
        conversationId,
        message.id,
        cancel: cancel,
      );
      if (!mounted || widget.conversation.id != conversationId) return;
      await _reloadMessagesAsync(force: true);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Download non avviato. Attendi il trasferimento in corso e riprova.',
          ),
        ),
      );
    }
  }

  Future<void> _pickAndSendAttachment() async {
    if (_isSendingAttachment) return;
    final conversationId = widget.conversation.id;
    final channelId = _channelId;
    final file = await openFile();
    if (file == null || !mounted) return;
    final size = await file.length();
    if (!mounted) return;
    if (widget.conversation.id != conversationId) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'La conversazione è cambiata: seleziona nuovamente l’allegato.',
          ),
        ),
      );
      return;
    }
    if (size <= 0 || size > maxAttachmentBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Il file deve essere non vuoto e non superare 2 MiB.',
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
      if (channelId != null && widget.bridge is GroupChannelBridge) {
        await (widget.bridge as GroupChannelBridge).sendChannelAttachment(
          conversationId,
          channelId,
          file.name,
          bytes,
        );
      } else {
        await widget.bridge.sendAttachment(
          conversationId: conversationId,
          fileName: file.name,
          bytes: bytes,
        );
      }
      if (!mounted) return;
      final bridge = widget.bridge;
      if (bridge is CachedMessagingBridge) {
        await _reloadMessagesAsync(force: true);
      } else {
        _reloadMessages(force: true);
      }
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

  String get _selectedChannelName => _channelId == null
      ? 'Generale'
      : _channels.firstWhere(
              (channel) => channel['id'] == _channelId,
              orElse: () => {'name': 'Canale'},
            )['name']
            as String;

  Widget _buildChannelList() => Column(
    key: ValueKey('group-channel-list'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Text(
          'CANALI DEL GRUPPO',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
      Expanded(
        child: ListView.builder(
          key: PageStorageKey('group-channels-${widget.conversation.id}'),
          controller: _channelListController,
          itemCount: _channels.length + 1,
          itemBuilder: (context, index) {
            final id = index == 0 ? null : _channels[index - 1]['id'] as String;
            final name = index == 0
                ? 'Generale'
                : _channels[index - 1]['name'] as String;
            ChatMessage? latest;
            for (final message in _messages) {
              if (message.channelId == id &&
                  (latest == null || message.orderAt.isAfter(latest.orderAt))) {
                latest = message;
              }
            }
            return ListTile(
              key: ValueKey('group-channel-${id ?? 'general'}'),
              selected: _channelSelected && _channelId == id,
              selectedTileColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.12),
              leading: Icon(
                index == 0 ? Icons.forum_outlined : Icons.tag_rounded,
              ),
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                latest?.attachmentName ?? latest?.body ?? 'Apri la chat',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _selectChannel(id),
            );
          },
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final visibleMessages =
        [
            ..._messages,
            ..._optimisticMessages,
          ].where((message) => message.channelId == _channelId).toList()
          ..sort((left, right) {
            final order = left.orderAt.compareTo(right.orderAt);
            return order == 0 ? left.id.compareTo(right.id) : order;
          });
    final cachedBridge = widget.bridge is CachedMessagingBridge
        ? widget.bridge as CachedMessagingBridge
        : null;
    final hasOlder =
        cachedBridge?.hasOlderMessages(widget.conversation.id) ?? false;
    final messagePane = Column(
      children: [
        if (_hasChannelList)
          ListTile(
            leading: IconButton(
              key: ValueKey('back-to-channels'),
              tooltip: 'Torna ai canali',
              onPressed: _returnToChannels,
              icon: Icon(Icons.arrow_back_rounded),
            ),
            title: Text(_selectedChannelName),
          ),
        if (_management != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.conversation.isGroup) ...[
                IconButton(
                  key: ValueKey('group-settings'),
                  tooltip: 'Gestisci gruppo',
                  onPressed: _manageGroup,
                  icon: Icon(Icons.tune),
                ),
                IconButton(
                  tooltip: 'Menziona un membro',
                  onPressed: _canSendMessages ? _mentionMember : null,
                  icon: Icon(Icons.alternate_email),
                ),
              ],
              IconButton(
                key: ValueKey('search-chat'),
                tooltip: 'Cerca nella chat',
                onPressed: () => _searchChat(),
                icon: Icon(Icons.search),
              ),
              if (_pinnedMessageIds.isNotEmpty)
                IconButton(
                  key: ValueKey('pinned-messages'),
                  tooltip: 'Messaggi fissati',
                  onPressed: () => _searchChat('', _pinnedMessageIds),
                  icon: Text('📌'),
                ),
            ],
          ),
        Expanded(
          child: _isLoadingMessages && _messages.isEmpty
              ? Center(child: CircularProgressIndicator())
              : ListView.builder(
                  key: ValueKey('chat-message-list'),
                  controller: _messageScrollController,
                  reverse: true,
                  padding: EdgeInsets.fromLTRB(22, 20, 22, 12),
                  itemCount: visibleMessages.length + (hasOlder ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index < visibleMessages.length) {
                      final message =
                          visibleMessages[visibleMessages.length - 1 - index];
                      final previousIndex = visibleMessages.length - 2 - index;
                      final startsDay =
                          previousIndex < 0 ||
                          !DateUtils.isSameDay(
                            visibleMessages[previousIndex].orderAt,
                            message.orderAt,
                          );
                      return Column(
                        children: [
                          if (startsDay) _DaySeparator(date: message.orderAt),
                          if (message.replyTo != null)
                            Align(
                              alignment: message.isOutgoing
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () =>
                                    _searchChat('id:${message.replyTo}'),
                                icon: Icon(Icons.reply, size: 16),
                                label: Text(
                                  visibleMessages
                                          .where(
                                            (original) =>
                                                original.id == message.replyTo,
                                          )
                                          .firstOrNull
                                          ?.body ??
                                      'Visualizza messaggio originale',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          GestureDetector(
                            onLongPress: () => _messageActions(message),
                            onSecondaryTap: () => _messageActions(message),
                            child: _MessageBubble(
                              message: message,
                              onRetrieveAttachment:
                                  widget.bridge is AttachmentRetrievalBridge
                                  ? (cancel) => _retrieveAttachment(
                                      message,
                                      cancel: cancel,
                                    )
                                  : null,
                              isPinned: _pinnedMessageIds.contains(message.id),
                              actionPending: _actionPending(message.id),
                              onMention: _openMention,
                              showAuthor: widget.conversation.isGroup,
                              onRestoreDraft:
                                  message.deliveryState ==
                                          DeliveryState.notRestored &&
                                      message.attachmentName == null
                                  ? () {
                                      if (_composerController.text.isEmpty) {
                                        _composerController.text = message.body;
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Completa la bozza attuale prima di recuperare questo messaggio.',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  : null,
                              showReceipt: true,
                            ),
                          ),
                        ],
                      );
                    }
                    if (hasOlder) {
                      return Center(
                        child: TextButton.icon(
                          onPressed: _isLoadingOlder
                              ? null
                              : _loadOlderMessages,
                          icon: _isLoadingOlder
                              ? SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(Icons.history_rounded),
                          label: Text('Carica messaggi precedenti'),
                        ),
                      );
                    }
                    return SizedBox.shrink();
                  },
                ),
        ),
        if (_replyTo != null)
          ListTile(
            dense: true,
            leading: Icon(Icons.reply),
            title: Text('Risposta a un messaggio'),
            subtitle: Text(
              _replyTo!.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Annulla risposta',
              onPressed: () => setState(() => _replyTo = null),
              icon: Icon(Icons.close),
            ),
          ),
        if (!_canSendMessages)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Non puoi scrivere in questo gruppo con i permessi attuali.',
              ),
            ),
          )
        else
          _Composer(
            controller: _composerController,
            onSend: _sendMessage,
            isSendingAttachment: _isSendingAttachment,
            incognitoKeyboard: widget.privacySettings.value.incognitoKeyboard,
            onAttachmentPressed: _pickAndSendAttachment,
          ),
      ],
    );
    return PopScope(
      canPop: widget.showHeader || !_hasChannelList || !_channelSelected,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _returnToChannels();
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppPalette.color(0xFF11151B),
              AppPalette.color(0xFF0C0F14),
            ],
          ),
        ),
        child: Column(
          children: [
            if (widget.showHeader)
              _ChatHeader(
                conversation: widget.conversation,
                bridge: widget.bridge,
                onChanged: widget.onChanged,
                onOpenProfile: widget.onToggleDetails,
                onOpenGroup: widget.conversation.isGroup && _management != null
                    ? _manageGroup
                    : null,
              ),
            Expanded(
              child: _supportsChannels && !_channelsLoaded
                  ? Center(
                      child: _channelLoadFailed
                          ? TextButton.icon(
                              onPressed: _loadChannels,
                              icon: Icon(Icons.refresh_rounded),
                              label: Text('Riprova a caricare i canali'),
                            )
                          : CircularProgressIndicator(),
                    )
                  : !_hasChannelList
                  ? messagePane
                  : widget.showHeader
                  ? Row(
                      children: [
                        SizedBox(width: 280, child: _buildChannelList()),
                        VerticalDivider(width: 1),
                        Expanded(
                          child: _channelSelected
                              ? messagePane
                              : Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'Seleziona un canale per iniziare a messaggiare',
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    )
                  : _channelSelected
                  ? messagePane
                  : Row(
                      children: [
                        if (widget.conversationRail != null) ...[
                          SizedBox(width: 76, child: widget.conversationRail),
                          VerticalDivider(width: 1),
                        ],
                        Expanded(child: _buildChannelList()),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeaderButton extends StatelessWidget {
  const _GroupHeaderButton({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return Tooltip(
      message: 'Impostazioni del gruppo',
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: 48),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.conversation,
    required this.bridge,
    required this.onChanged,
    this.onOpenGroup,
    this.onOpenProfile,
  });

  final Conversation conversation;
  final SecureMessagingBridge bridge;
  final VoidCallback onChanged;
  final VoidCallback? onOpenGroup;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 82,
      padding: EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _GroupHeaderButton(
              onTap:
                  onOpenGroup ??
                  onOpenProfile ??
                  () => _showContactProfile(
                    context,
                    conversation,
                    bridge,
                    onChanged,
                  ),
              child: Row(
                children: [
                  _ContactAvatar(conversation: conversation, radius: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conversation.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          _presenceLabel(conversation),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppPalette.color(0xFF9DA5B2),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Apri o chiudi dettagli',
            icon: Icon(Icons.person_outline),
            onPressed:
                onOpenProfile ??
                () => _showContactProfile(
                  context,
                  conversation,
                  bridge,
                  onChanged,
                ),
          ),
          _SafetyBadge(safety: conversation.safety),
          SizedBox(width: 8),
          PopupMenuButton<String>(
            key: ValueKey('conversation-menu'),
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
            itemBuilder: (context) => [
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
            icon: Icon(Icons.more_horiz_rounded),
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
            padding: EdgeInsets.symmetric(horizontal: 6),
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
          padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(
            _selected.label,
            key: ValueKey('emoji-category-title'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: emoji.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Le emoji usate di recente appariranno qui.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: EdgeInsets.fromLTRB(12, 6, 12, 12),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 54,
                  ),
                  itemCount: emoji.length,
                  itemBuilder: (context, index) {
                    final item = emoji[index];
                    return Tooltip(
                      message: item.name,
                      child: TextButton(
                        key: ValueKey('emoji-${item.char}'),
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => widget.onSelected(item),
                        child: Text(item.char, style: TextStyle(fontSize: 24)),
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
    this.incognitoKeyboard = false,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttachmentPressed;
  final bool isSendingAttachment;
  final bool incognitoKeyboard;

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
    '૮ ˶ᵔ ᵕ ᵔ˶ ა',
    '(˶˃ ᵕ ˂˶) .ᐟ.ᐟ',
    '𐔌՞. .՞𐦯',
    '₍₍⚞(˶ˆᗜˆ˵)⚟⁾⁾',
    '♡',
    'ദ്ദി◝ ⩊ ◜.ᐟ',
    '𖾕𖾝𖽙𖾟',
    '(⸝⸝๑﹏๑⸝⸝)',
    'ദ്ദി ˉ͈̀꒳ˉ͈́ )✧',
    '𑣲𝄞',
    '(˵◝ ⩊ ◜˵マ',
    '໒꒰ྀིっ˕ -｡꒱ྀི১',
    '⚞^. .^⚟',
    '(｡•̀ᴗ-)✧',
    '(っ˘з(˘⌣˘ )',
    '(๑˃ᴗ˂)ﻭ',
    '( ˘͈ ᵕ ˘͈♡)',
    'ฅ(＾・ω・＾ฅ)',
    '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧',
    '( ˶ˆ꒳ˆ˵ )',
    '(ᵔᴥᵔ)',
    '(๑•́ ₃ •̀๑)',
    '(づ￣ ³￣)づ',
    '(∩˃o˂∩)♡',
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
                TabBar(
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
                        padding: EdgeInsets.all(12),
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
          ? EdgeInsets.fromLTRB(6, 6, 6, 8)
          : EdgeInsets.fromLTRB(16, 12, 16, 18),
      decoration: BoxDecoration(
        color: AppPalette.color(0xFF15181E),
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
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.add_circle_outline_rounded),
              color: AppPalette.color(0xFFB5BDC9),
            ),
            IconButton(
              key: ValueKey('open-expression-picker'),
              tooltip: 'Emoji e kaomoji',
              visualDensity: compact ? VisualDensity.compact : null,
              onPressed: _showExpressions,
              icon: Icon(Icons.emoji_emotions_outlined),
              color: AppPalette.color(0xFFB5BDC9),
            ),
            SizedBox(width: compact ? 1 : 4),
            Expanded(
              child: TextField(
                key: ValueKey('message-composer'),
                enableIMEPersonalizedLearning:
                    kIsWeb ||
                    defaultTargetPlatform != TargetPlatform.android ||
                    !widget.incognitoKeyboard,
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
              key: ValueKey('send-message'),
              tooltip: 'Invia messaggio',
              visualDensity: compact ? VisualDensity.compact : null,
              onPressed: widget.onSend,
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              icon: Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showContactProfile(
  BuildContext context,
  Conversation conversation,
  SecureMessagingBridge bridge,
  VoidCallback onChanged,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Chiudi profilo',
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close),
              ),
            ),
            _ContactAvatar(conversation: conversation, radius: 48),
            SizedBox(height: 16),
            Text(
              conversation.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SizedBox(height: 12),
            _SafetyBadge(safety: conversation.safety),
            if (conversation.description.isNotEmpty)
              Text(conversation.description),
            SizedBox(height: 16),
            Text('Fingerprint'),
            SelectableText(
              conversation.fingerprint,
              textAlign: TextAlign.center,
            ),
            TextButton.icon(
              icon: Icon(Icons.verified_user_outlined),
              label: Text('Verifica sicurezza'),
              onPressed: () =>
                  _showSecuritySheet(context, conversation, bridge, onChanged),
            ),
          ],
        ),
      ),
    ),
  ),
);

class _ConversationDetails extends StatelessWidget {
  const _ConversationDetails({
    required this.conversation,
    this.onClose,
    required this.veilidSnapshot,
  });

  final Conversation conversation;
  final VeilidSnapshot veilidSnapshot;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppPalette.color(0xFF15181E),
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 26, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onClose != null)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Chiudi dettagli',
                  onPressed: onClose,
                  icon: Icon(Icons.close),
                ),
              ),
            Text(
              'DETTAGLI',
              style: TextStyle(
                color: AppPalette.color(0xFF9299A5),
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 24),
            Center(
              child: _ContactAvatar(conversation: conversation, radius: 42),
            ),
            SizedBox(height: 12),
            Center(
              child: Text(
                conversation.name,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            SizedBox(height: 6),
            Center(child: _SafetyBadge(safety: conversation.safety)),
            if (conversation.isGroup) ...[
              SizedBox(height: 10),
              Center(
                child: Text(
                  conversation.type == ConversationType.channel
                      ? 'Canale professionale · ${conversation.memberCount} membri'
                      : '${conversation.memberCount} membri',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppPalette.color(0xFFAEB7C3),
                    fontSize: 12,
                  ),
                ),
              ),
              if (conversation.description.isNotEmpty) ...[
                SizedBox(height: 6),
                Center(
                  child: Text(
                    conversation.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.color(0xFF9299A5),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
            SizedBox(height: 30),
            _DetailLabel('SICUREZZA SESSIONE'),
            SizedBox(height: 9),
            _InfoCard(
              icon: Icons.key_outlined,
              title: 'Fingerprint',
              subtitle: conversation.fingerprint,
            ),
            SizedBox(height: 10),
            _InfoCard(
              icon: Icons.hub_outlined,
              title: 'Trasporto',
              subtitle: veilidSnapshot.title,
            ),
            Spacer(),
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
          padding: EdgeInsets.all(11),
          child: Row(
            children: [
              _ContactAvatar(conversation: conversation, radius: 23),
              SizedBox(width: 12),
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
                        SizedBox(width: 8),
                        Text(
                          _relativeTime(conversation.lastActivity),
                          style: TextStyle(
                            color: AppPalette.color(0xFF9299A5),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Row(
                      children: [
                        if (conversation.safety ==
                            ContactSafety.refreshRequired)
                          Padding(
                            padding: EdgeInsets.only(right: 5),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 15,
                              color: AppPalette.color(0xFFFFC56B),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            conversation.lastMessage,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: conversation.unreadCount > 0
                                  ? AppPalette.color(0xFFE6E8EB)
                                  : AppPalette.color(0xFF9299A5),
                              fontSize: 13,
                              fontWeight: conversation.unreadCount > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (conversation.unreadCount > 0) ...[
                          SizedBox(width: 8),
                          Container(
                            constraints: BoxConstraints(minWidth: 20),
                            padding: EdgeInsets.symmetric(
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
  const _MessageBubble({
    required this.message,
    required this.showReceipt,
    this.onRestoreDraft,
    this.onMention,
    this.showAuthor = false,
    this.isPinned = false,
    this.actionPending = false,
    this.onRetrieveAttachment,
  });

  final ChatMessage message;
  final bool showAuthor;
  final bool isPinned;
  final bool actionPending;
  final bool showReceipt;
  final VoidCallback? onRestoreDraft;
  final ValueChanged<String>? onMention;
  final ValueChanged<bool>? onRetrieveAttachment;

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
      final location = await AttachmentDownloads().save(
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
        SnackBar(content: Text('Non è stato possibile salvare il file.')),
      );
    }
  }

  void _showImage(BuildContext context) {
    final bytes = message.attachmentBytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppPalette.color(0xFF0C0F14),
        insetPadding: EdgeInsets.all(20),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.all(12),
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: SafeAttachmentImage(bytes: bytes, expanded: true),
              ),
            ),
            Positioned(
              right: 6,
              top: 6,
              child: IconButton.filledTonal(
                tooltip: 'Chiudi',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded),
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
        : AppPalette.color(0xFF242933);
    final foreground = outgoing
        ? Theme.of(context).colorScheme.onPrimary
        : AppPalette.color(0xFFF2F3F5);
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: 520),
        margin: EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.fromLTRB(14, 10, 12, 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(outgoing ? 18 : 4),
            bottomRight: Radius.circular(outgoing ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAuthor) ...[
              Text(
                message.isOutgoing
                    ? 'Tu'
                    : (message.authorName?.trim().isNotEmpty == true
                          ? message.authorName!
                          : 'Membro ${message.authorId}'),
                key: ValueKey('message-author-${message.id}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
            ],
            if (message.attachmentName case final fileName?)
              Container(
                constraints: BoxConstraints(minWidth: 210),
                padding: EdgeInsets.all(10),
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
                          child: SafeAttachmentImage(
                            bytes: message.attachmentBytes!,
                          ),
                        ),
                      ),
                      SizedBox(height: 8),
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
                        SizedBox(width: 10),
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
                                  message.attachmentBytes?.length ??
                                      message.attachmentSize ??
                                      0,
                                ),
                                style: TextStyle(
                                  color: foreground.withValues(alpha: 0.68),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8),
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
                        if (message.attachmentDownloading &&
                            onRetrieveAttachment != null)
                          IconButton(
                            tooltip: 'Annulla download',
                            onPressed: () => onRetrieveAttachment!(true),
                            icon: Icon(Icons.close, color: foreground),
                          ),
                        if (message.canDownloadAttachment &&
                            onRetrieveAttachment != null)
                          IconButton(
                            tooltip: message.attachmentState == 'failed'
                                ? 'Riprova download'
                                : 'Scarica allegato',
                            onPressed: () => onRetrieveAttachment!(false),
                            icon: Icon(
                              Icons.cloud_download_outlined,
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
              MessageText(
                message.body,
                outgoing: outgoing,
                onMention: onMention,
                style: TextStyle(color: foreground, fontSize: 15, height: 1.3),
              ),
            if (message.attachmentName != null &&
                message.attachmentBytes == null)
              Text(
                message.attachmentDownloading
                    ? 'Download in corso…'
                    : message.attachmentState == 'failed'
                    ? 'Download non riuscito. Puoi riprovare.'
                    : 'Da scaricare',
                style: TextStyle(color: foreground, fontSize: 11),
              ),
            if (message.deliveryState == DeliveryState.notRestored) ...[
              Text(
                'Da reinviare: invio assente nel vecchio backup.',
                style: TextStyle(color: foreground, fontSize: 11),
              ),
              if (onRestoreDraft != null)
                TextButton(
                  onPressed: onRestoreDraft,
                  child: Text('Riprendi bozza'),
                ),
            ],
            if (isPinned)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.push_pin, size: 14, color: foreground),
                  SizedBox(width: 4),
                  Text(
                    'Fissato',
                    style: TextStyle(fontSize: 11, color: foreground),
                  ),
                ],
              ),
            if (actionPending)
              Text(
                'Modifica in attesa di conferma',
                style: TextStyle(fontSize: 11, color: foreground),
              ),
            SizedBox(height: 5),
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
                  SizedBox(width: 4),
                  Tooltip(
                    message: message.deliveryState.label,
                    child: Icon(
                      switch (message.deliveryState) {
                        DeliveryState.queued => Icons.schedule_rounded,
                        DeliveryState.notRestored =>
                          Icons.error_outline_rounded,
                        DeliveryState.sent => Icons.done_rounded,
                        DeliveryState.delivered ||
                        DeliveryState.read => Icons.done_all_rounded,
                      },
                      size: 14,
                      color: message.deliveryState == DeliveryState.read
                          ? AppPalette.color(0xFF2F6FED)
                          : foreground.withValues(alpha: 0.72),
                    ),
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
          child: conversation.avatarBytes != null
              ? ClipOval(
                  child: SizedBox.square(
                    dimension: radius * 2,
                    child: SafeAttachmentImage(
                      bytes: conversation.avatarBytes!,
                      previewEdge: 128,
                      fallback: Icon(
                        Icons.person_outline,
                        color: Color(conversation.accentValue),
                      ),
                    ),
                  ),
                )
              : conversation.isGroup
              ? Icon(
                  conversation.type == ConversationType.channel
                      ? Icons.campaign_rounded
                      : Icons.groups_2_rounded,
                  color: Color(conversation.accentValue),
                  size: radius * 0.9,
                )
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
                color: AppPalette.color(0xFF81E6A3),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppPalette.color(0xFF15181E),
                  width: 2,
                ),
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
        AppPalette.color(0xFF9DE4B6),
      ),
      ContactSafety.pending => (
        'Da verificare',
        Icons.shield_outlined,
        AppPalette.color(0xFFFFD27B),
      ),
      ContactSafety.refreshRequired => (
        'Chiave aggiornata',
        Icons.key_rounded,
        AppPalette.color(0xFFFFBE7A),
      ),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: details.$3.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(details.$2, size: 14, color: details.$3),
          SizedBox(width: 4),
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
        SylphyLogo(size: compact ? 36 : 42, excludeFromSemantics: true),
        SizedBox(width: 10),
        Text(
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
        key: ValueKey('open-profile'),
        customBorder: CircleBorder(),
        onTap: onPressed,
        child: CircleAvatar(
          key: ValueKey('current-profile-avatar'),
          radius: radius,
          backgroundColor: AppPalette.color(0xFF2A313B),
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

class _GroupDraft {
  const _GroupDraft({
    required this.name,
    required this.invitationCodes,
    required this.professional,
    required this.description,
    this.joinLink,
  });

  final String name;
  final List<String> invitationCodes;
  final bool professional;
  final String description;
  final String? joinLink;
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog();

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  Future<void> _joinViaLink() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Entra tramite link'),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(labelText: 'Link di invito Sylphy'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('Entra'),
          ),
        ],
      ),
    );
    if (mounted && code != null && code.isNotEmpty) {
      Navigator.pop(
        context,
        _GroupDraft(
          name: '',
          invitationCodes: [],
          professional: false,
          description: '',
          joinLink: code,
        ),
      );
    }
  }

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _membersController = TextEditingController();
  bool _professional = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _membersController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final codes = _membersController.text
        .split(RegExp(r'[\n,]'))
        .map(
          (value) => value.trim().replaceFirst(
            RegExp(r'^sylphy:', caseSensitive: false),
            '',
          ),
        )
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    Navigator.of(context).pop(
      _GroupDraft(
        name: _nameController.text.trim(),
        invitationCodes: codes,
        professional: _professional,
        description: _descriptionController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.groups_2_outlined),
          SizedBox(width: 12),
          Flexible(child: Text('Crea gruppo')),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Nome',
                    prefixIcon: Icon(Icons.title_rounded),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Inserisci un nome.'
                      : null,
                ),
                SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Descrizione (facoltativa)',
                    prefixIcon: Icon(Icons.subject_rounded),
                  ),
                ),
                SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Gruppo aziendale'),
                  subtitle: Text(
                    'Tutti possono scrivere. I permessi si modificano nelle impostazioni del gruppo.',
                  ),
                  value: _professional,
                  onChanged: (value) => setState(() => _professional = value),
                ),
                SizedBox(height: 8),
                TextFormField(
                  controller: _membersController,
                  minLines: 4,
                  maxLines: 8,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Codici invito dei membri',
                    hintText: 'Un codice per riga',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.person_add_alt_1_rounded),
                  ),
                  validator: (value) {
                    final count = (value ?? '')
                        .split(RegExp(r'[\n,]'))
                        .where((item) => item.trim().isNotEmpty)
                        .length;
                    return count == 0 ? 'Aggiungi almeno una persona.' : null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _joinViaLink, child: Text('Entra tramite link')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Annulla'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(Icons.check_rounded),
          label: Text('Crea'),
        ),
      ],
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
      title: Row(
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
                Text(
                  'Chiedi alla persona il suo codice invito Sylphy. Il core nativo controllerà identità, firme e scadenza prima di aggiungerla.',
                  style: TextStyle(
                    color: AppPalette.color(0xFFB8C1CC),
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 20),
                TextFormField(
                  key: ValueKey('contact-invitation-code'),
                  controller: _invitationController,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Codice invito',
                    hintText: 'sylphy:…',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.qr_code_2_rounded),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Incolla il codice invito.'
                      : null,
                ),
                SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: AppPalette.color(0xFFCFF36A),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Puoi ricevere e inviare subito. Verifica il fingerprint solo se vuoi contrassegnare questa persona come sicura.',
                        style: TextStyle(
                          color: AppPalette.color(0xFF9299A5),
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
          child: Text('Annulla'),
        ),
        FilledButton.icon(
          key: ValueKey('confirm-add-contact'),
          onPressed: _submit,
          icon: Icon(Icons.person_add_alt_1_rounded),
          label: Text('Aggiungi'),
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
        color: AppPalette.color(0xFF1C2221),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.color(0xFF34463A)),
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 32 : 36,
            height: compact ? 32 : 36,
            decoration: BoxDecoration(
              color: AppPalette.color(0xFF2A3D2F),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.lock_rounded,
              color: AppPalette.color(0xFFA5E5B7),
              size: 18,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  veilidSnapshot.phase == VeilidPhase.unavailable
                      ? 'Core nativo non disponibile'
                      : 'Core di sicurezza',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  veilidSnapshot.phase == VeilidPhase.unavailable
                      ? 'Nessun dato dimostrativo caricato'
                      : 'Bridge Rust + Veilid disponibile',
                  style: TextStyle(
                    color: AppPalette.color(0xFFAEB7C3),
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
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.color(0xFF1B2027),
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
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.title,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  snapshot.detail,
                  style: TextStyle(
                    color: AppPalette.color(0xFFB2BAC5),
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
              icon: Icon(Icons.refresh_rounded),
            ),
        ],
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: EdgeInsets.only(bottom: 18),
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppPalette.color(0xFF20252E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          DateUtils.isSameDay(date, DateTime.now())
              ? 'OGGI'
              : '${date.day}/${date.month}/${date.year}',
          style: TextStyle(
            color: AppPalette.color(0xFFAEB7C3),
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
      style: TextStyle(
        color: AppPalette.color(0xFF9299A5),
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
      padding: EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppPalette.color(0xFF1D222A),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppPalette.color(0xFFB8C1CC), size: 19),
          SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppPalette.color(0xFFAEB7C3),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
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
    return conversation.type == ConversationType.channel
        ? 'Canale aziendale · ${conversation.memberCount} membri'
        : 'Gruppo protetto · ${conversation.memberCount} membri';
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

void _showPrivacyOverview(
  BuildContext context,
  NativeCoreApi? nativeCore,
  VeilidService veilidService,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppPalette.color(0xFF1A1E25),
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
      final hybridResponse = nativeCore is NativeCoreClient
          ? await nativeCore.verifyHybridPrimitivesInBackground()
          : nativeCore.verifyHybridPrimitives();
      final response = hybridResponse.ok
          ? nativeCore is NativeCoreClient
                ? await nativeCore.verifyDoubleRatchetInBackground()
                : nativeCore.verifyDoubleRatchet()
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
          padding: EdgeInsets.fromLTRB(24, 8, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Privacy di Sylphy',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 12),
              Text(
                coreLoaded
                    ? 'Il bridge Rust è caricato. Il nodo Veilid usa storage isolato e accetta soltanto envelope applicativi opachi.'
                    : 'La libreria Rust non è disponibile. Sylphy resta chiuso e non mostra conversazioni dimostrative.',
                style: TextStyle(
                  color: AppPalette.color(0xFFC1C8D2),
                  height: 1.45,
                ),
              ),
              SizedBox(height: 16),
              AnimatedBuilder(
                animation: widget.veilidService,
                builder: (context, _) {
                  final snapshot = widget.veilidService.snapshot;
                  return Container(
                    padding: EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppPalette.color(0xFF141920),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppPalette.color(0xFF303741)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.hub_rounded,
                          color: _networkColor(snapshot.phase),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                snapshot.title,
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                              SizedBox(height: 2),
                              Text(
                                snapshot.detail,
                                style: TextStyle(
                                  color: AppPalette.color(0xFFAEB7C3),
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
                            icon: Icon(Icons.refresh_rounded),
                          ),
                      ],
                    ),
                  );
                },
              ),
              SizedBox(height: 18),
              _PrivacyLine(
                Icons.lock_outline_rounded,
                'Vault Argon2id + XChaCha20-Poly1305',
              ),
              SizedBox(height: 12),
              _PrivacyLine(
                Icons.key_outlined,
                'X25519 + ML-KEM-768 nel core nativo',
              ),
              SizedBox(height: 12),
              _PrivacyLine(
                Icons.sync_lock_rounded,
                'Double Ratchet Signal con chiavi per messaggio',
              ),
              SizedBox(height: 12),
              _PrivacyLine(
                Icons.hub_outlined,
                'Envelope opachi per il trasporto',
              ),
              if (coreLoaded) ...[
                SizedBox(height: 22),
                OutlinedButton.icon(
                  onPressed: _isChecking ? null : _checkNativeCore,
                  icon: _isChecking
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.verified_outlined),
                  label: Text('Verifica crittografia'),
                ),
                if (resultText != null) ...[
                  SizedBox(height: 10),
                  Text(
                    resultText,
                    style: TextStyle(
                      color: _response!.ok
                          ? AppPalette.color(0xFF9DE4B6)
                          : AppPalette.color(0xFFFFBE7A),
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
    backgroundColor: AppPalette.color(0xFF1A1E25),
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sicurezza con ${conversation.name}',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 14),
            _SafetyBadge(safety: conversation.safety),
            SizedBox(height: 20),
            Text(
              'FINGERPRINT',
              style: TextStyle(
                color: AppPalette.color(0xFF9299A5),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            SizedBox(height: 7),
            SelectableText(
              conversation.fingerprint,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 20),
            Text(
              'I messaggi sono visibili subito. La verifica è facoltativa e serve a confermare, confrontando il fingerprint fuori da Sylphy, che stai parlando con la persona giusta.',
              style: TextStyle(
                color: AppPalette.color(0xFFC1C8D2),
                height: 1.45,
              ),
            ),
            SizedBox(height: 20),
            FilledButton.icon(
              key: ValueKey('toggle-contact-verification'),
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
      title: Text('Cancellare la chat?'),
      content: Text(
        conversation.isGroup
            ? 'Uscirai da ${conversation.name} e cancellerai la cronologia locale. Non riceverai più messaggi o aggiornamenti del gruppo. Se sei il proprietario, la proprietà passerà a un amministratore oppure a un membro.'
            : 'Verranno eliminati dal dispositivo la conversazione con ${conversation.name}, i messaggi e il contatto. Questa operazione non cancella le copie sull’altro dispositivo.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Annulla'),
        ),
        FilledButton(
          key: ValueKey('confirm-delete-conversation'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Cancella'),
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
        SizedBox(width: 4),
        Icon(icon, size: 19, color: AppPalette.color(0xFFD4F66A)),
        SizedBox(width: 12),
        Expanded(
          child: Text(label, style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

Color _networkColor(VeilidPhase phase) => switch (phase) {
  VeilidPhase.attached => AppPalette.color(0xFF8CE6AC),
  VeilidPhase.connecting => AppPalette.color(0xFFCFF36A),
  VeilidPhase.degraded => AppPalette.color(0xFFFFC56B),
  VeilidPhase.offline => AppPalette.color(0xFF95A0AF),
  VeilidPhase.unavailable => AppPalette.color(0xFF77818F),
  VeilidPhase.error => AppPalette.color(0xFFFF8F86),
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
          '${item.id}|${item.name}|${item.initials}|${item.accentValue}|${Object.hashAll(item.avatarBytes ?? <int>[])}|${item.description}|${item.fingerprint}|${item.isAdmin}|${item.lastActivity.microsecondsSinceEpoch}|${item.lastMessage}|${item.unreadCount}|${item.safety.name}|${item.isOnline}|${item.type.name}|${item.memberCount}|${item.canSendMessages}|${item.groupRevision}|${item.pinnedMessageIds.join(",")}',
    )
    .join('\n');

String _signatureForMessages(List<ChatMessage> messages) => messages
    .map(
      (item) =>
          '${item.id}|${item.authorName}|${item.sentAt.microsecondsSinceEpoch}|${item.orderAt.microsecondsSinceEpoch}|${item.deliveryState.name}|${item.attachmentState}|${item.attachmentBytes?.length}',
    )
    .join('\n');
