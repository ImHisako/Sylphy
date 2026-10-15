import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/core/veilid/veilid_service.dart';
import 'package:sylphy/main.dart';

void main() {
  for (final entry in {
    'cyan': const Color(0xFF72DCFF),
    'pink': const Color(0xFFFFA6D8),
  }.entries) {
    testWidgets(
      'connected network and empty inbox use the ${entry.key} accent',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final settings = _ThemeSettings(entry.key);
        final network = _ConnectedNetwork();
        addTearDown(settings.dispose);
        addTearDown(network.dispose);
        await tester.pumpWidget(
          SylphyApp(
            privacySettings: settings,
            veilidService: network,
            profileStore: _ProfileStore(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Nessuna conversazione sicura'), findsOneWidget);
        final labels = tester.widgetList<Text>(
          find.text('Rete Veilid connessa'),
        );
        expect(labels.any((text) => text.style?.color == entry.value), isTrue);
        final icon = tester.widget<Icon>(
          find.byIcon(Icons.mark_chat_unread_outlined),
        );
        expect(icon.color, entry.value);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _ThemeSettings extends PrivacySettingsController {
  _ThemeSettings(this.theme)
    : super(cipher: const UnavailableLocalDataCipher());
  final String theme;
  @override
  bool get loaded => true;
  @override
  PrivacySettings get value => PrivacySettings(themeName: theme);
}

class _ConnectedNetwork extends VeilidService {
  _ConnectedNetwork() : super(nativeCore: null);
  @override
  VeilidSnapshot get snapshot =>
      const VeilidSnapshot(phase: VeilidPhase.attached);
}

class _ProfileStore implements UserProfileStore {
  @override
  Future<UserProfile?> load() async => const UserProfile(displayName: 'Ada');
  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async => UserProfile(displayName: displayName, photoBytes: photoBytes);
}
