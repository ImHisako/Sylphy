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
import '../../core/identity/identity_service.dart';
import '../updates/update_host.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.veilidService,
    required this.privacySettings,
    required this.profile,
    required this.onAccountImported,
    this.nativeCore,
    this.identityService,
  });

  final VeilidService veilidService;
  final NativeCoreApi? nativeCore;
  final IdentityService? identityService;
  final PrivacySettingsController privacySettings;
  final UserProfile profile;
  final ValueChanged<UserProfile> onAccountImported;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _diagnosticResult;
  bool _diagnosticRunning = false;
  String? _selectedSection;
  String _query = '';
  final _search = TextEditingController();

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
                  ListTile(
                    key: const ValueKey('export-account'),
                    leading: const Icon(Icons.add_to_home_screen_rounded),
                    title: const Text('Collega un altro dispositivo'),
                    subtitle: const Text(
                      'File cifrato, condivisione o QR sulla rete locale.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openAccountTransfer(AccountTransferMode.send),
                  ),
                  const Divider(height: 1),
                  ListTile(
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
              const SizedBox(height: 16),
            ],
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
            _SectionTitle('CONTATTI E RICHIESTE'),
            SizedBox(height: 8),
            _SettingsCard(
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
                  ),
                  if (_isAndroidPlatform)
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
            _SectionTitle('ACCESSIBILITÀ'),
            SizedBox(height: 8),
            _SettingsCard(
              child: SwitchListTile(
                secondary: Icon(Icons.motion_photos_off_outlined),
                title: Text('Riduci animazioni'),
                value: privacy.reduceMotion,
                onChanged: (value) => widget.privacySettings.update(
                  privacy.copyWith(reduceMotion: value),
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
          detail: 'DEVELOPER OPTIONS · controlli e log senza messaggi o chiavi',
          icon: Icons.bug_report_outlined,
          children: [
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
                    key: const ValueKey('basic-logging-switch'),
                    secondary: const Icon(Icons.receipt_long_outlined),
                    title: const Text('Logging di base'),
                    subtitle: const Text(
                      'Registra eventi ed errori diagnostici dell’app. Disattivalo per sospendere anche il logging dettagliato.',
                    ),
                    value: AppLog.instance.loggingEnabled,
                    onChanged: AppLog.instance.setLoggingEnabled,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
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
        ),
      ];
      final selected = sections
          .where((section) => section.id == _selectedSection)
          .firstOrNull;
      final visible = sections
          .where(
            (section) => '${section.title} ${section.detail}'
                .toLowerCase()
                .contains(_query.toLowerCase()),
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
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: selected != null
                  ? ListView(
                      key: ValueKey('settings-content-${selected.id}'),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: selected.children,
                    )
                  : ListView(
                      key: const ValueKey('settings-index'),
                      padding: const EdgeInsets.all(16),
                      children: [
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
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            labelText: 'Cerca nelle impostazioni',
                          ),
                          onChanged: (value) => setState(() => _query = value),
                        ),
                        const SizedBox(height: 16),
                        if (visible.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Nessuna sezione corrispondente. Prova un’altra parola.',
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
                                onTap: () {
                                  FocusScope.of(context).unfocus();
                                  setState(() => _selectedSection = section.id);
                                },
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
