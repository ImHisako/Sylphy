import 'core/privacy/app_palette.dart';
import 'dart:async';
import 'dart:io';
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
import 'core/platform/stream_proof_host.dart';
import 'core/veilid/veilid_service.dart';
import 'features/messenger/messenger_home.dart';
import 'features/onboarding/profile_onboarding.dart';
import 'core/updates/app_updates.dart';
import 'features/updates/update_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Diagnostics must never delay Flutter's first frame. In particular, a
  // stalled platform storage call previously left Android on its launch
  // window with no way to recover until the process was force-stopped.
  unawaited(AppLog.instance.initialize());
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
  runApp(
    SylphyApp(
      nativeCore: nativeCore,
      updates: AppUpdateController.production(),
    ),
  );
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
    this.updates,
  });

  final SecureMessagingBridge? bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService? veilidService;
  final UserProfileStore? profileStore;
  final ProfilePhotoPicker? photoPicker;
  final IdentityService? identityService;
  final PrivacySettingsController? privacySettings;
  final AppUpdateController? updates;

  @override
  State<SylphyApp> createState() => _SylphyAppState();
}

class _SylphyAppState extends State<SylphyApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
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
  int _nativeServicesGeneration = 0;
  Timer? _identityRepublishTimer;
  DateTime? _lastRouteRefresh;

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
            ? UnavailableMessagingBridge()
            : SylphyMessagingBridge(core: widget.nativeCore!));
    _ownsVeilidService = widget.veilidService == null;
    _veilidService =
        widget.veilidService ?? VeilidService(nativeCore: widget.nativeCore);
    final profileCipher = widget.nativeCore is NativeCoreClient
        ? NativeLocalDataCipher(
            core: widget.nativeCore! as NativeCoreClient,
            password: PlatformDeviceSecretStore().getOrCreate,
          )
        : UnavailableLocalDataCipher();
    _profileStore =
        widget.profileStore ?? FileUserProfileStore(cipher: profileCipher);
    _ownsIdentityService = widget.identityService == null;
    _identityService =
        widget.identityService ??
        IdentityService(nativeCore: widget.nativeCore);
    _privacySettings =
        widget.privacySettings ??
        PrivacySettingsController(cipher: profileCipher);
    _privacySettings.addListener(_onPrivacyChanged);
    _veilidService.addListener(_onRouteChanged);
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
      _runGuarded(
        MessageNotifications().initialize(),
        category: 'notifications',
        action: 'initialization_failed',
      );
      await Future.wait<void>([
        if (!_privacySettings.loaded) _privacySettings.load(),
        _profileLoadFuture,
      ]);
      await _configureNativePrivacy();
      // Unlock the local identity before waiting for the P2P node to attach.
      // On a cold desktop start this makes the profile usable immediately.
      if (_profile != null) {
        await _publishProfile();
      }
      await _veilidService.start();
      if (_profile != null && !_identityService.snapshot.hasShortInvitation) {
        await _publishProfile();
      }
    } finally {
      _nativeServicesReady = true;
      if (mounted) {
        setState(() => _nativeServicesGeneration++);
      }
    }
  }

  Future<void> _publishProfile({bool forceRefresh = false}) async {
    await _identityService.initialize(
      profile: _profile,
      shareDisplayName: _privacySettings.value.shareDisplayName,
      shareProfilePhoto: _privacySettings.value.shareProfilePhoto,
      forceRefresh: forceRefresh,
    );
    _scheduleShortInvitationRefresh();
  }

  void _onRouteChanged() {
    if (!_nativeServicesReady ||
        _profile == null ||
        !_veilidService.snapshot.isAttached ||
        !_veilidService.snapshot.routeNeedsPublish) {
      return;
    }
    final now = DateTime.now();
    if (_lastRouteRefresh != null &&
        now.difference(_lastRouteRefresh!) < Duration(seconds: 15)) {
      return;
    }
    _lastRouteRefresh = now;
    _runGuarded(
      _publishProfile(forceRefresh: true),
      category: 'identity',
      action: 'route_republish_failed',
    );
  }

  void _scheduleShortInvitationRefresh() {
    if (_identityService.snapshot.hasShortInvitation) {
      _identityRepublishTimer?.cancel();
      _identityRepublishTimer = null;
      return;
    }
    _identityRepublishTimer ??= Timer.periodic(Duration(seconds: 6), (timer) {
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
    if (mounted) setState(() {});
    if (!_nativeServicesReady) {
      return;
    }
    _runGuarded(
      _applyPrivacyChanges(),
      category: 'identity',
      action: 'privacy_publish_failed',
    );
  }

  Future<void> _applyPrivacyChanges() async {
    await _configureNativePrivacy();
    await _publishProfile();
  }

  Future<void> _configureNativePrivacy() async {
    final core = widget.nativeCore;
    if (core is! NativeCoreClient) return;
    final response = await core.configurePrivacyInBackground(
      allowUnknownContacts: _privacySettings.value.allowUnknownContacts,
      sendReadReceipts: _privacySettings.value.sendReadReceipts,
    );
    if (!response.ok) {
      throw NativeCoreException(
        'Configurazione privacy nativa rifiutata: ${response.code}',
      );
    }
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

  void _accountImported(UserProfile profile) {
    if (_bridge is SylphyMessagingBridge) {
      _bridge.clearCachesAfterAccountImport();
    }
    _identityService.invalidateAfterAccountImport();
    setState(() {
      _profile = profile;
      _isEditingProfile = false;
      _nativeServicesGeneration++;
    });
    _runGuarded(
      _resumeNativeServices(),
      category: 'account',
      action: 'import_resume_failed',
    );
  }

  @override
  void dispose() {
    widget.updates?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _privacySettings.removeListener(_onPrivacyChanged);
    _veilidService.removeListener(_onRouteChanged);
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
    if (state == AppLifecycleState.resumed) {
      _runGuarded(
        _resumeNativeServices(),
        category: 'lifecycle',
        action: 'resume_failed',
      );
    }
  }

  Future<void> _resumeNativeServices() async {
    await _veilidService.start();
    if (_profile != null) {
      await _publishProfile(forceRefresh: true);
    }
    if (mounted) {
      setState(() => _nativeServicesGeneration++);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppPalette.themeName = _privacySettings.value.themeName;
    final surface = AppPalette.color(0xFF0C0F14);
    final primary = AppPalette.color(0xFFCFF36A);
    final onSurface = AppPalette.color(0xFFF4F7F2);
    final outline = AppPalette.color(0xFF323943);
    final colorScheme = ColorScheme.fromSeed(
      brightness: AppPalette.isLight ? Brightness.light : Brightness.dark,
      seedColor: primary,
      primary: primary,
      onPrimary: AppPalette.color(0xFF1B2500),
      surface: surface,
      onSurface: onSurface,
      outline: outline,
    );

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Sylphy',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [_DiagnosticNavigatorObserver()],
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            disableAnimations:
                media.disableAnimations || _privacySettings.value.reduceMotion,
          ),
          child: StreamProofHost(
            settings: _privacySettings,
            child: widget.updates == null
                ? child ?? SizedBox.shrink()
                : UpdateHost(
                    controller: widget.updates!,
                    navigatorKey: _navigatorKey,
                    onRestart: () async {
                      if (await widget.updates!.prepareRestart()) {
                        await _veilidService.stop();
                        exit(0);
                      }
                    },
                    child: child ?? SizedBox.shrink(),
                  ),
          ),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: surface,
        dividerColor: outline.withValues(alpha: 0.65),
        visualDensity: VisualDensity.standard,
        splashFactory: InkSparkle.splashFactory,
        appBarTheme: AppBarTheme(
          centerTitle: false,
          backgroundColor: surface,
          foregroundColor: onSurface,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppPalette.color(0xFF171C24),
          hintStyle: TextStyle(color: AppPalette.color(0xFF9299A5)),
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
            borderSide: BorderSide(color: primary, width: 1.4),
          ),
        ),
        cardTheme: CardThemeData(
          color: AppPalette.color(0xFF151A21),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: outline.withValues(alpha: 0.55)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppPalette.color(0xFF252B34),
          contentTextStyle: TextStyle(
            color: AppPalette.color(0xFFF4F7F2),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          actionTextColor: primary,
          disabledActionTextColor: AppPalette.color(0xFF9299A5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: !_profileLoaded
          ? Scaffold(body: Center(child: CircularProgressIndicator()))
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
                servicesReady: _nativeServicesReady,
                servicesGeneration: _nativeServicesGeneration,
                onAccountImported: _accountImported,
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
