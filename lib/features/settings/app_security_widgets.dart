import 'package:flutter/material.dart';
import '../../core/privacy/app_security.dart';

class AppSecurityScope extends InheritedNotifier<AppSecurityController> {
  const AppSecurityScope({
    super.key,
    required AppSecurityController controller,
    required super.child,
  }) : super(notifier: controller);
  static AppSecurityController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSecurityScope>()?.notifier;
}

/// Replaces the Navigator subtree while locked, disposing dialogs, message
/// composers and route state instead of retaining them under an overlay.
class AppSecurityHost extends StatelessWidget {
  const AppSecurityHost({
    super.key,
    required this.controller,
    required this.child,
  });
  final AppSecurityController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => AppSecurityScope(
    controller: controller,
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.loaded) {
          return Material(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: controller.error == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(controller.error!),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: controller.initialize,
                            child: const Text('Riprova'),
                          ),
                        ],
                      ),
              ),
            ),
          );
        }
        if (controller.locked) {
          if (!controller.enabled) {
            return Material(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (controller.cleaning) const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      controller.error ??
                          (controller.cleaning
                              ? 'Pulizia della memoria in corso…'
                              : 'Memoria locale ripulita'),
                    ),
                  ],
                ),
              ),
            );
          }
          return Navigator(
            key: const ValueKey('locked-navigator'),
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => AnimatedBuilder(
                animation: controller,
                builder: (_, _) => _UnlockPage(controller: controller),
              ),
            ),
          );
        }
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => controller.userActivity(),
          onPointerSignal: (_) => controller.userActivity(),
          child: Focus(
            canRequestFocus: false,
            onKeyEvent: (_, _) {
              controller.userActivity();
              return KeyEventResult.ignored;
            },
            child: child,
          ),
        );
      },
    ),
  );
}

class _UnlockPage extends StatefulWidget {
  const _UnlockPage({required this.controller});
  final AppSecurityController controller;
  @override
  State<_UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<_UnlockPage> {
  final _passphrase = TextEditingController();
  Future<void> _unlock() async {
    final value = _passphrase.text;
    _passphrase.clear();
    await widget.controller.unlock(value);
  }

  @override
  void dispose() {
    _passphrase.clear();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 52,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Sylphy è bloccato',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Inserisci la passphrase per aprire i dati cifrati.',
                  ),
                  if (widget.controller.cleaning) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    const Text('Pulizia della memoria in corso…'),
                  ],
                  const SizedBox(height: 24),
                  TextField(
                    key: const ValueKey('unlock-passphrase'),
                    controller: _passphrase,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    enabled:
                        !widget.controller.busy && !widget.controller.cleaning,
                    onSubmitted: (_) => _unlock(),
                    decoration: const InputDecoration(labelText: 'Passphrase'),
                  ),
                  if (widget.controller.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      widget.controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey('unlock-vault'),
                    onPressed:
                        widget.controller.busy || widget.controller.cleaning
                        ? null
                        : _unlock,
                    child: Text(
                      widget.controller.busy ? 'Apertura…' : 'Sblocca',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AppSecuritySettings extends StatelessWidget {
  const AppSecuritySettings({super.key});

  Future<void> _enable(
    BuildContext context,
    AppSecurityController controller,
  ) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final passphrase = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Proteggi i dati con una passphrase'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Usa almeno 12 caratteri, preferibilmente più parole casuali. La passphrase serve a ogni riavvio e dopo il blocco. Se la perdi, i dati locali non sono recuperabili.',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('new-passphrase'),
                  controller: first,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(labelText: 'Passphrase'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('confirm-passphrase'),
                  controller: second,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(
                    labelText: 'Ripeti passphrase',
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () {
                if (first.text.runes.length < 12 ||
                    first.text.trim().isEmpty ||
                    first.text.length > 128) {
                  update(() => error = 'Usa da 12 a 128 caratteri.');
                  return;
                }
                if (first.text != second.text) {
                  update(() => error = 'Le passphrase non coincidono.');
                  return;
                }
                final value = first.text;
                first.clear();
                second.clear();
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Attiva protezione'),
            ),
          ],
        ),
      ),
    );
    // Dialog route animations must finish before disposing its controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    first.clear();
    second.clear();
    first.dispose();
    second.dispose();
    if (passphrase == null || !context.mounted) return;
    try {
      await controller.enable(passphrase);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Protezione non attivata completamente. Riprova dalle impostazioni.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _disable(
    BuildContext context,
    AppSecurityController controller,
  ) async {
    final input = TextEditingController();
    final passphrase = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disattivare la passphrase?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'I dati resteranno cifrati con la chiave del dispositivo, ma Sylphy si aprirà senza passphrase. Inserisci la passphrase attuale per confermare.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('remove-passphrase-input'),
                controller: input,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(
                  labelText: 'Passphrase attuale',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-passphrase'),
            onPressed: () {
              if (input.text.isEmpty) return;
              final value = input.text;
              input.clear();
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Disattiva passphrase'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.clear();
    input.dispose();
    if (passphrase == null || !context.mounted) return;
    try {
      await controller.disable(passphrase);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Passphrase errata o modifica non completata. Controlla lo stato della protezione e riprova.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _policy(BuildContext context, Future<void> operation) async {
    try {
      await operation;
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impossibile salvare le condizioni di blocco.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppSecurityScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();
    return Card(
      child: Column(
        children: [
          ListTile(
            key: const ValueKey('passphrase-encryption'),
            leading: const Icon(Icons.enhanced_encryption_outlined),
            title: const Text('Cifratura dei dati con passphrase'),
            subtitle: Text(
              controller.enabled
                  ? 'Attiva · tocca per disattivare la passphrase.'
                  : 'Aggiungi una passphrase alla cifratura locale esistente.',
            ),
            trailing: controller.busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(),
                  )
                : Icon(
                    controller.enabled
                        ? Icons.check_circle_outline
                        : Icons.chevron_right,
                  ),
            onTap: controller.busy
                ? null
                : () => controller.enabled
                      ? _disable(context, controller)
                      : _enable(context, controller),
          ),
          if (controller.enabled) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<int>(
                key: const ValueKey('automatic-lock-timeout'),
                initialValue: controller.inactivitySeconds,
                decoration: const InputDecoration(
                  labelText: 'Blocco per inattività',
                ),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30 secondi')),
                  DropdownMenuItem(value: 60, child: Text('1 minuto')),
                  DropdownMenuItem(value: 300, child: Text('5 minuti')),
                  DropdownMenuItem(value: 900, child: Text('15 minuti')),
                  DropdownMenuItem(value: 0, child: Text('Disattivato')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _policy(context, controller.updatePolicy(seconds: value));
                  }
                },
              ),
            ),
            SwitchListTile(
              key: const ValueKey('automatic-lock-background'),
              title: const Text('Blocca in background'),
              subtitle: const Text(
                'Blocca quando passi a un’altra app o riduci la finestra.',
              ),
              value: controller.lockOnBackground,
              onChanged: (value) => _policy(
                context,
                controller.updatePolicy(onBackground: value),
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.android)
              SwitchListTile(
                key: const ValueKey('automatic-lock-screen-off'),
                title: const Text('Blocca allo spegnimento dello schermo'),
                subtitle: const Text(
                  'Attivo anche con il blocco in background disattivato.',
                ),
                value: controller.lockOnScreenOff,
                onChanged: (value) => _policy(
                  context,
                  controller.updatePolicy(onScreenOff: value),
                ),
              ),
            ListTile(
              key: const ValueKey('wipe-and-lock'),
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Pulisci RAM e blocca'),
              subtitle: const Text(
                'Azzera i buffer nativi di chiavi e sessioni e rimuove le cache visibili. Pulizia best effort: il sistema può conservare copie in memoria.',
              ),
              onTap: controller.lock,
            ),
          ],
          const ListTile(
            leading: Icon(Icons.memory_outlined),
            title: Text('Pulizia RAM alla chiusura sempre attiva'),
            subtitle: Text(
              'Alla chiusura Sylphy rimuove chiavi, sessioni e cache dalla memoria, anche senza passphrase. La pulizia è best effort.',
            ),
          ),
        ],
      ),
    );
  }
}
