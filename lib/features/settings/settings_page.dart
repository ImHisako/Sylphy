import '../../core/privacy/app_palette.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/native/native_core.dart';
import '../../core/profile/user_profile.dart';
import '../../core/privacy/privacy_settings.dart';
import '../../core/platform/stream_proof_host.dart';
import '../../core/veilid/veilid_service.dart';
import 'account_transfer_page.dart';
import 'android_notification_settings.dart';
import 'app_security_widgets.dart';
import 'identity_rotation_settings.dart';
import 'settings_search.dart';
import 'performance_settings.dart';
import '../../core/identity/identity_service.dart';
import '../updates/update_host.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.veilidService,
    required this.privacySettings,
    required this.profile,
    required this.onAccountImported,
    required this.onEditProfile,
    this.nativeCore,
    this.identityService,
  });

  final VeilidService veilidService;
  final NativeCoreApi? nativeCore;
  final IdentityService? identityService;
  final PrivacySettingsController privacySettings;
  final UserProfile profile;
  final ValueChanged<UserProfile> onAccountImported;
  final VoidCallback onEditProfile;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _diagnosticResult;
  bool _diagnosticRunning = false;
  String? _selectedSection;
  String _query = '';
  final _search = TextEditingController();
  final _searchAnchors = <String, GlobalKey>{};
  String? _selectedSetting;

  void _openSection(String sectionId, {String? settingId}) {
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedSection = sectionId;
      _selectedSetting = settingId;
    });
    if (settingId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedSetting != settingId) return;
        final target = _searchAnchors[settingId]?.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(target, alignment: 0.15);
        }
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openAccountTransfer(AccountTransferMode mode) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/account-transfer'),
          builder: (_) => AccountTransferPage(
            mode: mode,
            veilidService: widget.veilidService,
            profile: widget.profile,
            nativeCore: widget.nativeCore,
            onAccountImported: widget.onAccountImported,
            replaceExisting: mode == AccountTransferMode.receive,
          ),
        ),
      );

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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      AppLog.instance,
      widget.veilidService,
      widget.privacySettings,
    ]),
    builder: (context, _) {
      final snapshot = widget.veilidService.snapshot;
      final privacy = widget.privacySettings.value;
      final security = AppSecurityScope.maybeOf(context);
      final updates = AppUpdateScope.maybeOf(context);
      final sections = <_SettingsSection>[
        _SettingsSection(
          id: 'account',
          title: 'Account e dispositivi',
          detail: 'Collega un dispositivo, importa un account e crea un backup',
          icon: Icons.devices_rounded,
          children: [
            _SettingsCard(
              child: Column(
                children: [
                  SettingsSearchTarget(
                    id: 'export-account',
                    child: ListTile(
                      key: const ValueKey('export-account'),
                      leading: const Icon(Icons.add_to_home_screen_rounded),
                      title: const Text('Collega un altro dispositivo'),
                      subtitle: const Text(
                        'File cifrato, condivisione o QR sulla rete locale.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          _openAccountTransfer(AccountTransferMode.send),
                    ),
                  ),
                  const Divider(height: 1),
                  SettingsSearchTarget(
                    id: 'import-account',
                    child: ListTile(
                      key: const ValueKey('import-account'),
                      leading: const Icon(Icons.restore_rounded),
                      title: const Text('Usa un account esistente'),
                      subtitle: const Text(
                        'Scegli il backup e ripristina identità, contatti e cronologia.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          _openAccountTransfer(AccountTransferMode.receive),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'La password di trasferimento protegge il backup. Ogni dispositivo mantiene sessioni di messaggistica proprie.',
              ),
            ),
          ],
        ),
        _SettingsSection(
          id: 'security',
          title: 'Sicurezza locale',
          detail: 'Blocco automatico, passphrase e pulizia della memoria',
          icon: Icons.lock_outline_rounded,
          children: [const AppSecuritySettings()],
        ),
        _SettingsSection(
          id: 'privacy',
          title: 'Privacy del profilo',
          detail:
              'ID Sylphy, nome e foto, messaggi e spunte, contatti e richieste',
          icon: Icons.privacy_tip_outlined,
          children: [
            if (widget.identityService != null) ...[
              IdentityRotationSettings(
                identityService: widget.identityService!,
                privacySettings: widget.privacySettings,
              ),
              const SizedBox(height: 16),
            ],
            if (_isAndroidPlatform || supportsStreamProof) ...[
              _SettingsCard(
                child: SettingsSearchTarget(
                  id: 'allow-screenshots',
                  child: SwitchListTile(
                    key: const ValueKey('allow-screenshots'),
                    secondary: const Icon(Icons.screenshot_outlined),
                    title: const Text('Consenti screenshot dell’app'),
                    subtitle: Text(
                      _isAndroidPlatform
                          ? 'Consente screenshot e registrazioni mentre l’app è sbloccata. Le anteprime in background restano protette.'
                          : 'Disattiva lo Stream proof per consentire screenshot e condivisioni dello schermo.',
                    ),
                    value: _isAndroidPlatform
                        ? privacy.allowScreenshots
                        : !privacy.streamProof,
                    onChanged: (value) => widget.privacySettings.update(
                      _isAndroidPlatform
                          ? privacy.copyWith(allowScreenshots: value)
                          : privacy.copyWith(streamProof: !value),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            _SectionTitle('PRIVACY DEL PROFILO'),
            SizedBox(height: 8),
            _SettingsCard(
              child: Column(
                children: [
                  SettingsSearchTarget(
                    id: 'share-display-name',
                    child: SwitchListTile(
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
                  ),
                  Divider(height: 1),
                  SettingsSearchTarget(
                    id: 'share-profile-photo',
                    child: SwitchListTile(
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
                  SettingsSearchTarget(
                    id: 'show-read-receipts',
                    child: SwitchListTile(
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
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            _SectionTitle('CONTATTI E RICHIESTE'),
            SizedBox(height: 8),
            _SettingsCard(
              child: SettingsSearchTarget(
                id: 'unknown-contacts',
                child: SwitchListTile(
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
              ),
            ),
          ],
        ),
        _SettingsSection(
          id: 'appearance',
          title: 'Aspetto',
          detail: 'Tema, tastiera e accessibilità: riduci animazioni',
          icon: Icons.palette_outlined,
          children: [
            _SectionTitle(
              _isAndroidPlatform ? 'ASPETTO E TASTIERA' : 'ASPETTO',
            ),
            SizedBox(height: 8),
            _SettingsCard(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
                    child: SettingsSearchTarget(
                      id: 'app-theme',
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('app-theme'),
                        initialValue:
                            [
                              'sylphy',
                              'black',
                              'cyan',
                              'pink',
                              'amoled',
                              'white',
                              'halloween',
                            ].contains(privacy.themeName)
                            ? privacy.themeName
                            : 'sylphy',
                        decoration: InputDecoration(
                          labelText: 'Tema di Sylphy',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        isExpanded: true,
                        items: [
                          DropdownMenuItem(
                            value: 'sylphy',
                            child: Text('Sylphy'),
                          ),
                          DropdownMenuItem(
                            value: 'black',
                            child: Text('Black'),
                          ),
                          DropdownMenuItem(value: 'cyan', child: Text('Cyan')),
                          DropdownMenuItem(value: 'pink', child: Text('Pink')),
                          DropdownMenuItem(
                            value: 'amoled',
                            child: Text('AMOLED'),
                          ),
                          DropdownMenuItem(
                            value: 'white',
                            child: Text('White'),
                          ),
                          DropdownMenuItem(
                            value: 'halloween',
                            child: Text('Halloween'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            widget.privacySettings.update(
                              privacy.copyWith(themeName: value),
                            );
                          }
                        },
                      ),
                    ),
                  ),
                  if (_isAndroidPlatform)
                    SettingsSearchTarget(
                      id: 'incognito-keyboard',
                      child: SwitchListTile(
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
                    ),
                ],
              ),
            ),
            SizedBox(height: 16),
            _SectionTitle('ACCESSIBILITÀ'),
            SizedBox(height: 8),
            _SettingsCard(
              child: SettingsSearchTarget(
                id: 'reduce-motion',
                child: SwitchListTile(
                  secondary: Icon(Icons.motion_photos_off_outlined),
                  title: Text('Riduci animazioni'),
                  value: privacy.reduceMotion,
                  onChanged: (value) => widget.privacySettings.update(
                    privacy.copyWith(reduceMotion: value),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (supportsStreamProof)
          _SettingsSection(
            id: 'screen',
            title: 'Condivisione schermo',
            detail: 'Protezione dalle catture su Windows',
            icon: Icons.screenshot_monitor_outlined,
            children: [
              _SettingsCard(
                child: SettingsSearchTarget(
                  id: 'stream-proof',
                  child: SwitchListTile(
                    key: ValueKey('stream-proof'),
                    secondary: Icon(Icons.screenshot_monitor_outlined),
                    title: Text('Stream proof'),
                    subtitle: Text(
                      'Esclude Sylphy dalle catture e dalle condivisioni compatibili, '
                      'lasciandolo visibile a te. Richiede Windows 10 versione 2004 o successiva. '
                      'Verifica l’anteprima del programma di condivisione.',
                    ),
                    value: privacy.streamProof,
                    onChanged: (value) => widget.privacySettings.update(
                      privacy.copyWith(streamProof: value),
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (_isAndroidPlatform)
          _SettingsSection(
            id: 'notifications',
            title: 'Notifiche e vibrazione',
            detail: 'Permessi, suoni e notifiche Android',
            icon: Icons.notifications_outlined,
            children: [
              const _SettingsCard(child: AndroidNotificationSettings()),
            ],
          ),
        _SettingsSection(
          id: 'updates',
          title: 'Aggiornamenti',
          detail: 'Versione e aggiornamenti dell’app',
          icon: Icons.system_update_outlined,
          children: [const UpdateSettings()],
        ),
        _SettingsSection(
          id: 'diagnostics',
          title: 'Diagnostica',
          detail:
              'DEVELOPER OPTIONS · prestazioni e log senza messaggi o chiavi',
          icon: Icons.bug_report_outlined,
          children: [
            SettingsSearchTarget(
              id: 'performance-settings',
              child: PerformanceSettings(nativeCore: widget.nativeCore),
            ),
            const SizedBox(height: 16),
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
                  SettingsSearchTarget(
                    id: 'basic-logging-switch',
                    child: SwitchListTile(
                      key: const ValueKey('basic-logging-switch'),
                      secondary: const Icon(Icons.receipt_long_outlined),
                      title: const Text('Logging di base'),
                      subtitle: const Text(
                        'Registra eventi ed errori diagnostici dell’app. Disattivalo per sospendere anche il logging dettagliato.',
                      ),
                      value: AppLog.instance.loggingEnabled,
                      onChanged: AppLog.instance.setLoggingEnabled,
                    ),
                  ),
                  const Divider(height: 1),
                  SettingsSearchTarget(
                    id: 'developer-logging-switch',
                    child: SwitchListTile(
                      key: ValueKey('developer-logging-switch'),
                      secondary: Icon(Icons.bug_report_outlined),
                      title: Text('Logging dettagliato'),
                      subtitle: Text(
                        'Registra lifecycle, navigazione, azioni UI e chiamate al core. Testi dei messaggi, password e chiavi sono sempre esclusi.',
                      ),
                      value:
                          AppLog.instance.loggingEnabled &&
                          AppLog.instance.verboseEnabled,
                      onChanged: AppLog.instance.loggingEnabled
                          ? AppLog.instance.setVerboseEnabled
                          : null,
                    ),
                  ),
                  Divider(height: 1),
                  SettingsSearchTarget(
                    id: 'run-diagnostics',
                    child: ListTile(
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
                SettingsSearchTarget(
                  id: 'copy-logs',
                  child: IconButton(
                    tooltip: 'Copia log',
                    onPressed: _copyLogs,
                    icon: Icon(Icons.copy_all_outlined),
                  ),
                ),
                SettingsSearchTarget(
                  id: 'clear-logs',
                  child: IconButton(
                    tooltip: 'Cancella log',
                    onPressed: AppLog.instance.clear,
                    icon: Icon(Icons.delete_sweep_outlined),
                  ),
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
        ),
      ];
      final entries = <SettingsSearchEntry>[
        const SettingsSearchEntry(
          'export-account',
          'account',
          'Collega un altro dispositivo',
          'backup esporta trasferimento file cifrato condivisione qr computer telefono account',
        ),
        const SettingsSearchEntry(
          'import-account',
          'account',
          'Usa un account esistente',
          'importa ripristina backup identita contatti cronologia trasferimento',
        ),
        if (security != null) ...[
          const SettingsSearchEntry(
            'passphrase-encryption',
            'security',
            'Cifratura dei dati con passphrase',
            'password protezione dati locali sicurezza',
          ),
          const SettingsSearchEntry(
            'close-memory-cleanup',
            'security',
            'Pulizia RAM alla chiusura sempre attiva',
            'memoria cache chiavi sessioni',
          ),
          if (security.enabled) ...[
            const SettingsSearchEntry(
              'automatic-lock-timeout',
              'security',
              'Blocco per inattività',
              'automatico tempo secondi minuti sicurezza',
            ),
            const SettingsSearchEntry(
              'automatic-lock-background',
              'security',
              'Blocca in background',
              'automatico app finestra sicurezza',
            ),
            if (_isAndroidPlatform)
              const SettingsSearchEntry(
                'automatic-lock-screen-off',
                'security',
                'Blocca allo spegnimento dello schermo',
                'automatico telefono sicurezza',
              ),
            const SettingsSearchEntry(
              'wipe-and-lock',
              'security',
              'Pulisci RAM e blocca',
              'memoria buffer cache chiavi sessioni sicurezza',
            ),
          ],
        ],
        if (widget.identityService != null) ...[
          const SettingsSearchEntry(
            'identity-rotation-interval',
            'privacy',
            'Cambio automatico dell’ID',
            'identita sylphy intervallo rotazione ore giorni',
          ),
          const SettingsSearchEntry(
            'rotate-identity-now',
            'privacy',
            'Cambia ID adesso',
            'identita sylphy manuale rotazione codice',
          ),
        ],
        if (_isAndroidPlatform || supportsStreamProof)
          const SettingsSearchEntry(
            'allow-screenshots',
            'privacy',
            'Consenti screenshot dell’app',
            'catture registrazione schermo',
          ),
        const SettingsSearchEntry(
          'share-display-name',
          'privacy',
          'Mostra il nome profilo',
          'privacy condividi contatti',
        ),
        const SettingsSearchEntry(
          'share-profile-photo',
          'privacy',
          'Mostra la foto profilo',
          'privacy condividi immagine avatar contatti',
        ),
        const SettingsSearchEntry(
          'show-read-receipts',
          'privacy',
          'Mostra spunte ricevute',
          'messaggi conferme lettura letto ricevute',
        ),
        const SettingsSearchEntry(
          'unknown-contacts',
          'privacy',
          'Richieste da sconosciuti',
          'contatti privacy accetta nuove richieste',
        ),
        const SettingsSearchEntry(
          'app-theme',
          'appearance',
          'Tema di Sylphy',
          'aspetto colori black cyan pink amoled white halloween pipistrelli arancione viola scuro chiaro',
        ),
        if (_isAndroidPlatform)
          const SettingsSearchEntry(
            'incognito-keyboard',
            'appearance',
            'Tastiera in incognito',
            'gboard scrittura memorizzare apprendimento',
          ),
        const SettingsSearchEntry(
          'reduce-motion',
          'appearance',
          'Riduci animazioni',
          'accessibilita movimento aspetto',
        ),
        if (supportsStreamProof)
          const SettingsSearchEntry(
            'stream-proof',
            'screen',
            'Stream proof',
            'condivisione schermo windows catture screenshot protezione',
          ),
        if (_isAndroidPlatform) ...[
          const SettingsSearchEntry(
            'message-notifications',
            'notifications',
            'Notifiche dei messaggi',
            'avvisi background fissati attiva disattiva silenzia',
          ),
          const SettingsSearchEntry(
            'notification-sound',
            'notifications',
            'Suono delle notifiche',
            'audio suoneria volume',
          ),
          const SettingsSearchEntry(
            'notification-vibration',
            'notifications',
            'Vibrazione delle notifiche',
            'vibra avvisi telefono',
          ),
          const SettingsSearchEntry(
            'android-notification-settings',
            'notifications',
            'Impostazioni notifiche Android',
            'permessi autorizzazioni schermata blocco silenzioso non disturbare',
          ),
        ],
        if (updates?.supported == true) ...[
          const SettingsSearchEntry(
            'automatic-updates',
            'updates',
            'Aggiornamenti automatici',
            'release github controllo avvio',
          ),
          const SettingsSearchEntry(
            'check-app-updates',
            'updates',
            'Controlla aggiornamenti',
            'versione release github scarica installa disponibile',
          ),
        ],
        const SettingsSearchEntry(
          'performance-settings',
          'diagnostics',
          'Prestazioni dei messaggi',
          'tempi latenza campioni confronto diagnostica',
        ),
        const SettingsSearchEntry(
          'basic-logging-switch',
          'diagnostics',
          'Logging di base',
          'diagnostica log eventi errori',
        ),
        const SettingsSearchEntry(
          'developer-logging-switch',
          'diagnostics',
          'Logging dettagliato',
          'diagnostica log developer options lifecycle navigazione',
        ),
        const SettingsSearchEntry(
          'run-diagnostics',
          'diagnostics',
          'Esegui diagnostica',
          'core nativo bootstrap rete veilid controlli',
        ),
        const SettingsSearchEntry(
          'copy-logs',
          'diagnostics',
          'Copia log',
          'diagnostica esporta appunti',
        ),
        const SettingsSearchEntry(
          'clear-logs',
          'diagnostics',
          'Cancella log',
          'diagnostica elimina pulisci',
        ),
      ];
      final searching = _query.trim().isNotEmpty;
      final matches = searching
          ? entries.where((entry) => entry.matches(_query)).toList()
          : <SettingsSearchEntry>[];
      final selected = sections
          .where((section) => section.id == _selectedSection)
          .firstOrNull;
      final visible = sections
          .where(
            (section) => matchesSettingsSearch(
              '${section.title} ${section.detail}',
              _query,
            ),
          )
          .toList();
      return PopScope(
        canPop: selected == null,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && mounted) setState(() => _selectedSection = null);
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(selected?.title ?? 'Impostazioni'),
            leading: selected == null
                ? null
                : BackButton(
                    onPressed: () => setState(() => _selectedSection = null),
                  ),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: selected != null
                  ? SettingsSearchScope(
                      anchors: _searchAnchors,
                      selectedId: _selectedSetting,
                      child: SingleChildScrollView(
                        key: ValueKey('settings-content-${selected.id}'),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: selected.children,
                        ),
                      ),
                    )
                  : ListView(
                      key: const ValueKey('settings-index'),
                      padding: const EdgeInsets.all(16),
                      children: [
                        _SettingsProfileHeader(
                          profile: widget.profile,
                          onEdit: widget.onEditProfile,
                        ),
                        const SizedBox(height: 24),
                        const _SectionTitle('RETE E CONNESSIONE'),
                        const SizedBox(height: 8),
                        _SettingsCard(
                          child: ListTile(
                            key: const ValueKey('settings-network-status'),
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
                        const SizedBox(height: 24),
                        TextField(
                          key: const ValueKey('settings-search'),
                          controller: _search,
                          decoration: InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            labelText: 'Cerca nelle impostazioni',
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Cancella ricerca',
                                    onPressed: () {
                                      _search.clear();
                                      setState(() => _query = '');
                                    },
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                          onChanged: (value) => setState(() => _query = value),
                        ),
                        const SizedBox(height: 16),
                        if (searching && matches.isNotEmpty) ...[
                          const _SectionTitle('IMPOSTAZIONI TROVATE'),
                          const SizedBox(height: 8),
                          for (final entry in matches)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _SettingsCard(
                                child: ListTile(
                                  key: ValueKey('settings-result-${entry.id}'),
                                  leading: Icon(
                                    sections
                                        .firstWhere(
                                          (section) =>
                                              section.id == entry.sectionId,
                                        )
                                        .icon,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  title: Text(entry.title),
                                  subtitle: Text(
                                    sections
                                        .firstWhere(
                                          (section) =>
                                              section.id == entry.sectionId,
                                        )
                                        .title,
                                  ),
                                  trailing: const Icon(
                                    Icons.chevron_right_rounded,
                                  ),
                                  onTap: () => _openSection(
                                    entry.sectionId,
                                    settingId: entry.id,
                                  ),
                                ),
                              ),
                            ),
                        ],
                        if (visible.isEmpty && matches.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Nessuna impostazione trovata. Prova un’altra parola.',
                            ),
                          ),
                        for (final section in visible)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _SettingsCard(
                              child: ListTile(
                                key: ValueKey('settings-section-${section.id}'),
                                leading: Icon(
                                  section.icon,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                title: Text(section.title),
                                subtitle: Text(section.detail),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                ),
                                onTap: () => _openSection(section.id),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      );
    },
  );
}

class _SettingsSection {
  const _SettingsSection({
    required this.id,
    required this.title,
    required this.detail,
    required this.icon,
    required this.children,
  });
  final String id;
  final String title;
  final String detail;
  final IconData icon;
  final List<Widget> children;
}

class _SettingsProfileHeader extends StatelessWidget {
  const _SettingsProfileHeader({required this.profile, required this.onEdit});

  final UserProfile profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => _SettingsCard(
    child: InkWell(
      key: const ValueKey('settings-profile'),
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    key: const ValueKey('settings-profile-name'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('Modifica nome e foto'),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Tooltip(
              message: 'Modifica foto profilo',
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    key: const ValueKey('settings-profile-avatar'),
                    radius: 30,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    backgroundImage: profile.photoBytes == null
                        ? null
                        : MemoryImage(profile.photoBytes!),
                    child: profile.photoBytes == null
                        ? Text(
                            profile.initials,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          )
                        : null,
                  ),
                  Positioned(
                    right: -3,
                    bottom: -3,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Icon(
                        Icons.photo_camera_outlined,
                        size: 14,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
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

bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
