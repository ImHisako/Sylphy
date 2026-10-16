import 'package:flutter/material.dart';

import '../../core/identity/identity_service.dart';
import '../../core/privacy/privacy_settings.dart';

class IdentityRotationSettings extends StatefulWidget {
  const IdentityRotationSettings({
    super.key,
    required this.identityService,
    required this.privacySettings,
  });

  final IdentityService identityService;
  final PrivacySettingsController privacySettings;

  @override
  State<IdentityRotationSettings> createState() =>
      _IdentityRotationSettingsState();
}

class _IdentityRotationSettingsState extends State<IdentityRotationSettings> {
  bool _saving = false;
  static const _presets = {
    0: 'Solo manualmente',
    1: 'Ogni ora',
    6: 'Ogni 6 ore',
    24: 'Ogni giorno',
    168: 'Ogni settimana',
    720: 'Ogni 30 giorni',
  };

  Future<void> _chooseInterval() async {
    final current = widget.privacySettings.value.identityRotationHours;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Quando cambiare ID'),
        children: [
          for (final entry in _presets.entries)
            SimpleDialogOption(
              key: ValueKey('identity-interval-${entry.key}'),
              onPressed: () => Navigator.pop(context, entry.key),
              child: Row(
                children: [
                  Expanded(child: Text(entry.value)),
                  if (current == entry.key) const Icon(Icons.check),
                ],
              ),
            ),
          SimpleDialogOption(
            key: const ValueKey('identity-interval-custom'),
            onPressed: () => Navigator.pop(context, -1),
            child: const Text('Intervallo personalizzato…'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    var hours = selected;
    if (hours == -1) {
      final custom = await showDialog<int>(
        context: context,
        builder: (context) =>
            _CustomIntervalDialog(initialHours: current > 0 ? current : 24),
      );
      if (!mounted || custom == null) return;
      hours = custom;
    }
    setState(() => _saving = true);
    try {
      await widget.privacySettings.update(
        widget.privacySettings.value.copyWith(identityRotationHours: hours),
      );
      if (widget.privacySettings.storageError == null) {
        final privacy = widget.privacySettings.value;
        await widget.identityService.initialize(
          rotationIntervalSeconds: hours * 3600,
          shareDisplayName: privacy.shareDisplayName,
          shareProfilePhoto: privacy.shareProfilePhoto,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rotateNow() async {
    final changed = await widget.identityService.rotateNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          changed
              ? 'ID Sylphy cambiato. Puoi copiare quello nuovo dal tuo profilo.'
              : 'ID non cambiato. Verifica la connessione e riprova.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.identityService,
      widget.privacySettings,
    ]),
    builder: (context, _) {
      final identity = widget.identityService;
      final hours = widget.privacySettings.value.identityRotationHours;
      final next = identity.nextRotationAt;
      final busy = _saving || identity.rotationInProgress;
      final interval = _presets[hours] ?? 'Ogni $hours ore';
      final nextText = identity.rotationPolicyPending
          ? 'Impostazione in attesa della connessione.'
          : hours == 0
          ? 'Il cambio automatico è disattivato.'
          : next == null
          ? 'Attivazione in attesa della connessione.'
          : 'Prossimo cambio: ${MaterialLocalizations.of(context).formatShortDate(next)} alle ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(next), alwaysUse24HourFormat: true)}.';
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'ID SYLPHY',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              ListTile(
                key: const ValueKey('identity-rotation-interval'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.update),
                title: const Text('Cambio automatico dell’ID'),
                subtitle: Text(interval),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy ? null : _chooseInterval,
              ),
              Text(nextText),
              const SizedBox(height: 8),
              const Text(
                'Cambia il codice da condividere e conserva account, chat e contatti. A app chiusa o bloccata il cambio viene eseguito alla riapertura, con rete disponibile.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('rotate-identity-now'),
                onPressed: !identity.canRotate || busy ? null : _rotateNow,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(
                  identity.rotationInProgress
                      ? 'Cambio ID in corso…'
                      : 'Cambia ID adesso',
                ),
              ),
              if (identity.revocationPending)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Il nuovo ID è pronto. La disattivazione del precedente è ancora in attesa della rete.',
                  ),
                ),
              if (identity.rotationError != null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Rinnovo non completato. Controlla la connessione e riprova.',
                  ),
                ),
              if (widget.privacySettings.storageError != null)
                const Text('Impossibile salvare l’intervallo. Riprova.'),
            ],
          ),
        ),
      );
    },
  );
}

class _CustomIntervalDialog extends StatefulWidget {
  const _CustomIntervalDialog({required this.initialHours});
  final int initialHours;
  @override
  State<_CustomIntervalDialog> createState() => _CustomIntervalDialogState();
}

class _CustomIntervalDialogState extends State<_CustomIntervalDialog> {
  late final _input = TextEditingController(text: '${widget.initialHours}');
  String? _error;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Intervallo in ore'),
    content: TextField(
      key: const ValueKey('identity-custom-hours'),
      controller: _input,
      autofocus: true,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Da 1 a 8760 ore',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annulla'),
      ),
      FilledButton(
        onPressed: () {
          final value = int.tryParse(_input.text.trim());
          if (value == null || value < 1 || value > 8760) {
            setState(() => _error = 'Inserisci un numero intero da 1 a 8760.');
            return;
          }
          Navigator.pop(context, value);
        },
        child: const Text('Salva'),
      ),
    ],
  );
}
