import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Android owns sound and vibration settings for the existing message channel.
/// The enabled preference is stored natively so the background worker reads it
/// even when Flutter is not running.
class AndroidNotificationSettings extends StatefulWidget {
  const AndroidNotificationSettings({super.key});

  @override
  State<AndroidNotificationSettings> createState() =>
      _AndroidNotificationSettingsState();
}

class _AndroidNotificationSettingsState
    extends State<AndroidNotificationSettings>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('sylphy/platform');
  Map<Object?, Object?>? _settings;
  bool _busy = false;
  bool _refreshPending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_busy) {
        _refreshPending = true;
      } else {
        unawaited(_run());
      }
    }
  }

  Future<void> _run({String? method, Object? arguments}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (method != null) {
        await _channel.invokeMethod<Object?>(method, arguments);
      }
      final settings = await _channel.invokeMapMethod<Object?, Object?>(
        'getNotificationSettings',
      );
      if (settings == null || settings['enabled'] is! bool) {
        throw const FormatException('Missing Android notification settings');
      }
      if (mounted) setState(() => _settings = settings);
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              'Impossibile aggiornare le impostazioni delle notifiche. Riprova.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_run());
        }
      }
    }
  }

  String _channelStatus(String key, {required bool feminine}) {
    final value = _settings?[key];
    if (value is! bool) return 'Gestisci nelle impostazioni Android';
    final state = value
        ? (feminine ? 'Attiva' : 'Attivo')
        : (feminine ? 'Disattivata' : 'Disattivato');
    return '$state in Android · Tocca per modificare';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _settings != null && !_busy;
    final blockedByAndroid =
        _settings != null &&
        (_settings!['system_enabled'] != true ||
            _settings!['channel_enabled'] != true);
    return Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        SwitchListTile(
          key: const ValueKey('message-notifications'),
          secondary: const Icon(Icons.notifications_outlined),
          title: const Text('Notifiche dei messaggi'),
          subtitle: const Text(
            'Avvisi per nuovi messaggi e messaggi fissati, anche in background. '
            'Disattivarli non interrompe la ricezione dei messaggi.',
          ),
          value: _settings?['enabled'] == true,
          onChanged: ready
              ? (value) =>
                    _run(method: 'setNotificationsEnabled', arguments: value)
              : null,
        ),
        if (blockedByAndroid)
          ListTile(
            key: const ValueKey('notifications-blocked'),
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text('Notifiche bloccate da Android'),
            subtitle: const Text(
              'Tocca per controllare autorizzazioni e notifiche dei messaggi.',
            ),
            trailing: const Icon(Icons.open_in_new_rounded),
            onTap: _busy
                ? null
                : () => _run(
                    method: 'openNotificationSettings',
                    arguments: _settings?['system_enabled'] == true,
                  ),
          ),
        const Divider(height: 1),
        ListTile(
          key: const ValueKey('notification-sound'),
          leading: const Icon(Icons.volume_up_outlined),
          title: const Text('Suono delle notifiche'),
          subtitle: Text(_channelStatus('sound_enabled', feminine: false)),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: ready
              ? () => _run(method: 'openNotificationSettings', arguments: true)
              : null,
        ),
        const Divider(height: 1),
        ListTile(
          key: const ValueKey('notification-vibration'),
          leading: const Icon(Icons.vibration_rounded),
          title: const Text('Vibrazione delle notifiche'),
          subtitle: Text(_channelStatus('vibration_enabled', feminine: true)),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: ready
              ? () => _run(method: 'openNotificationSettings', arguments: true)
              : null,
        ),
        const Divider(height: 1),
        ListTile(
          key: const ValueKey('android-notification-settings'),
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Impostazioni notifiche Android'),
          subtitle: const Text(
            'Autorizzazioni, schermata di blocco e altre opzioni. '
            'Suono e vibrazione rispettano il silenzioso e Non disturbare del telefono.',
          ),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: _busy
              ? null
              : () =>
                    _run(method: 'openNotificationSettings', arguments: false),
        ),
        if (_error != null)
          ListTile(
            title: Text(_error!),
            trailing: TextButton(
              onPressed: _busy ? null : () => _run(),
              child: const Text('Riprova'),
            ),
          ),
      ],
    );
  }
}
