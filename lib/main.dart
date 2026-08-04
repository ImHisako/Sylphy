import 'dart:async';

import 'package:flutter/material.dart';

import 'core/messaging/secure_messaging_bridge.dart';
import 'core/messaging/sylphy_messaging_bridge.dart';
import 'core/native/native_core.dart';
import 'core/profile/user_profile.dart';
import 'core/veilid/veilid_service.dart';
import 'features/messenger/messenger_home.dart';
import 'features/onboarding/profile_onboarding.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SylphyApp(nativeCore: NativeCoreClient.tryLoad()));
}

class SylphyApp extends StatefulWidget {
  const SylphyApp({
    super.key,
    this.bridge,
    this.nativeCore,
    this.veilidService,
    this.profileStore,
    this.photoPicker,
  });

  final SecureMessagingBridge? bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService? veilidService;
  final UserProfileStore? profileStore;
  final ProfilePhotoPicker? photoPicker;

  @override
  State<SylphyApp> createState() => _SylphyAppState();
}

class _SylphyAppState extends State<SylphyApp> {
  late final SecureMessagingBridge _bridge;
  late final VeilidService _veilidService;
  late final bool _ownsVeilidService;
  late final UserProfileStore _profileStore;
  UserProfile? _profile;
  bool _profileLoaded = false;

  @override
  void initState() {
    super.initState();
    _bridge =
        widget.bridge ??
        (widget.nativeCore == null
            ? const UnavailableMessagingBridge()
            : SylphyMessagingBridge(core: widget.nativeCore!));
    _ownsVeilidService = widget.veilidService == null;
    _veilidService =
        widget.veilidService ?? VeilidService(nativeCore: widget.nativeCore);
    _profileStore = widget.profileStore ?? FileUserProfileStore();
    unawaited(_loadProfile());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_veilidService.start());
      }
    });
  }

  Future<void> _loadProfile() async {
    UserProfile? profile;
    try {
      profile = await _profileStore.load();
    } on Exception {
      profile = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _profile = profile;
      _profileLoaded = true;
    });
  }

  void _completeOnboarding(UserProfile profile) {
    setState(() => _profile = profile);
  }

  @override
  void dispose() {
    if (_ownsVeilidService) {
      unawaited(_veilidService.stop());
      _veilidService.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const surface = Color(0xFF0C0F14);
    const primary = Color(0xFFCFF36A);
    const onSurface = Color(0xFFF4F7F2);
    const outline = Color(0xFF323943);
    final colorScheme = ColorScheme.fromSeed(
      brightness: Brightness.dark,
      seedColor: primary,
      primary: primary,
      onPrimary: const Color(0xFF1B2500),
      surface: surface,
      onSurface: onSurface,
      outline: outline,
    );

    return MaterialApp(
      title: 'Sylphy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: surface,
        dividerColor: outline.withValues(alpha: 0.65),
        visualDensity: VisualDensity.standard,
        splashFactory: InkSparkle.splashFactory,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: surface,
          foregroundColor: onSurface,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF171C24),
          hintStyle: const TextStyle(color: Color(0xFF9299A5)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: outline.withValues(alpha: 0.6)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: primary, width: 1.4),
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF151A21),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: outline.withValues(alpha: 0.55)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF252B34),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: !_profileLoaded
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _profile == null
          ? ProfileOnboarding(
              profileStore: _profileStore,
              photoPicker: widget.photoPicker,
              onCompleted: _completeOnboarding,
            )
          : AnimatedBuilder(
              animation: _veilidService,
              builder: (context, _) => MessengerHome(
                bridge: _bridge,
                nativeCore: widget.nativeCore,
                veilidService: _veilidService,
                profile: _profile!,
              ),
            ),
    );
  }
}
