import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/native/native_core.dart';
import '../../core/privacy/privacy_settings.dart';
import '../../core/veilid/veilid_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.veilidService,
    required this.privacySettings,
    this.nativeCore,
  });

  final VeilidService veilidService;
  final NativeCoreApi? nativeCore;
  final PrivacySettingsController privacySettings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _diagnosticResult;
  bool _diagnosticRunning = false;

  Future<void> _runDiagnostics() async {
    if (_diagnosticRunning) {
      return;
    }
    setState(() {
      _diagnosticRunning = true;
      _diagnosticResult = null;
    });
    AppLog.instance.record(
      category: 'developer_options',
      action: 'diagnostic_check_started',
      force: true,
    );
    try {
      final core = widget.nativeCore;
      if (core == null) {
        _diagnosticResult = 'Core nativo non caricato.';
      } else {
        final status = core.status();
        await widget.veilidService.retry();
        final network = widget.veilidService.snapshot;
        _diagnosticResult = status.ok
            ? 'Core ABI disponibile · Veilid: ${network.phase.name}'
            : 'Core: ${status.code} · Veilid: ${network.diagnosticCode ?? network.phase.name}';
      }
      AppLog.instance.record(
        category: 'developer_options',
        action: 'diagnostic_check_completed',
        result:
            widget.veilidService.snapshot.diagnosticCode ??
            widget.veilidService.snapshot.phase.name,
        force: true,
      );
    } on Object catch (error) {
      _diagnosticResult = 'Verifica interrotta: ${error.runtimeType}';
      AppLog.instance.recordError(
        category: 'developer_options',
        action: 'diagnostic_check_failed',
        error: error,
      );
    } finally {
      if (mounted) {
        setState(() => _diagnosticRunning = false);
      }
    }
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: AppLog.instance.exportText()));
    AppLog.instance.record(
      category: 'developer_options',
      action: 'diagnostic_log_copied',
      force: true,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Log diagnostici copiati.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: AnimatedBuilder(
        animation: Listenable.merge([
          AppLog.instance,
          widget.veilidService,
          widget.privacySettings,
        ]),
        builder: (context, _) {
          final snapshot = widget.veilidService.snapshot;
          final privacy = widget.privacySettings.value;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _SettingsCard(
                child: ListTile(
                  leading: Icon(
                    Icons.hub_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(snapshot.title),
                  subtitle: Text(snapshot.detail),
                  trailing: IconButton(
                    tooltip: 'Riprova connessione',
                    onPressed: widget.veilidService.retry,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const _SectionTitle('PRIVACY DEL PROFILO'),
              const SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('share-display-name'),
                      secondary: const Icon(Icons.badge_outlined),
                      title: const Text('Mostra il nome profilo'),
                      subtitle: const Text(
                        'Consenti ai contatti di vedere il nome che hai scelto.',
                      ),
                      value: privacy.shareDisplayName,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(shareDisplayName: value),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      key: const ValueKey('share-profile-photo'),
                      secondary: const Icon(Icons.account_circle_outlined),
                      title: const Text('Mostra la foto profilo'),
                      subtitle: const Text(
                        'Condividi la foto solo con i contatti Sylphy.',
                      ),
                      value: privacy.shareProfilePhoto,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(shareProfilePhoto: value),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.circle_outlined),
                      title: const Text('Mostra quando sei online'),
                      value: privacy.showOnlineStatus,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(showOnlineStatus: value),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.schedule_outlined),
                      title: const Text('Mostra ultimo accesso'),
                      value: privacy.showLastSeen,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(showLastSeen: value),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionTitle('MESSAGGI E SPUNTE'),
              const SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('send-read-receipts'),
                      secondary: const Icon(Icons.done_all_rounded),
                      title: const Text('Conferme di lettura'),
                      subtitle: const Text(
                        'Se disattivate, l’altro utente non vedrà le doppie spunte di lettura.',
                      ),
                      value: privacy.sendReadReceipts,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(sendReadReceipts: value),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      key: const ValueKey('show-read-receipts'),
                      secondary: const Icon(Icons.visibility_outlined),
                      title: const Text('Mostra spunte ricevute'),
                      subtitle: const Text(
                        'Nasconde le spunte solo nella tua interfaccia.',
                      ),
                      value: privacy.showReadReceipts,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(showReadReceipts: value),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionTitle('CONTATTI E ACCESSIBILITÀ'),
              const SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.person_search_outlined),
                      title: const Text('Richieste da sconosciuti'),
                      subtitle: const Text(
                        'Accetta nuove richieste soltanto quando è attivo.',
                      ),
                      value: privacy.allowUnknownContacts,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(allowUnknownContacts: value),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.motion_photos_off_outlined),
                      title: const Text('Riduci animazioni'),
                      value: privacy.reduceMotion,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(reduceMotion: value),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'DEVELOPER OPTIONS',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF9299A5),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('developer-logging-switch'),
                      secondary: const Icon(Icons.bug_report_outlined),
                      title: const Text('Logging dettagliato'),
                      subtitle: const Text(
                        'Registra lifecycle, navigazione, azioni UI e chiamate al core. Testi dei messaggi, password e chiavi sono sempre esclusi.',
                      ),
                      value: AppLog.instance.verboseEnabled,
                      onChanged: AppLog.instance.setVerboseEnabled,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.health_and_safety_outlined),
                      title: const Text('Esegui diagnostica'),
                      subtitle: _diagnosticResult == null
                          ? const Text(
                              'Controlla core nativo, bootstrap e Veilid.',
                            )
                          : Text(_diagnosticResult!),
                      trailing: _diagnosticRunning
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _diagnosticRunning ? null : _runDiagnostics,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'LOG (${AppLog.instance.entries.length})',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF9299A5),
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Copia log',
                    onPressed: _copyLogs,
                    icon: const Icon(Icons.copy_all_outlined),
                  ),
                  IconButton(
                    tooltip: 'Cancella log',
                    onPressed: AppLog.instance.clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
              _LogViewer(entries: AppLog.instance.entries),
              if (AppLog.instance.logFilePath case final path?) ...[
                const SizedBox(height: 10),
                SelectableText(
                  'File persistente: $path',
                  style: const TextStyle(
                    color: Color(0xFF7F8997),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF151A21),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF303741)),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: const Color(0xFF9299A5),
      fontWeight: FontWeight.w800,
      letterSpacing: 1.1,
    ),
  );
}

class _LogViewer extends StatelessWidget {
  const _LogViewer({required this.entries});

  final List<AppLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final visibleEntries = entries.reversed.take(300).toList(growable: false);
    return Container(
      key: const ValueKey('developer-log-viewer'),
      constraints: const BoxConstraints(minHeight: 180, maxHeight: 420),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF090C11),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF303741)),
      ),
      child: visibleEntries.isEmpty
          ? const Center(
              child: Text(
                'Nessun evento registrato.',
                style: TextStyle(color: Color(0xFF9299A5)),
              ),
            )
          : Scrollbar(
              child: ListView.separated(
                itemCount: visibleEntries.length,
                separatorBuilder: (context, index) => const Divider(height: 12),
                itemBuilder: (context, index) {
                  final entry = visibleEntries[index];
                  return SelectableText(
                    entry.formatted,
                    style: TextStyle(
                      color: _logColor(entry.level),
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  );
                },
              ),
            ),
    );
  }
}

Color _logColor(AppLogLevel level) => switch (level) {
  AppLogLevel.debug => const Color(0xFF9299A5),
  AppLogLevel.info => const Color(0xFFC8D0DA),
  AppLogLevel.warning => const Color(0xFFFFC56B),
  AppLogLevel.error => const Color(0xFFFF8F86),
};
