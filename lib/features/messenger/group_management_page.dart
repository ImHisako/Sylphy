import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/messaging/secure_messaging_bridge.dart';

String groupError(Object error) {
  if (error is TimeoutException) {
    return 'Le impostazioni stanno impiegando troppo tempo. Puoi riprovare.';
  }
  final code = error is SecureMessagingException
      ? error.code
      : 'internal_error';
  return switch (code) {
    'group_permission_denied' =>
      'I permessi del gruppo non consentono questa azione.',
    'group_closed' => 'Il gruppo è stato chiuso o non ne fai più parte.',
    'slow_mode_active' =>
      'Modalità lenta attiva: attendi prima di inviare un altro messaggio.',
    'spam_rejected' =>
      'Il filtro antispam ha bloccato un messaggio ripetuto o troppo frequente.',
    'unsupported_version' =>
      'Tutti i membri devono aggiornare Sylphy e ripubblicare il proprio ID per usare la gestione gruppi.',
    'limit_exceeded' =>
      'Limite raggiunto: controlla dimensione del contenuto e numero di membri.',
    'invalid_input' =>
      'L’elemento non è più disponibile oppure i dati non sono validi.',
    _ => 'Operazione non riuscita ($code).',
  };
}

class GroupManagementPage extends StatefulWidget {
  const GroupManagementPage({
    super.key,
    required this.bridge,
    required this.conversationId,
  }) : _channelsOnly = false;

  const GroupManagementPage.channels({
    super.key,
    required this.bridge,
    required this.conversationId,
  }) : _channelsOnly = true;

  final bool _channelsOnly;
  final GroupManagementBridge bridge;
  final String conversationId;
  @override
  State<GroupManagementPage> createState() => _GroupManagementPageState();
}

class _GroupManagementPageState extends State<GroupManagementPage> {
  Map<String, dynamic>? _details;
  String? _error;
  bool _busy = false;
  Listenable? _inboxChanges;
  int _loadGeneration = 0;
  bool _loading = false;
  bool _reloadRequested = false;
  @override
  void initState() {
    super.initState();
    final bridge = widget.bridge;
    if (bridge is CachedGroupManagementBridge) {
      _details = (bridge as CachedGroupManagementBridge).cachedGroupDetails(
        widget.conversationId,
      );
    }
    _load();
    if (bridge is InboxRevisionNotifications) {
      _inboxChanges = (bridge as InboxRevisionNotifications).inboxChanges;
      _inboxChanges!.addListener(_onInboxChanged);
    }
  }

  void _onInboxChanged() {
    if (!_busy) _load();
  }

  @override
  void dispose() {
    _inboxChanges?.removeListener(_onInboxChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) {
      _reloadRequested = true;
      return;
    }
    _loading = true;
    final generation = ++_loadGeneration;
    try {
      final details = await widget.bridge
          .groupDetails(widget.conversationId)
          .timeout(const Duration(seconds: 10));
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _details = details;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = groupError(error));
      }
    } finally {
      _loading = false;
      if (_reloadRequested && mounted && _error == null) {
        _reloadRequested = false;
        unawaited(_load());
      } else {
        _reloadRequested = false;
      }
    }
  }

  bool _hasPermission(String permission) =>
      (_details?['permissions'] as Map?)?[permission] == true &&
      _details?['closed'] != true;

  bool _allowed(String permission) => !_busy && _hasPermission(permission);

  String _permissionMessage(String permission) => _details?['closed'] == true
      ? 'Il gruppo è stato chiuso o non ne fai più parte.'
      : 'Per questa azione chiedi al proprietario di assegnarti il permesso «${_adminLabels[permission]}».';

  VoidCallback? _onAction(String permission, VoidCallback action) {
    if (_busy) return null;
    return () {
      if (_hasPermission(permission)) {
        action();
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_permissionMessage(permission))));
    };
  }

  Widget _actionIndicator(String permission) => _hasPermission(permission)
      ? const Icon(Icons.chevron_right)
      : Tooltip(
          message: _permissionMessage(permission),
          child: const Icon(Icons.lock_outline),
        );

  Future<void> _act(Map<String, dynamic> action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = await widget.bridge.groupAction(
        widget.conversationId,
        action,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state == 'pending_owner'
                ? 'Richiesta inviata al proprietario. In attesa di conferma della modifica.'
                : 'Gruppo aggiornato.',
          ),
        ),
      );
      if (action['kind'] == 'close' && state == 'applied') {
        Navigator.pop(context);
        return;
      }
      await _load();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(groupError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Conferma'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _editInfo() async {
    final name = TextEditingController(
      text: _details?['name'] as String? ?? '',
    );
    final description = TextEditingController(
      text: _details?['description'] as String? ?? '',
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Informazioni del gruppo'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 64,
                decoration: const InputDecoration(labelText: 'Nome'),
              ),
              TextField(
                controller: description,
                maxLength: 1000,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Descrizione'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'kind': 'info',
              'name': name.text,
              'description': description.text,
            }),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    if (result != null) await _act(result);
  }

  Future<void> _addMembers() async {
    final codes = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aggiungi persone'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: codes,
            minLines: 3,
            maxLines: 7,
            decoration: const InputDecoration(
              labelText: 'ID Sylphy, uno per riga',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              codes.text
                  .split(RegExp(r'\s+'))
                  .where((code) => code.isNotEmpty)
                  .toList(),
            ),
            child: const Text('Aggiungi'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _act({'kind': 'add_members', 'invitation_codes': result});
    }
  }

  Future<void> _editPolicy({Map? member}) async {
    final initial = member == null
        ? (_details?['policy'] as Map?)
        : (member['restriction'] as Map?);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _PolicyDialog(
        initial: initial,
        memberName: member?['name'] as String?,
      ),
    );
    if (result == null) return;
    await _act(
      member == null
          ? {'kind': 'policy', 'policy': result}
          : {'kind': 'restrict', 'member_id': member['id'], 'policy': result},
    );
  }

  Future<void> _editChannel([Map? channel]) async {
    var name = channel?['name'] as String? ?? '';
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(channel == null ? 'Crea canale' : 'Rinomina canale'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: name,
            onChanged: (value) => name = value,
            autofocus: true,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'Nome del canale'),
            validator: (value) {
              final candidate = value?.trim() ?? '';
              if (candidate.isEmpty) return 'Inserisci un nome.';
              final duplicate = (_details?['channels'] as List? ?? []).any(
                (item) =>
                    item['id'] != channel?['id'] &&
                    (item['name'] as String).toLowerCase() ==
                        candidate.toLowerCase(),
              );
              return duplicate ? 'Esiste già un canale con questo nome.' : null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, name.trim());
              }
            },
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await _act(
      channel == null
          ? {'kind': 'create_channel', 'name': result}
          : {
              'kind': 'rename_channel',
              'channel_id': channel['id'],
              'name': result,
            },
    );
  }

  Future<void> _openChannels() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GroupManagementPage.channels(
          bridge: widget.bridge,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted) await _load();
  }

  bool get _channelsPending =>
      (_details?['pending_actions'] as List? ?? []).any(
        (action) => const [
          'create_channel',
          'rename_channel',
          'delete_channel',
          'move_channel',
        ].contains(action['kind']),
      );

  bool get _canManageChannels => _allowed('change_info') && !_channelsPending;

  Future<void> _moveChannel(
    List<Map> snapshot,
    int oldIndex,
    int newIndex,
  ) async {
    if (!_canManageChannels) return;
    final channels = List<Map>.from(snapshot);
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final moved = channels.removeAt(oldIndex);
    await _act({
      'kind': 'move_channel',
      'channel_id': moved['id'],
      'before_channel_id': newIndex < channels.length
          ? channels[newIndex]['id']
          : null,
    });
  }

  Future<void> _deleteChannel(Map channel) async {
    if (!_canManageChannels || !_hasPermission('delete_messages')) return;
    if (await _confirm(
          'Elimina canale',
          'Eliminare «${channel['name']}» e tutti i suoi messaggi per il gruppo? Questa azione non può essere annullata.',
        ) &&
        mounted) {
      await _act({'kind': 'delete_channel', 'channel_id': channel['id']});
    }
  }

  Widget _buildChannels(Map<String, dynamic> details) {
    final channels = (details['channels'] as List? ?? []).cast<Map>();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ReorderableListView.builder(
          key: const ValueKey('manage-channel-list'),
          padding: const EdgeInsets.all(16),
          buildDefaultDragHandles: false,
          // Keep compatibility with the Flutter 3.35 release toolchain.
          // ignore: deprecated_member_use
          onReorder: (oldIndex, newIndex) =>
              _moveChannel(channels, oldIndex, newIndex),
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Text(
                details['name'] as String,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Trascina i canali per cambiarne l’ordine oppure usa il menu accanto al nome.',
              ),
              if (!_hasPermission('change_info'))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_permissionMessage('change_info')),
                ),
              if (_channelsPending)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Modifica dei canali in attesa di conferma del proprietario.',
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('create-group-channel'),
                onPressed: _canManageChannels && channels.length < 50
                    ? () => _editChannel()
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('Crea canale'),
              ),
              const SizedBox(height: 16),
              const ListTile(
                leading: Icon(Icons.chat_bubble_outline),
                title: Text('Generale'),
                subtitle: Text('Sempre disponibile · posizione fissa'),
                trailing: Icon(Icons.lock_outline),
              ),
              const Divider(),
              if (channels.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nessun canale aggiuntivo. Crea il primo canale del gruppo.',
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
          itemCount: channels.length,
          itemBuilder: (context, index) {
            final channel = channels[index];
            return ListTile(
              key: ValueKey('manage-channel-${channel['id']}'),
              leading: const Icon(Icons.tag),
              title: Text(
                channel['name'] as String,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Gestisci ${channel['name']}',
                    enabled: _canManageChannels,
                    onSelected: (action) async {
                      if (!_canManageChannels) return;
                      switch (action) {
                        case 'rename':
                          await _editChannel(channel);
                        case 'up':
                          await _moveChannel(channels, index, index - 1);
                        case 'down':
                          await _moveChannel(channels, index, index + 2);
                        case 'delete':
                          await _deleteChannel(channel);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rinomina'),
                      ),
                      PopupMenuItem(
                        value: 'up',
                        enabled: index > 0,
                        child: const Text('Sposta su'),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled: index < channels.length - 1,
                        child: const Text('Sposta giù'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: _hasPermission('delete_messages'),
                        child: const Text('Elimina canale'),
                      ),
                    ],
                  ),
                  ReorderableDragStartListener(
                    key: ValueKey('drag-channel-${channel['id']}'),
                    index: index,
                    enabled: _canManageChannels,
                    child: const Tooltip(
                      message: 'Trascina per spostare',
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _editAdmin(Map member) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _AdminDialog(
        name: member['name'] as String,
        initial: member['permissions'] as Map?,
        available: _details?['permissions'] as Map? ?? {},
      ),
    );
    if (result != null) {
      await _act({
        'kind': 'set_admin',
        'member_id': member['id'],
        'permissions': result['revoke_role'] == true
            ? null
            : result['permissions'],
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget._channelsOnly ? 'Gestisci canali' : 'Gestisci gruppo',
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: details == null
          ? Center(
              child: _error == null
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Caricamento impostazioni del gruppo…'),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!),
                        ),
                        FilledButton.icon(
                          onPressed: () {
                            setState(() => _error = null);
                            _load();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Riprova'),
                        ),
                      ],
                    ),
            )
          : widget._channelsOnly
          ? _buildChannels(details)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ListTile(
                      title: Text(
                        details['name'] as String,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      subtitle: Text(details['description'] as String? ?? ''),
                      trailing: IconButton(
                        tooltip: _hasPermission('change_info')
                            ? 'Modifica informazioni'
                            : _permissionMessage('change_info'),
                        onPressed: _onAction('change_info', _editInfo),
                        icon: Icon(
                          _hasPermission('change_info')
                              ? Icons.edit_outlined
                              : Icons.lock_outline,
                        ),
                      ),
                    ),
                    Card(
                      child: Column(
                        children: [
                          SwitchListTile(
                            key: const ValueKey('group-action-notices'),
                            secondary: const Icon(Icons.campaign_outlined),
                            title: const Text('Avvisi delle azioni in chat'),
                            subtitle: const Text(
                              'Mostra gli avvisi per permessi, membri, messaggi eliminati e fissati.',
                            ),
                            value: details['show_action_notices'] != false,
                            onChanged: _allowed('manage_permissions')
                                ? (enabled) => _act({
                                    'kind': 'action_notices',
                                    'enabled': enabled,
                                  })
                                : null,
                          ),
                          const Divider(),
                          ListTile(
                            key: const ValueKey('open-group-channels'),
                            leading: const Icon(Icons.view_list_outlined),
                            title: const Text('Gestisci canali'),
                            subtitle: const Text(
                              'Crea, rinomina, elimina e riordina i canali.',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _busy ? null : _openChannels,
                          ),
                          ListTile(
                            leading: const Icon(Icons.tune),
                            title: const Text('Permessi e antispam'),
                            subtitle: Text(
                              (details['policy'] as Map?)?['send_messages'] !=
                                      false
                                  ? 'Tutti i membri possono scrivere'
                                  : 'Scrivono solo gli amministratori',
                            ),
                            trailing: _actionIndicator('manage_permissions'),
                            onTap: _onAction(
                              'manage_permissions',
                              () => _editPolicy(),
                            ),
                          ),
                          ListTile(
                            leading: const Icon(Icons.person_add_alt),
                            title: const Text('Aggiungi persone'),
                            subtitle: const Text('Invita usando gli ID Sylphy'),
                            trailing: _actionIndicator('invite_members'),
                            onTap: _onAction('invite_members', _addMembers),
                          ),
                          ListTile(
                            leading: const Icon(Icons.link),
                            title: const Text('Crea link di invito'),
                            subtitle: const Text(
                              'Valido 7 giorni; un nuovo link sostituisce quello precedente.',
                            ),
                            trailing: _actionIndicator('invite_members'),
                            onTap: _onAction(
                              'invite_members',
                              () => _act({'kind': 'invite_link'}),
                            ),
                          ),
                          if (details['invite_link'] case final String link)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  SelectableText(link, maxLines: 3),
                                  Row(
                                    children: [
                                      TextButton.icon(
                                        onPressed: () async {
                                          await Clipboard.setData(
                                            ClipboardData(text: link),
                                          );
                                        },
                                        icon: const Icon(Icons.copy),
                                        label: const Text('Copia link'),
                                      ),
                                      TextButton(
                                        onPressed: _allowed('invite_members')
                                            ? () => _act({
                                                'kind': 'revoke_invite_link',
                                              })
                                            : null,
                                        child: const Text('Revoca link'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if ((details['pinned'] as List? ?? []).isNotEmpty) ...[
                      Text(
                        'Messaggi fissati',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final id
                          in (details['pinned'] as List).cast<String>())
                        ListTile(
                          leading: const Icon(Icons.push_pin_outlined),
                          title: const Text('Apri messaggio fissato'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => ChatSearchPage(
                                bridge: widget.bridge,
                                conversationId: widget.conversationId,
                                initialQuery: 'id:$id',
                                allowReply: false,
                              ),
                            ),
                          ),
                          trailing: _allowed('pin_messages')
                              ? IconButton(
                                  tooltip: 'Rimuovi dai fissati',
                                  icon: const Icon(Icons.close),
                                  onPressed: () => _act({
                                    'kind': 'pin',
                                    'message_id': id,
                                    'pinned': false,
                                  }),
                                )
                              : null,
                        ),
                      const SizedBox(height: 20),
                    ],
                    Text(
                      'Membri e amministratori',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final member
                        in (details['members'] as List).cast<Map>())
                      Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              member['is_owner'] == true
                                  ? Icons.workspace_premium
                                  : member['permissions'] != null
                                  ? Icons.shield_outlined
                                  : Icons.person_outline,
                            ),
                          ),
                          title: Text(member['name'] as String),
                          subtitle: Text(
                            member['is_owner'] == true
                                ? 'Proprietario'
                                : member['permissions'] != null
                                ? 'Amministratore'
                                : member['restriction'] != null
                                ? 'Membro con restrizioni'
                                : 'Membro',
                          ),
                          trailing:
                              member['is_owner'] == true ||
                                  (!_allowed('add_admins') &&
                                      !_allowed('manage_members'))
                              ? null
                              : PopupMenuButton<String>(
                                  tooltip: 'Gestisci membro',
                                  onSelected: (action) async {
                                    if (action == 'admin') {
                                      await _editAdmin(member);
                                    } else if (action == 'restrict') {
                                      await _editPolicy(member: member);
                                    } else if (action == 'reset') {
                                      await _act({
                                        'kind': 'restrict',
                                        'member_id': member['id'],
                                        'policy': null,
                                      });
                                    } else if (action == 'remove' &&
                                        await _confirm(
                                          'Rimuovi membro',
                                          'Rimuovere ${member['name']} dal gruppo?',
                                        )) {
                                      await _act({
                                        'kind': 'remove_member',
                                        'member_id': member['id'],
                                      });
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (_allowed('add_admins'))
                                      const PopupMenuItem(
                                        value: 'admin',
                                        child: Text('Ruolo e privilegi'),
                                      ),
                                    if (_allowed('manage_members')) ...[
                                      if (member['permissions'] == null)
                                        const PopupMenuItem(
                                          value: 'restrict',
                                          child: Text(
                                            'Restrizioni e modalità lenta',
                                          ),
                                        ),
                                      if (member['permissions'] == null &&
                                          member['restriction'] != null)
                                        const PopupMenuItem(
                                          value: 'reset',
                                          child: Text('Rimuovi restrizioni'),
                                        ),
                                      const PopupMenuItem(
                                        value: 'remove',
                                        child: Text('Rimuovi dal gruppo'),
                                      ),
                                    ],
                                  ],
                                ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    if (details['is_owner'] == true)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        icon: const Icon(Icons.delete_forever),
                        label: const Text('Elimina gruppo per tutti'),
                        onPressed: _busy
                            ? null
                            : () async {
                                if (await _confirm(
                                  'Elimina gruppo per tutti',
                                  'La chat sarà chiusa e la cronologia locale eliminata sui client aggiornati. I dispositivi offline riceveranno il comando quando torneranno online; copie esportate e screenshot non possono essere rimossi.',
                                )) {
                                  await _act({'kind': 'close'});
                                }
                              },
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Le modifiche degli amministratori delegati vengono coordinate dal proprietario. Nuovi membri vedono i messaggi successivi al loro ingresso.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

const _policyLabels = {
  'send_messages': 'Inviare messaggi',
  'send_media': 'Inviare media e file',
  'send_links': 'Inviare link',
};

class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog({this.initial, this.memberName});
  final Map? initial;
  final String? memberName;
  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late final Map<String, dynamic> _value = {
    for (final key in _policyLabels.keys) key: widget.initial?[key] != false,
    'slow_mode_seconds': widget.initial?['slow_mode_seconds'] ?? 0,
    'aggressive_antispam': widget.initial?['aggressive_antispam'] == true,
  };
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.memberName == null
          ? 'Permessi del gruppo'
          : 'Restrizioni · ${widget.memberName}',
    ),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _policyLabels.entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item.value),
                value: _value[item.key] as bool,
                onChanged: (value) => setState(() => _value[item.key] = value),
              ),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _value['slow_mode_seconds'] as int,
              decoration: const InputDecoration(labelText: 'Modalità lenta'),
              items:
                  {
                        0,
                        10,
                        30,
                        60,
                        300,
                        900,
                        3600,
                        _value['slow_mode_seconds'] as int,
                      }
                      .map(
                        (seconds) => DropdownMenuItem(
                          value: seconds,
                          child: Text(
                            seconds == 0
                                ? 'Disattivata'
                                : 'Un messaggio ogni $seconds secondi',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (seconds) =>
                  setState(() => _value['slow_mode_seconds'] = seconds ?? 0),
            ),
            if (widget.memberName == null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Antispam aggressivo'),
                subtitle: const Text(
                  'Blocca ripetizioni, invii troppo frequenti e menzioni in massa.',
                ),
                value: _value['aggressive_antispam'] as bool,
                onChanged: (value) =>
                    setState(() => _value['aggressive_antispam'] = value),
              ),
            const Text(
              'Gli amministratori sono esenti dalle restrizioni di invio. Le restrizioni individuali si aggiungono a quelle del gruppo.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annulla'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _value),
        child: const Text('Salva'),
      ),
    ],
  );
}

const _adminLabels = {
  'delete_messages': 'Eliminare messaggi',
  'manage_members': 'Gestire e limitare membri',
  'change_info': 'Cambiare informazioni',
  'invite_members': 'Invitare persone',
  'add_admins': 'Aggiungere amministratori',
  'pin_messages': 'Fissare messaggi',
  'manage_permissions': 'Cambiare permessi e antispam',
};

class _AdminDialog extends StatefulWidget {
  const _AdminDialog({
    required this.name,
    required this.available,
    this.initial,
  });
  final String name;
  final Map available;
  final Map? initial;
  @override
  State<_AdminDialog> createState() => _AdminDialogState();
}

class _AdminDialogState extends State<_AdminDialog> {
  late final Map<String, dynamic> _value = {
    for (final key in _adminLabels.keys) key: widget.initial?[key] == true,
  };
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Amministratore · ${widget.name}'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _adminLabels.entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item.value),
                value: _value[item.key] as bool,
                onChanged: widget.available[item.key] == true
                    ? (value) => setState(() => _value[item.key] = value)
                    : null,
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.initial != null)
        TextButton(
          onPressed: () => Navigator.pop(context, {'revoke_role': true}),
          child: const Text('Revoca ruolo'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annulla'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'permissions': Map<String, dynamic>.from(_value),
        }),
        child: const Text('Salva'),
      ),
    ],
  );
}

class ChatSearchPage extends StatefulWidget {
  const ChatSearchPage({
    super.key,
    required this.bridge,
    required this.conversationId,
    this.initialQuery = '',
    this.allowReply = true,
    this.pinnedMessageIds,
  });
  final GroupManagementBridge bridge;
  final String conversationId;
  final String initialQuery;
  final bool allowReply;
  final List<String>? pinnedMessageIds;
  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends State<ChatSearchPage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  Timer? _debounce;
  int _generation = 0;
  List<Map> _results = [];
  bool _loading = false;
  bool _hasMore = false;
  int _total = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty || widget.pinnedMessageIds != null) {
      _search();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search({bool more = false}) async {
    final generation = ++_generation;
    final query = _query.text.trim();
    if (query.isEmpty && widget.pinnedMessageIds == null) {
      setState(() {
        _results = [];
        _hasMore = false;
        _loading = false;
        _total = 0;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _results = [];
    });
    try {
      final Map<String, dynamic> response;
      if (widget.pinnedMessageIds case final ids?) {
        final pages = await Future.wait(
          ids.map(
            (id) =>
                widget.bridge.searchMessages(widget.conversationId, 'id:$id'),
          ),
        );
        final messages = pages
            .expand((page) => page['messages'] as List)
            .toList();
        response = {
          'messages': messages,
          'total': messages.length,
          'has_more': false,
        };
      } else {
        response = await widget.bridge.searchMessages(
          widget.conversationId,
          query,
          offset: more ? _results.length : 0,
        );
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = [
          ...(more ? _results : <Map>[]),
          ...(response['messages'] as List).cast<Map>(),
        ];
        _hasMore = response['has_more'] == true;
        _total = response['total'] as int;
        _loading = false;
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = groupError(error);
          _loading = false;
        });
      }
    }
  }

  Future<void> _openMessage(Map message) async {
    final reply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Messaggio'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(message['body'] as String),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Chiudi'),
          ),
          if (widget.allowReply)
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.reply),
              label: const Text('Rispondi'),
            ),
        ],
      ),
    );
    if (mounted && reply == true) Navigator.pop(context, message);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.pinnedMessageIds != null
            ? 'Messaggi fissati'
            : 'Cerca nella chat',
      ),
    ),
    body: Column(
      children: [
        if (widget.pinnedMessageIds == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Testo, @menzioni o #hashtag',
              ),
              onChanged: (_) {
                _generation++;
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 220), _search);
              },
            ),
          ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (widget.pinnedMessageIds != null &&
            !_loading &&
            _results.isEmpty &&
            _error == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Il contenuto dei messaggi fissati non è disponibile su questo dispositivo.',
            ),
          ),
        if (_query.text.trim().isNotEmpty && !_loading)
          Text('$_total risultati'),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _results.length) {
                return TextButton(
                  onPressed: _loading ? null : () => _search(more: true),
                  child: const Text('Altri risultati'),
                );
              }
              final message = _results[index];
              final date = DateTime.fromMillisecondsSinceEpoch(
                message['sent_at_ms'] as int,
              ).toLocal();
              return ListTile(
                title: Text(
                  message['body'] as String,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${message['author_name'] ?? ''} · ${date.day}/${date.month}/${date.year} · ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _openMessage(message),
              );
            },
          ),
        ),
      ],
    ),
  );
}
