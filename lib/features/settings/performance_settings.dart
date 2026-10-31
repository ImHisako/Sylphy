import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/performance_timings.dart';
import '../../core/native/native_core.dart';

class PerformanceSettings extends StatelessWidget {
  const PerformanceSettings({super.key, required this.nativeCore});
  final NativeCoreApi? nativeCore;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const ValueKey('performance-settings'),
      leading: const Icon(Icons.speed_rounded),
      title: const Text('Prestazioni dei messaggi'),
      subtitle: const Text('Tempi locali, campioni e confronto prima/dopo'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _PerformanceDialog(api: nativeCore),
      ),
    ),
  );
}

class _PerformanceDialog extends StatefulWidget {
  const _PerformanceDialog({required this.api});
  final NativeCoreApi? api;
  @override
  State<_PerformanceDialog> createState() => _PerformanceDialogState();
}

class _PerformanceDialogState extends State<_PerformanceDialog> {
  Map<String, Object?>? _report;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final api = widget.api;
      Map<String, dynamic>? native;
      if (api is NativePerformanceApi) {
        final response = await (api as NativePerformanceApi)
            .performanceSnapshot(reset: reset);
        if (!response.ok) throw const FormatException();
        native = response.data;
      }
      if (reset) PerformanceTimings.clear();
      if (!mounted) return;
      setState(() {
        _error = null;
        _report = {
          'format': 'sylphy-performance',
          'version': 1,
          'app': PerformanceTimings.snapshot(),
          'native': reset ? null : native,
        };
      });
    } on Object {
      if (mounted) {
        setState(
          () => _error = 'Misure non disponibili. Riprova con l’app sbloccata.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Prestazioni dei messaggi'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ultimi 128 campioni per fase. Tempi in millisecondi: mediana e 95° percentile. Le fasi sono misurate separatamente e non rappresentano il tempo totale tra due dispositivi.',
            ),
            const SizedBox(height: 12),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            if (_report case final report?) ...[
              for (final source in ['app', 'native'])
                if (report[source] case final Map data) ...[
                  if (data['active_uploads'] case final int count)
                    Text('Upload attivi: $count'),
                  if (data['stages'] case final Map stages)
                    for (final entry in stages.entries)
                      if (entry.value case final Map stats)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Text(
                            '${_label(entry.key.toString())}: ${_ms(stats['p50_ms'])} / ${_ms(stats['p95_ms'])} ms · ${stats['sampled'] ?? 0} campioni',
                          ),
                        ),
                ],
            ],
            const SizedBox(height: 8),
            const Text(
              'Le misure restano in memoria. Il report contiene durate e contatori, senza testi, contatti, file o chiavi.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _loading ? null : () => _load(reset: true),
        child: const Text('Azzera'),
      ),
      TextButton(
        onPressed: _loading ? null : _load,
        child: const Text('Aggiorna'),
      ),
      TextButton(
        onPressed: _report == null || _loading
            ? null
            : () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert(_report),
                  ),
                );
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      content: Text('Report prestazioni copiato.'),
                    ),
                  );
                }
              },
        child: const Text('Copia report'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Chiudi'),
      ),
    ],
  );

  String _ms(Object? value) => value is num ? value.toStringAsFixed(1) : '—';
  String _label(String stage) =>
      const {
        'commandQueue': 'Attesa nella coda dell’app',
        'commandTotal': 'Esecuzione del comando',
        'inboxRefreshToFrame': 'Aggiornamento delle conversazioni',
        'command_wait': 'Attesa del core',
        'text_prepare': 'Preparazione e salvataggio del testo',
        'upload': 'Caricamento allegato',
        'direct': 'Consegna diretta',
        'offline': 'Deposito offline',
        'mailbox_poll': 'Lettura mailbox',
        'inbound_persist': 'Salvataggio in ricezione',
      }[stage] ??
      stage;
}
