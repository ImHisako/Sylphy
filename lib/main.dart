import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/diagnostics/app_log.dart';
import 'core/messaging/secure_messaging_bridge.dart';
import 'core/messaging/sylphy_messaging_bridge.dart';
import 'core/identity/identity_service.dart';
import 'core/native/native_core.dart';
import 'core/profile/user_profile.dart';
import 'core/privacy/privacy_settings.dart';
import 'core/platform/message_notifications.dart';
import 'core/veilid/veilid_service.dart';
import 'features/messenger/messenger_home.dart';
import 'features/onboarding/profile_onboarding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.initialize();
  FlutterError.onError = (details) {
    AppLog.instance.recordError(
      category: 'flutter',
      action: 'framework_error',
      error: details.exception,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.recordError(
      category: 'dart',
      action: 'uncaught_error',
      error: error,
    );
    // The error has been recorded. Returning false forwards it as unhandled
    // and can terminate release builds on both Android and Windows.
    return true;
  };
  final nativeCore = NativeCoreClient.tryLoad();
  AppLog.instance.record(
    category: 'native_core',
    action: 'library_load',
    level: nativeCore == null ? AppLogLevel.error : AppLogLevel.info,
    result: nativeCore == null ? 'unavailable' : 'abi_${nativeCore.abiVersion}',
    force: nativeCore == null,
  );
  runApp(SylphyApp(nativeCore: nativeCore));
}

class SylphyApp extends StatefulWidget {
  const SylphyApp({
    super.key,
    this.bridge,
    this.nativeCore,
    this.veilidService,
    this.profileStore,
    this.photoPicker,
    this.identityService,
    this.privacySettings,
  });

  final SecureMessagingBridge? bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService? veilidService;
  final UserProfileStore? profileStore;
  final ProfilePhotoPicker? photoPicker;
  final IdentityService? identityService;
  final PrivacySettingsController? privacySettings;

  @override
  State<SylphyApp> createState() => _SylphyAppState();
}

class _SylphyAppState extends State<SylphyApp> with WidgetsBindingObserver {
  late final SecureMessagingBridge _bridge;
  late final VeilidService _veilidService;
  late final bool _ownsVeilidService;
  late final UserProfileStore _profileStore;
  late final IdentityService _identityService;
  late final bool _ownsIdentityService;
  late final PrivacySettingsController _privacySettings;
  late final Future<void> _profileLoadFuture;
  UserProfile? _profile;
  bool _profileLoaded = false;
  bool _isEditingProfile = false;
  bool _nativeServicesReady = false;
  Timer? _identityRepublishTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLog.instance.record(
      category: 'app',
      action: 'application_started',
      verbose: true,
    );
    _bridge =
        widget.bridge ??
        (widget.nativeCore == null
            ? const UnavailableMessagingBridge()
            : SylphyMessagingBridge(core: widget.nativeCore!));
    _ownsVeilidService = widget.veilidService == null;
    _veilidService =
        widget.veilidService ?? VeilidService(nativeCore: widget.nativeCore);
    _profileStore = widget.profileStore ?? FileUserProfileStore();
    _ownsIdentityService = widget.identityService == null;
    _identityService =
        widget.identityService ??
        IdentityService(nativeCore: widget.nativeCore);
    _privacySettings = widget.privacySettings ?? PrivacySettingsController();
    _privacySettings.addListener(_onPrivacyChanged);
    _profileLoadFuture = _loadProfile();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _runGuarded(
          _initializeNativeServices(),
          category: 'app',
          action: 'native_services_initialization_failed',
        );
      }
    });
  }

  Future<void> _initializeNativeServices() async {
    try {
      await const MessageNotifications().initialize();
      if (!_privacySettings.loaded) await _privacySettings.load();
      await _profileLoadFuture;
      await _veilidService.start();
      if (_profile != null) {
        await _publishProfile();
      }
    } finally {
      _nativeServicesReady = true;
    }
  }

  Future<void> _publishProfile() async {
    await _identityService.initialize(
      profile: _profile,
      shareDisplayName: _privacySettings.value.shareDisplayName,
      shareProfilePhoto: _privacySettings.value.shareProfilePhoto,
    );
    _scheduleShortInvitationRefresh();
  }

  void _scheduleShortInvitationRefresh() {
    if (_identityService.snapshot.hasShortInvitation) {
      _identityRepublishTimer?.cancel();
      _identityRepublishTimer = null;
      return;
    }
    _identityRepublishTimer ??= Timer.periodic(const Duration(seconds: 6), (
      timer,
    ) {
      if (!mounted || _identityService.snapshot.hasShortInvitation) {
        timer.cancel();
        _identityRepublishTimer = null;
        return;
      }
      if (_veilidService.snapshot.isAttached) {
        _runGuarded(
          _publishProfile(),
          category: 'identity',
          action: 'short_invitation_refresh_failed',
        );
      }
    });
  }

  void _onPrivacyChanged() {
    if (!_nativeServicesReady) {
      return;
    }
    _runGuarded(
      _publishProfile(),
      category: 'identity',
      action: 'privacy_publish_failed',
    );
  }

  void _runGuarded(
    Future<void> operation, {
    required String category,
    required String action,
  }) {
    unawaited(
      operation.catchError((Object error) {
        AppLog.instance.recordError(
          category: category,
          action: action,
          error: error,
        );
      }),
    );
  }

  Future<void> _loadProfile() async {
    AppLog.instance.record(
      category: 'profile',
      action: 'load_started',
      verbose: true,
    );
    UserProfile? profile;
    try {
      profile = await _profileStore.load();
      AppLog.instance.record(
        category: 'profile',
        action: 'load_completed',
        result: profile == null ? 'missing' : 'available',
        verbose: true,
      );
    } on Exception catch (error) {
      profile = null;
      AppLog.instance.recordError(
        category: 'profile',
        action: 'load_failed',
        error: error,
      );
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
    AppLog.instance.record(
      category: 'profile',
      action: 'onboarding_completed',
      verbose: true,
    );
    setState(() {
      _profile = profile;
      _isEditingProfile = false;
    });
    _runGuarded(
      _publishProfile(),
      category: 'identity',
      action: 'profile_publish_failed',
    );
  }

  void _editProfile() {
    AppLog.instance.record(
      category: 'profile',
      action: 'edit_opened',
      verbose: true,
    );
    setState(() => _isEditingProfile = true);
  }

  void _cancelProfileEdit() => setState(() => _isEditingProfile = false);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _privacySettings.removeListener(_onPrivacyChanged);
    _identityRepublishTimer?.cancel();
    if (_ownsVeilidService) {
      unawaited(_veilidService.stop());
      _veilidService.dispose();
    }
    if (_ownsIdentityService) {
      _identityService.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.instance.record(
      category: 'lifecycle',
      action: 'state_changed',
      result: state.name,
      verbose: true,
    );
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
      navigatorObservers: [_DiagnosticNavigatorObserver()],
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
          contentTextStyle: const TextStyle(
            color: Color(0xFFF4F7F2),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          actionTextColor: primary,
          disabledActionTextColor: const Color(0xFF9299A5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: !_profileLoaded
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _profile == null || _isEditingProfile
          ? ProfileOnboarding(
              profileStore: _profileStore,
              photoPicker: widget.photoPicker,
              onCompleted: _completeOnboarding,
              initialProfile: _isEditingProfile ? _profile : null,
              onCancelled: _isEditingProfile ? _cancelProfileEdit : null,
            )
          : AnimatedBuilder(
              animation: Listenable.merge([_veilidService, _identityService]),
              builder: (context, _) => MessengerHome(
                bridge: _bridge,
                nativeCore: widget.nativeCore,
                veilidService: _veilidService,
                profile: _profile!,
                identityService: _identityService,
                privacySettings: _privacySettings,
                onEditProfile: _editProfile,
              ),
            ),
    );
  }
}

class _DiagnosticNavigatorObserver extends NavigatorObserver {
  void _record(String action, Route<dynamic>? route) {
    AppLog.instance.record(
      category: 'navigation',
      action: action,
      result: route?.settings.name ?? route?.runtimeType.toString() ?? 'none',
      verbose: true,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('route_pushed', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('route_popped', route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _record('route_replaced', newRoute);
  }
}
