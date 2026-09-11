import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/updates/app_updates.dart';

class AppUpdateScope extends InheritedNotifier<AppUpdateController> {
  const AppUpdateScope({
    super.key,
    required AppUpdateController controller,
    required super.child,
  }) : super(notifier: controller);
  static AppUpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdateScope>()?.notifier;
}

class UpdateHost extends StatefulWidget {
  const UpdateHost({
    super.key,
    required this.controller,
    required this.navigatorKey,
    required this.onRestart,
    required this.child,
  });
  final AppUpdateController controller;
  final GlobalKey<NavigatorState> navigatorKey;
  final Future<void> Function() onRestart;
  final Widget child;
  @override
  State<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends State<UpdateHost> with WidgetsBindingObserver {
  Timer? _startup;
  Timer? _periodic;
  int _shownRevision = 0;
  bool _dialogOpen = false;
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    _startup = Timer(const Duration(seconds: 8), _check);
    _periodic = Timer.periodic(const Duration(minutes: 15), (_) => _check());
  }

  void _check() {
    if (mounted && _foreground && !_dialogOpen) {
      unawaited(widget.controller.check());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _changed();
      _check();
    }
  }

  void _changed() {
    if (_dialogOpen) {
      _shownRevision = widget.controller.promptRevision;
      return;
    }
    if (!mounted ||
        !_foreground ||
        widget.controller.promptRevision <= _shownRevision ||
        widget.controller.available == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !_foreground ||
          _dialogOpen ||
          widget.controller.promptRevision <= _shownRevision) {
        return;
      }
      final context = widget.navigatorKey.currentState?.overlay?.context;
      if (context == null) return;
      _shownRevision = widget.controller.promptRevision;
      _dialogOpen = true;
      try {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => UpdateDialog(
            controller: widget.controller,
            onRestart: widget.onRestart,
          ),
        );
      } finally {
        _dialogOpen = false;
      }
    });
  }

  @override
  void dispose() {
    _startup?.cancel();
    _periodic?.cancel();
    widget.controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AppUpdateScope(controller: widget.controller, child: widget.child);
}

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.controller,
    required this.onRestart,
  });
  final AppUpdateController controller;
  final Future<void> Function() onRestart;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final update = controller.available!;
      final busy = controller.busy;
      final downloading = controller.stage == UpdateStage.downloading;
      final ready = controller.downloaded != null;
      final installed = controller.stage == UpdateStage.installed;
      return PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text(
            installed
                ? 'Aggiornamento installato'
                : 'Sylphy ${update.version.version} disponibile',
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Versione attuale: ${controller.current?.version ?? ''}',
                  ),
                  const SizedBox(height: 12),
                  if (!ready && !downloading)
                    Text(
                      'Scarica l’aggiornamento da GitHub (${(update.asset.size / 1048576).toStringAsFixed(1)} MB). Al termine ti verrà chiesto di installarlo.',
                    ),
                  if (ready && !installed)
                    const Text(
                      'Download verificato. Vuoi aggiornare Sylphy? L’account e le chat vengono conservati.',
                    ),
                  if (downloading) ...[
                    LinearProgressIndicator(value: controller.progress),
                    const SizedBox(height: 8),
                    Text('Download: ${(controller.progress * 100).floor()}%'),
                  ],
                  if (controller.stage == UpdateStage.installing) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                    const Text('Preparazione dell’aggiornamento…'),
                  ],
                  if (controller.message != null) ...[
                    const SizedBox(height: 12),
                    Text(controller.message!),
                  ],
                  if (update.notes.isNotEmpty && !downloading) ...[
                    const SizedBox(height: 16),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Novità della versione'),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(update.notes),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (downloading)
              TextButton(
                onPressed: controller.cancelDownload,
                child: const Text('Annulla download'),
              ),
            if (!busy) ...[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Più tardi'),
              ),
              if (!ready)
                TextButton(
                  onPressed: () async {
                    await controller.skip();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Salta versione'),
                ),
              if (controller.permissionRequired)
                TextButton(
                  onPressed: controller.allowAndroidInstalls,
                  child: const Text('Autorizza su Android'),
                ),
              FilledButton(
                onPressed: installed
                    ? onRestart
                    : ready
                    ? controller.install
                    : controller.download,
                child: Text(
                  installed
                      ? 'Riavvia Sylphy'
                      : ready
                      ? 'Aggiorna'
                      : 'Scarica aggiornamento',
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = AppUpdateScope.maybeOf(context);
    if (controller == null || !controller.supported) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Aggiornamenti automatici'),
            subtitle: const Text(
              'Controlla le release su GitHub all’avvio e ogni 6 ore. Download e installazione richiedono conferma.',
            ),
            value: controller.automatic,
            onChanged: controller.current == null
                ? null
                : controller.setAutomatic,
          ),
          ListTile(
            key: const ValueKey('check-app-updates'),
            leading: const Icon(Icons.system_update_alt_rounded),
            title: Text(
              controller.available == null
                  ? 'Controlla aggiornamenti'
                  : 'Apri aggiornamento disponibile',
            ),
            subtitle: Text(
              controller.message ??
                  (controller.current == null
                      ? 'Release GitHub ufficiali'
                      : 'Versione ${controller.current!.version} (${controller.current!.build})'),
            ),
            trailing: controller.busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: controller.busy
                ? null
                : () {
                    if (controller.available != null) {
                      controller.showAvailable();
                    } else {
                      unawaited(controller.check(manual: true));
                    }
                  },
          ),
        ],
      ),
    );
  }
}
