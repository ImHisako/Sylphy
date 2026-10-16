import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/identity/account_transfer_service.dart';
import '../../core/native/native_core.dart';
import '../../core/profile/user_profile.dart';
import '../../core/privacy/app_security.dart';
import '../../core/veilid/veilid_service.dart';
import 'account_qr_scanner_page.dart';
import 'account_transfer_recovery.dart';
import 'app_security_widgets.dart';

enum AccountTransferMode { send, receive }

class AccountTransferPage extends StatefulWidget {
  const AccountTransferPage({
    super.key,
    required this.mode,
    required this.veilidService,
    required this.onAccountImported,
    this.profile,
    this.nativeCore,
    this.profileStore,
    this.service,
    this.replaceExisting = false,
    this.initialDocument,
  });

  final AccountTransferMode mode;
  final VeilidService veilidService;
  final ValueChanged<UserProfile> onAccountImported;
  final UserProfile? profile;
  final NativeCoreApi? nativeCore;
  final UserProfileStore? profileStore;
  final AccountTransferService? service;
  final bool replaceExisting;
  final Uint8List? initialDocument;

  @override
  State<AccountTransferPage> createState() => _AccountTransferPageState();
}

class _AccountTransferPageState extends State<AccountTransferPage> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _code = TextEditingController();
  AccountTransferService? _service;
  AppSecurityController? _security;
  AccountTransferRecovery? _recovery;
  AccountQrTransferSession? _qrSession;
  Uint8List? _document;
  bool _busy = false;
  bool _completed = false;
  bool _showPassword = false;
  String? _message;
  String? _errorCode;

  bool get _sending => widget.mode == AccountTransferMode.send;
  bool get _current => mounted && _security?.locked != true;
  bool get _hasCamera =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _document = widget.initialDocument;
    final core = widget.nativeCore;
    _service =
        widget.service ??
        (core is NativeAccountTransferApi
            ? AccountTransferService(
                nativeCore: core as NativeAccountTransferApi,
                profileStore: widget.profileStore,
              )
            : null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _security = AppSecurityScope.maybeOf(context);
    _recovery = AccountTransferRecoveryScope.maybeOf(context);
  }

  @override
  void dispose() {
    _document?.fillRange(0, _document!.length, 0);
    unawaited(_qrSession?.close());
    _password.clear();
    _confirmation.clear();
    _code.clear();
    _password.dispose();
    _confirmation.dispose();
    _code.dispose();
    super.dispose();
  }

  void _failed(Object error) {
    final failure = error is AccountTransferException
        ? error
        : AccountTransferException(
            error is PlatformException
                ? 'file_access_failed'
                : 'transfer_failed',
          );
    AppLog.instance.record(
      category: 'account',
      action: 'transfer_failed',
      level: AppLogLevel.error,
      result: failure.code,
      force: true,
    );
    if (_current) {
      setState(() {
        _errorCode = failure.code;
        _message = failure.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${failure.message}\nCodice: ${failure.code}')),
      );
    }
  }

  Future<void> _selectDocument({
    bool fromCode = false,
    bool scan = false,
  }) async {
    final service = _service;
    if (_busy || service == null) return;
    final recovery = _recovery;
    final recoveryGeneration = recovery?.generation;
    String? payload;
    if (scan) {
      payload = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/account-qr-scanner'),
          builder: (_) => const AccountQrScannerPage(),
        ),
      );
      if (!_current || payload == null) return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _errorCode = null;
    });
    try {
      final bytes = fromCode || scan
          ? await service.downloadFromQrPayload(payload ?? _code.text.trim())
          : await service.pickBackupDocument();
      if (bytes == null) return;
      try {
        parseBackupDocument(bytes);
      } on Object {
        bytes.fillRange(0, bytes.length, 0);
        rethrow;
      }
      if (!_current) {
        if (recovery != null && recoveryGeneration != null) {
          recovery.retain(bytes, recoveryGeneration);
        } else {
          bytes.fillRange(0, bytes.length, 0);
        }
        return;
      }
      setState(() {
        _document?.fillRange(0, _document!.length, 0);
        _document = bytes;
        _code.clear();
        _password.clear();
        _message =
            'Backup riconosciuto. Inserisci la password di trasferimento.';
      });
    } on Object catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validatedPassword() {
    final password = _password.text;
    if (password.runes.length < 10 || password.runes.length > 256) {
      setState(() {
        _errorCode = 'password_required';
        _message =
            'Inserisci una password di trasferimento da 10 a 256 caratteri.';
      });
      return null;
    }
    if (_sending && password != _confirmation.text) {
      setState(() {
        _errorCode = 'password_mismatch';
        _message = 'Le due password non coincidono.';
      });
      return null;
    }
    return password;
  }

  Future<void> _export(String method) async {
    final service = _service;
    final profile = widget.profile;
    if (_busy || service == null || profile == null) return;
    final password = _validatedPassword();
    if (password == null) return;
    setState(() {
      _busy = true;
      _errorCode = null;
      _message = 'Preparazione del backup cifrato…';
    });
    AccountQrTransferSession? session;
    try {
      if (method == 'qr') {
        final document = await service.createBackupDocument(
          profile: profile,
          transferPassword: password,
        );
        if (!mounted || !_current) return;
        session = await AccountQrTransferSession.start(document);
        _qrSession = session;
        if (!mounted || !_current) return;
        await showDialog<void>(
          context: context,
          builder: (_) => _AccountQrDialog(session: session!),
        );
        if (_current) {
          setState(
            () => _message =
                session!.state.value == AccountQrTransferState.transferred
                ? 'File cifrato inviato. Completa il ripristino sull’altro dispositivo.'
                : 'Trasferimento QR chiuso. Puoi generarne un altro.',
          );
        }
      } else {
        final result = method == 'share'
            ? await service.shareBackup(
                profile: profile,
                transferPassword: password,
                isCurrent: () => _current,
              )
            : await service.exportToFile(
                profile: profile,
                transferPassword: password,
                isCurrent: () => _current,
              );
        if (_current) {
          setState(
            () => _message = result == null
                ? 'Operazione annullata. Puoi riprovare.'
                : method == 'share'
                ? 'File cifrato consegnato alla condivisione. Importalo sull’altro dispositivo.'
                : 'Backup cifrato salvato: $result',
          );
        }
      }
    } on Object catch (error) {
      _failed(error);
    } finally {
      _qrSession = null;
      await session?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final service = _service;
    final document = _document;
    if (_busy || service == null || document == null) return;
    final password = _validatedPassword();
    if (password == null) return;
    if (widget.replaceExisting) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sostituire l’account su questo dispositivo?'),
          content: const Text(
            'Il backup sostituirà identità, contatti e cronologia locali. Gli account non vengono uniti. Esporta prima un backup dell’account attuale se vuoi conservarlo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Importa account'),
            ),
          ],
        ),
      );
      if (confirmed != true || !_current) return;
    }
    setState(() {
      _busy = true;
      _errorCode = null;
      _message = 'Ripristino dell’account cifrato…';
    });
    _password.clear();
    var networkStopped = false;
    try {
      await widget.veilidService.stop();
      networkStopped = true;
      if (!_current) return;
      final profile = await service.importFromDocument(
        bytes: document,
        transferPassword: password,
      );
      // A successful native transaction stays committed even if the route was
      // disposed by locking. The root restores it from encrypted storage later.
      if (!_current) return;
      widget.onAccountImported(profile);
      if (mounted) {
        setState(() {
          _completed = true;
          _message =
              'Account ripristinato. Identità, contatti e cronologia sono disponibili; la rete si riconnetterà.';
        });
      }
    } on Object catch (error) {
      if (error is AccountTransferException &&
          error.importedProfile != null &&
          _current) {
        widget.onAccountImported(error.importedProfile!);
        _completed = true;
      }
      _failed(error);
    } finally {
      if (networkStopped && _current) await widget.veilidService.start();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          _sending
              ? 'Collega un altro dispositivo'
              : 'Usa un account esistente',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Icon(
                _sending ? Icons.devices_rounded : Icons.restore_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                _sending
                    ? 'Porta il tuo account sull’altro dispositivo'
                    : 'Ripristina il tuo account Sylphy',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                _sending
                    ? '1. Scegli una password di trasferimento.\n2. Salva o condividi il file cifrato, oppure mostra un QR sulla stessa rete Wi-Fi.\n3. Sull’altro dispositivo scegli “Usa un account esistente” e inserisci la stessa password.'
                    : '1. Sul dispositivo di origine apri Impostazioni → Account e dispositivi → Collega un altro dispositivo.\n2. Scegli qui il file esportato oppure ricevi il backup tramite QR.\n3. Inserisci la password scelta durante l’esportazione.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Il backup conserva identità, contatti e cronologia inclusi nell’esportazione. Ogni dispositivo crea nuove sessioni di messaggistica. La password di trasferimento è distinta dalla passphrase di blocco dell’app.',
              ),
              if (_service == null) ...[
                const SizedBox(height: 20),
                const Text(
                  'Core di trasferimento non disponibile. Installa una build con il core nativo aggiornato.',
                ),
              ] else if (!_completed) ...[
                if (!_sending) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const ValueKey('choose-account-file'),
                    onPressed: _busy ? null : () => _selectDocument(),
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Scegli file account'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sono accettati anche i file rinominati o senza estensione. Viene verificato il contenuto.',
                  ),
                  if (_hasCamera)
                    OutlinedButton.icon(
                      key: const ValueKey('scan-account-qr'),
                      onPressed: _busy
                          ? null
                          : () => _selectDocument(scan: true),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scansiona QR dall’altro dispositivo'),
                    ),
                  ExpansionTile(
                    title: const Text('Ricevi con un codice copiato'),
                    children: [
                      TextField(
                        controller: _code,
                        enabled: !_busy,
                        maxLength: 16384,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Codice di trasferimento',
                          helperText:
                              'Copia il codice sotto il QR sull’altro dispositivo.',
                        ),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _selectDocument(fromCode: true),
                        child: const Text('Ricevi backup sulla rete locale'),
                      ),
                    ],
                  ),
                  if (_document != null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.task_alt),
                      title: const Text('Backup selezionato'),
                      subtitle: Text(
                        '${(_document!.length / 1024).ceil()} KiB · pronto per la password',
                      ),
                    ),
                ],
                const SizedBox(height: 20),
                TextField(
                  key: const ValueKey('transfer-password'),
                  controller: _password,
                  enabled: !_busy && (_sending || _document != null),
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: 'Password di trasferimento',
                    suffixIcon: IconButton(
                      tooltip: _showPassword
                          ? 'Nascondi password'
                          : 'Mostra password',
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
                if (_sending) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('confirm-transfer-password'),
                    controller: _confirmation,
                    enabled: !_busy,
                    obscureText: !_showPassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: const InputDecoration(
                      labelText: 'Ripeti la password di trasferimento',
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const ValueKey('save-account-backup'),
                    onPressed: _busy ? null : () => _export('file'),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Salva file cifrato'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('share-account-backup'),
                    onPressed: _busy ? null : () => _export('share'),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Condividi file cifrato'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('export-account-qr'),
                    onPressed: _busy ? null : () => _export('qr'),
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('Mostra QR sulla rete locale'),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('restore-account'),
                    onPressed: _busy || _document == null ? null : _import,
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('Ripristina account'),
                  ),
                ],
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(liveRegion: true, child: Text(_message!)),
                ),
              if (_errorCode != null)
                SelectableText(
                  'Codice errore: $_errorCode',
                  key: const ValueKey('account-transfer-error-code'),
                ),
              if (_completed)
                FilledButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Apri Sylphy'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AccountQrDialog extends StatelessWidget {
  const _AccountQrDialog({required this.session});
  final AccountQrTransferSession session;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Scansiona dall’altro dispositivo'),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: ValueListenableBuilder(
          valueListenable: session.state,
          builder: (context, state, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state == AccountQrTransferState.waiting) ...[
                AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      data: session.qrPayload,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Apri “Usa un account esistente” sull’altro dispositivo. Mantieni entrambi sulla stessa rete Wi-Fi. Il QR scade dopo 5 minuti.',
                ),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: session.qrPayload)),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copia codice di trasferimento'),
                ),
              ] else
                Text(switch (state) {
                  AccountQrTransferState.transferred =>
                    'File cifrato trasferito. Completa il ripristino sull’altro dispositivo.',
                  AccountQrTransferState.expired =>
                    'QR scaduto. Chiudi e generane uno nuovo.',
                  _ => 'Trasferimento interrotto. Chiudi e riprova.',
                }),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Chiudi'),
      ),
    ],
  );
}
