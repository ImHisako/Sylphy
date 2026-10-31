/// Process-local, bounded durations. Values never contain message/account data.
enum PerformanceStage { commandQueue, commandTotal, inboxRefreshToFrame }

class PerformanceTimings {
  static const capacity = 128;
  static final _samples = <PerformanceStage, List<int>>{};
  static final _totals = <PerformanceStage, int>{};
  static int _generation = 0;
  static int get generation => _generation;

  static void record(
    PerformanceStage stage,
    Duration elapsed, {
    int? generation,
  }) {
    if (generation != null && generation != _generation) return;
    final samples = _samples.putIfAbsent(stage, () => []);
    if (samples.length == capacity) samples.removeAt(0);
    samples.add(elapsed.inMicroseconds);
    _totals[stage] = (_totals[stage] ?? 0) + 1;
  }

  static Map<String, Object?> snapshot() => {
    'clock': 'process_monotonic',
    'sample_capacity': capacity,
    'stages': {
      for (final stage in PerformanceStage.values) stage.name: _summary(stage),
    },
  };

  static Map<String, Object?> _summary(PerformanceStage stage) {
    final values = [...?_samples[stage]]..sort();
    double? percentile(double fraction) => values.isEmpty
        ? null
        : values[(values.length * fraction).ceil() - 1] / 1000;
    return {
      'total': _totals[stage] ?? 0,
      'sampled': values.length,
      'p50_ms': percentile(.5),
      'p95_ms': percentile(.95),
      'max_ms': values.isEmpty ? null : values.last / 1000,
    };
  }

  static void clear() {
    _generation++;
    _samples.clear();
    _totals.clear();
  }
}
