import '../../core/privacy/app_palette.dart';
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
import '../updates/update_host.dart';

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
              SizedBox(height: 16),
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(labelText: 'Password'),
              ),
              if (confirm) ...[
                SizedBox(height: 10),
                TextField(
                  controller: second,
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'Ripeti password'),
                ),
              ],
              if (error != null) ...[
                SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(color: AppPalette.color(0xFFFF9D95)),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Annulla'),
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
      SnackBar(
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
          padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  'Collega un altro dispositivo',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text('Scegli come trasferire l’account cifrato.'),
              ),
              ListTile(
                key: ValueKey('export-account-qr'),
                leading: Icon(Icons.qr_code_2_rounded),
                title: Text('Mostra QR Code'),
                subtitle: Text(
                  'Trasferimento diretto sulla stessa rete Wi-Fi o LAN.',
                ),
                onTap: () =>
                    Navigator.pop(context, _AccountExportMethod.qrCode),
              ),
              ListTile(
                key: ValueKey('export-account-file'),
                leading: Icon(Icons.save_alt_rounded),
                title: Text('Salva file cifrato'),
                subtitle: Text('Metodo compatibile con tutti i dispositivi.'),
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
              ListTile(
                title: Text(
                  'Usa un account esistente',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text('Scegli il computer o un file già esportato.'),
              ),
              ListTile(
                key: ValueKey('import-account-qr'),
                leading: Icon(Icons.qr_code_scanner_rounded),
                title: Text('Scansiona QR dal computer'),
                onTap: () =>
                    Navigator.pop(context, _AccountImportMethod.qrCode),
              ),
              ListTile(
                key: ValueKey('import-account-file'),
                leading: Icon(Icons.file_open_outlined),
                title: Text('Scegli file account'),
                onTap: () => Navigator.pop(context, _AccountImportMethod.file),
              ),
              SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (!mounted || source == null) return;
      useQr = source == _AccountImportMethod.qrCode;
      if (useQr) {
        qrPayload = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            settings: RouteSettings(name: '/account-qr-scanner'),
            builder: (context) => AccountQrScannerPage(),
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
    ).showSnackBar(SnackBar(content: Text('Log diagnostici copiati.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Impostazioni')),
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
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
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
                    icon: Icon(Icons.refresh_rounded),
                  ),
                ),
              ),
              SizedBox(height: 16),
              _SectionTitle('ACCOUNT E DISPOSITIVI'),
              SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    ListTile(
                      key: ValueKey('export-account'),
                      leading: Icon(Icons.laptop_chromebook_rounded),
                      title: Text('Collega un altro dispositivo'),
                      subtitle: Text(
                        'Crea un file cifrato con identità, contatti, chat, messaggi e sessioni sicure.',
                      ),
                      trailing: _accountTransferRunning
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.chevron_right_rounded),
                      onTap: _accountTransferRunning
                          ? null
                          : _linkAnotherDevice,
                    ),
                    Divider(height: 1),
                    ListTile(
                      key: ValueKey('import-account'),
                      leading: Icon(Icons.phonelink_ring_rounded),
                      title: Text('Usa un account esistente'),
                      subtitle: Text(
                        'Importa il file creato sull’altro telefono o computer.',
                      ),
                      trailing: Icon(Icons.chevron_right_rounded),
                      onTap: _accountTransferRunning ? null : _importAccount,
                    ),
                    if (_accountTransferResult != null) ...[
                      Divider(height: 1),
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_accountTransferResult!),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: 16),
              _SectionTitle('PRIVACY DEL PROFILO'),
              SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: ValueKey('share-display-name'),
                      secondary: Icon(Icons.badge_outlined),
                      title: Text('Mostra il nome profilo'),
                      subtitle: Text(
                        'Consenti ai contatti di vedere il nome che hai scelto.',
                      ),
                      value: privacy.shareDisplayName,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(shareDisplayName: value),
                      ),
                    ),
                    Divider(height: 1),
                    SwitchListTile(
                      key: ValueKey('share-profile-photo'),
                      secondary: Icon(Icons.account_circle_outlined),
                      title: Text('Mostra la foto profilo'),
                      subtitle: Text(
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
              SizedBox(height: 16),
              _SectionTitle('MESSAGGI E SPUNTE'),
              SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: ValueKey('show-read-receipts'),
                      secondary: Icon(Icons.visibility_outlined),
                      title: Text('Mostra spunte ricevute'),
                      subtitle: Text(
                        'Permette agli altri di vedere quando leggi i loro messaggi.',
                      ),
                      value: privacy.sendReadReceipts,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(
                          sendReadReceipts: value,
                          showReadReceipts: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              _SectionTitle('ASPETTO E TASTIERA'),
              _SettingsCard(
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      key: ValueKey('app-theme'),
                      initialValue:
                          [
                            'sylphy',
                            'black',
                            'cyan',
                            'pink',
                            'amoled',
                            'white',
                          ].contains(privacy.themeName)
                          ? privacy.themeName
                          : 'sylphy',
                      decoration: InputDecoration(labelText: 'Tema di Sylphy'),
                      items: [
                        DropdownMenuItem(
                          value: 'sylphy',
                          child: Text('Sylphy'),
                        ),
                        DropdownMenuItem(value: 'black', child: Text('Black')),
                        DropdownMenuItem(value: 'cyan', child: Text('Cyan')),
                        DropdownMenuItem(value: 'pink', child: Text('Pink')),
                        DropdownMenuItem(
                          value: 'amoled',
                          child: Text('AMOLED'),
                        ),
                        DropdownMenuItem(value: 'white', child: Text('White')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          widget.privacySettings.update(
                            privacy.copyWith(themeName: value),
                          );
                        }
                      },
                    ),
                    SwitchListTile(
                      key: ValueKey('incognito-keyboard'),
                      secondary: Icon(Icons.keyboard_outlined),
                      title: Text('Tastiera in incognito'),
                      subtitle: Text(
                        'Chiede a Gboard e alle tastiere compatibili di non memorizzare ciò che scrivi in chat.',
                      ),
                      value: privacy.incognitoKeyboard,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(incognitoKeyboard: value),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              _SectionTitle('CONTATTI E ACCESSIBILITÀ'),
              SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: Icon(Icons.person_search_outlined),
                      title: Text('Richieste da sconosciuti'),
                      subtitle: Text(
                        'Accetta nuove richieste soltanto quando è attivo.',
                      ),
                      value: privacy.allowUnknownContacts,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(allowUnknownContacts: value),
                      ),
                    ),
                    Divider(height: 1),
                    SwitchListTile(
                      secondary: Icon(Icons.motion_photos_off_outlined),
                      title: Text('Riduci animazioni'),
                      value: privacy.reduceMotion,
                      onChanged: (value) => widget.privacySettings.update(
                        privacy.copyWith(reduceMotion: value),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              UpdateSettings(),
              SizedBox(height: 16),
              Text(
                'DEVELOPER OPTIONS',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppPalette.color(0xFF9299A5),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: ValueKey('developer-logging-switch'),
                      secondary: Icon(Icons.bug_report_outlined),
                      title: Text('Logging dettagliato'),
                      subtitle: Text(
                        'Registra lifecycle, navigazione, azioni UI e chiamate al core. Testi dei messaggi, password e chiavi sono sempre esclusi.',
                      ),
                      value: AppLog.instance.verboseEnabled,
                      onChanged: AppLog.instance.setVerboseEnabled,
                    ),
                    Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.health_and_safety_outlined),
                      title: Text('Esegui diagnostica'),
                      subtitle: _diagnosticResult == null
                          ? Text('Controlla core nativo, bootstrap e Veilid.')
                          : Text(_diagnosticResult!),
                      trailing: _diagnosticRunning
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.chevron_right_rounded),
                      onTap: _diagnosticRunning ? null : _runDiagnostics,
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'LOG (${AppLog.instance.entries.length})',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppPalette.color(0xFF9299A5),
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  Spacer(),
                  IconButton(
                    tooltip: 'Copia log',
                    onPressed: _copyLogs,
                    icon: Icon(Icons.copy_all_outlined),
                  ),
                  IconButton(
                    tooltip: 'Cancella log',
                    onPressed: AppLog.instance.clear,
                    icon: Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
              _LogViewer(entries: AppLog.instance.entries),
              if (AppLog.instance.logFilePath case final path?) ...[
                SizedBox(height: 10),
                SelectableText(
                  'File persistente: $path',
                  style: TextStyle(
                    color: AppPalette.color(0xFF7F8997),
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
    return Material(
      color: AppPalette.color(0xFF151A21),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: AppPalette.color(0xFF303741)),
      ),
      clipBehavior: Clip.antiAlias,
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
      title: Text('Scansiona dal telefono'),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 390),
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
                    padding: EdgeInsets.all(12),
                    child: QrImageView(
                      key: ValueKey('account-transfer-qr'),
                      data: session.qrPayload,
                      size: 280,
                      backgroundColor: Colors.white,
                      eyeStyle: QrEyeStyle(color: Colors.black),
                      dataModuleStyle: QrDataModuleStyle(color: Colors.black),
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
                        ? AppPalette.color(0xFF8CE6AC)
                        : AppPalette.color(0xFFFF9D95),
                  ),
                SizedBox(height: 16),
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
          child: Text('Chiudi'),
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
      color: AppPalette.color(0xFF9299A5),
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
      key: ValueKey('developer-log-viewer'),
      constraints: BoxConstraints(minHeight: 180, maxHeight: 420),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.color(0xFF090C11),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.color(0xFF303741)),
      ),
      child: visibleEntries.isEmpty
          ? Center(
              child: Text(
                'Nessun evento registrato.',
                style: TextStyle(color: AppPalette.color(0xFF9299A5)),
              ),
            )
          : Scrollbar(
              child: ListView.separated(
                itemCount: visibleEntries.length,
                separatorBuilder: (context, index) => Divider(height: 12),
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
  AppLogLevel.debug => AppPalette.color(0xFF9299A5),
  AppLogLevel.info => AppPalette.color(0xFFC8D0DA),
  AppLogLevel.warning => AppPalette.color(0xFFFFC56B),
  AppLogLevel.error => AppPalette.color(0xFFFF8F86),
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
