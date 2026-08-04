import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/veilid/veilid_service.dart';

void main() {
  test('maps an attached native response without exposing routing data', () {
    const response = NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'compiled': true,
        'running': true,
        'attachment_state': 'attached_good',
        'public_internet_ready': true,
        'live_peer_count': '7',
      },
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.attached);
    expect(snapshot.livePeerCount, 7);
    expect(response.data, isNot(contains('node_id')));
    expect(response.data, isNot(contains('route_blob')));
  });

  test('reports a missing native library truthfully', () {
    final service = VeilidService(nativeCore: null);
    addTearDown(service.dispose);

    expect(service.snapshot.phase, VeilidPhase.unavailable);
    expect(service.snapshot.title, 'Core Veilid non incluso');
  });
}
