import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/identity/account_transfer_service.dart';
import '../../core/native/native_core.dart';
import '../../core/profile/user_profile.dart';
import '../../core/privacy/privacy_settings.dart';
import '../../core/veilid/veilid_service.dart';
import 'account_qr_scanner_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.veilidService,
    required this.privacySettings,
    required this.profile,
    required this.onAccountImported,
    this.nativeCore,
  });

  final VeilidService veilidService;
  final NativeCoreApi? nativeCore;
  final PrivacySettingsController privacySettings;
  final UserProfile profile;
  final ValueChanged<UserProfile> onAccountImported;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _diagnosticResult;
  bool _diagnosticRunning = false;
  bool _accountTransferRunning = false;
  String? _accountTransferResult;

  Future<String?> _requestTransferPassword({
    required bool confirm,
    String? actionLabel,
  }) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(confirm ? 'Proteggi il trasferimento' : 'Apri account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                confirm
                    ? 'Scegli una password di almeno 10 caratteri. Servirà sull’altro dispositivo e non viene salvata.'
                    : 'Inserisci la password scelta quando hai creato il file account.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (confirm) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: second,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Ripeti password',
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: const TextStyle(color: Color(0xFFFF9D95))),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () {
                if (first.text.characters.length < 10) {
                  setDialogState(() => error = 'Usa almeno 10 caratteri.');
                  return;
                }
                if (confirm && first.text != second.text) {
                  setDialogState(() => error = 'Le password non coincidono.');
                  return;
                }
                Navigator.of(dialogContext).pop(first.text);
              },
              child: Text(actionLabel ?? (confirm ? 'Crea file' : 'Continua')),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    second.dispose();
    return result;
  }

  NativeCoreClient? _transferCoreOrExplain() {
    final core = widget.nativeCore;
    if (core is NativeCoreClient) return core;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Trasferimento non disponibile: installa la versione Sylphy più recente.',
        ),
      ),
    );
    return null;
  }

  Future<void> _linkAnotherDevice() async {
    if (_accountTransferRunning || _transferCoreOrExplain() == null) return;
    if (!_isDesktopPlatform) {
      await _exportAccount();
      return;
    }
    final choice = await showModalBottomSheet<_AccountExportMethod>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  'Collega un altro dispositivo',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text('Scegli come trasferire l’account cifrato.'),
              ),
              ListTile(
                key: const ValueKey('export-account-qr'),
                leading: const Icon(Icons.qr_code_2_rounded),
                title: const Text('Mostra QR Code'),
                subtitle: const Text(
                  'Trasferimento diretto sulla stessa rete Wi-Fi o LAN.',
                ),
                onTap: () =>
                    Navigator.pop(context, _AccountExportMethod.qrCode),
              ),
              ListTile(
                key: const ValueKey('export-account-file'),
                leading: const Icon(Icons.save_alt_rounded),
                title: const Text('Salva file cifrato'),
                subtitle: const Text(
                  'Metodo compatibile con tutti i dispositivi.',
                ),
                onTap: () => Navigator.pop(context, _AccountExportMethod.file),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == _AccountExportMethod.qrCode) {
      await _exportAccountViaQr();
    } else {
      await _exportAccount();
    }
  }

  Future<void> _exportAccount() async {
    final core = _transferCoreOrExplain();
    if (core == null || _accountTransferRunning) return;
    final password = await _requestTransferPassword(confirm: true);
    if (password == null || !mounted) return;
    setState(() {
      _accountTransferRunning = true;
      _accountTransferResult = null;
    });
    try {
      final path = await AccountTransferService(
        nativeCore: core,
      ).exportToFile(profile: widget.profile, transferPassword: password);
      if (mounted) {
        setState(() {
          _accountTransferResult = path == null
              ? 'Esportazione annullata.'
              : 'File account cifrato creato. Trasferiscilo sull’altro dispositivo.';
        });
      }
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'account',
        action: 'export_failed',
        error: error,
      );
      if (mounted) {
        setState(() => _accountTransferResult = 'Esportazione non riuscita.');
      }
    } finally {
      if (mounted) setState(() => _accountTransferRunning = false);
    }
  }

  Future<void> _exportAccountViaQr() async {
    final core = _transferCoreOrExplain();
    if (core == null || _accountTransferRunning) return;
    final password = await _requestTransferPassword(
      confirm: true,
      actionLabel: 'Mostra QR',
    );
    if (password == null || !mounted) return;
    setState(() {
      _accountTransferRunning = true;
      _accountTransferResult = 'Preparazione del trasferimento sicuro…';
    });
    AccountQrTransferSession? session;
    try {
      final service = AccountTransferService(nativeCore: core);
      final document = await service.createBackupDocument(
        profile: widget.profile,
        transferPassword: password,
      );
      session = await AccountQrTransferSession.start(document);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _AccountQrDialog(session: session!),
      );
      if (mounted) {
        setState(() {
          _accountTransferResult =
              session!.state.value == AccountQrTransferState.transferred
              ? 'Account inviato al telefono.'
              : 'Trasferimento QR chiuso.';
        });
      }
    } on AccountTransferException catch (error) {
      AppLog.instance.recordError(
        category: 'account',
        action: 'qr_export_failed',
        error: error,
      );
      if (mounted) {
        setState(() {
          _accountTransferResult = error.code == 'no_local_network'
              ? 'Collega computer e telefono alla stessa rete e riprova.'
              : 'Impossibile avviare il trasferimento QR.';
        });
      }
    } finally {
      await session?.dispose();
      if (mounted) setState(() => _accountTransferRunning = false);
    }
  }

  Future<void> _importAccount() async {
    final core = _transferCoreOrExplain();
    if (core == null || _accountTransferRunning) return;
    String? qrPayload;
    var useQr = false;
    if (_isMobilePlatform) {
      final source = await showModalBottomSheet<_AccountImportMethod>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  'Usa un account esistente',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text('Scegli il computer o un file già esportato.'),
              ),
              ListTile(
                key: const ValueKey('import-account-qr'),
                leading: const Icon(Icons.qr_code_scanner_rounded),
                title: const Text('Scansiona QR dal computer'),
                onTap: () =>
                    Navigator.pop(context, _AccountImportMethod.qrCode),
              ),
              ListTile(
                key: const ValueKey('import-account-file'),
                leading: const Icon(Icons.file_open_outlined),
                title: const Text('Scegli file account'),
                onTap: () => Navigator.pop(context, _AccountImportMethod.file),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (!mounted || source == null) return;
      useQr = source == _AccountImportMethod.qrCode;
      if (useQr) {
        qrPayload = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            settings: const RouteSettings(name: '/account-qr-scanner'),
            builder: (context) => const AccountQrScannerPage(),
          ),
        );
        if (!mounted || qrPayload == null) return;
      }
    }
    final password = await _requestTransferPassword(confirm: false);
    if (password == null || !mounted) return;
    setState(() {
      _accountTransferRunning = true;
      _accountTransferResult = null;
    });
    var networkStopped = false;
    try {
      final service = AccountTransferService(nativeCore: core);
      final Uint8List? document = useQr
          ? await service.downloadFromQrPayload(qrPayload!)
          : await service.pickBackupDocument();
      if (document == null) {
        if (mounted) {
          setState(() => _accountTransferResult = 'Importazione annullata.');
        }
        return;
      }
      await widget.veilidService.stop();
      networkStopped = true;
      final profile = await service.importFromDocument(
        bytes: document,
        transferPassword: password,
      );
      widget.onAccountImported(profile);
      if (mounted) {
        setState(
          () => _accountTransferResult =
              'Account collegato: profilo, chat e messaggi sono stati ripristinati.',
        );
      }
    } on Object catch (error) {
      final importedProfile = error is AccountTransferException
          ? error.importedProfile
          : null;
      if (importedProfile != null) {
        widget.onAccountImported(importedProfile);
      }
      AppLog.instance.recordError(
        category: 'account',
        action: 'import_failed',
        error: error,
      );
      if (mounted) {
        setState(
          () => _accountTransferResult = importedProfile == null
              ? 'Importazione non riuscita. Controlla file e password.'
              : 'Account collegato, ma il profilo non è stato salvato sul dispositivo. Riprova dal profilo.',
        );
      }
    } finally {
      if (networkStopped) await widget.veilidService.start();
      if (mounted) setState(() => _accountTransferRunning = false);
    }
  }

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
        final status = core is NativeCoreClient
            ? await core.statusInBackground()
            : core.status();
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
              const _SectionTitle('ACCOUNT E DISPOSITIVI'),
              const SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    ListTile(
                      key: const ValueKey('export-account'),
                      leading: const Icon(Icons.laptop_chromebook_rounded),
                      title: const Text('Collega un altro dispositivo'),
                      subtitle: const Text(
                        'Crea un file cifrato con identità, contatti, chat, messaggi e sessioni sicure.',
                      ),
                      trailing: _accountTransferRunning
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _accountTransferRunning
                          ? null
                          : _linkAnotherDevice,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const ValueKey('import-account'),
                      leading: const Icon(Icons.phonelink_ring_rounded),
                      title: const Text('Usa un account esistente'),
                      subtitle: const Text(
                        'Importa il file creato sull’altro telefono o computer.',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _accountTransferRunning ? null : _importAccount,
                    ),
                    if (_accountTransferResult != null) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_accountTransferResult!),
                        ),
                      ),
                    ],
                  ],
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

enum _AccountExportMethod { qrCode, file }

enum _AccountImportMethod { qrCode, file }

class _AccountQrDialog extends StatelessWidget {
  const _AccountQrDialog({required this.session});

  final AccountQrTransferSession session;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Scansiona dal telefono'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390),
        child: AnimatedBuilder(
          animation: session.state,
          builder: (context, _) {
            final state = session.state.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state == AccountQrTransferState.waiting)
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      key: const ValueKey('account-transfer-qr'),
                      data: session.qrPayload,
                      size: 280,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(color: Colors.black),
                      dataModuleStyle: const QrDataModuleStyle(
                        color: Colors.black,
                      ),
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                    ),
                  )
                else
                  Icon(
                    state == AccountQrTransferState.transferred
                        ? Icons.check_circle_rounded
                        : state == AccountQrTransferState.expired
                        ? Icons.timer_off_outlined
                        : Icons.error_outline_rounded,
                    size: 72,
                    color: state == AccountQrTransferState.transferred
                        ? const Color(0xFF8CE6AC)
                        : const Color(0xFFFF9D95),
                  ),
                const SizedBox(height: 16),
                Text(switch (state) {
                  AccountQrTransferState.waiting =>
                    'Sul telefono apri “Usa un account esistente” e scegli “Scansiona QR”. I dispositivi devono essere sulla stessa rete.',
                  AccountQrTransferState.transferred =>
                    'File cifrato trasferito. Completa l’importazione sul telefono.',
                  AccountQrTransferState.expired =>
                    'Il QR è scaduto dopo 5 minuti. Chiudi e generane uno nuovo.',
                  AccountQrTransferState.error =>
                    'Trasferimento interrotto. Chiudi e riprova.',
                }, textAlign: TextAlign.center),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Chiudi'),
        ),
      ],
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

bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
