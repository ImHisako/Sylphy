import 'core/privacy/app_palette.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/diagnostics/app_log.dart';
import 'core/messaging/secure_messaging_bridge.dart';
import 'core/messaging/sylphy_messaging_bridge.dart';
import 'core/identity/identity_service.dart';
import 'core/native/native_core.dart';
import 'core/profile/user_profile.dart';
import 'core/privacy/privacy_settings.dart';
import 'core/privacy/app_security.dart';
import 'features/settings/app_security_widgets.dart';
import 'features/settings/account_transfer_page.dart';
import 'features/settings/account_transfer_recovery.dart';
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
    if (AppLog.instance.initialized && AppLog.instance.loggingEnabled) {
      FlutterError.presentError(details);
    }
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
    this.appSecurity,
  });

  final SecureMessagingBridge? bridge;
  final NativeCoreApi? nativeCore;
  final VeilidService? veilidService;
  final UserProfileStore? profileStore;
  final ProfilePhotoPicker? photoPicker;
  final IdentityService? identityService;
  final PrivacySettingsController? privacySettings;
  final AppUpdateController? updates;
  final AppSecurityController? appSecurity;

  @override
  State<SylphyApp> createState() => _SylphyAppState();
}

class _SylphyAppState extends State<SylphyApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _accountTransferRecovery = AccountTransferRecovery();
  bool _transferRecoveryScheduled = false;
  late final SecureMessagingBridge _bridge;
  late final VeilidService _veilidService;
  late final bool _ownsVeilidService;
  late final UserProfileStore _profileStore;
  late final IdentityService _identityService;
  late final bool _ownsIdentityService;
  late final PrivacySettingsController _privacySettings;
  late final AppSecurityController? _appSecurity;
  bool _initialSecurityResolved = false;
  bool _lastSecurityLocked = true;
  int _localGeneration = 0;
  late final Future<void> _profileLoadFuture;
  UserProfile? _profile;
  bool _profileLoaded = false;
  bool _isEditingProfile = false;
  bool _nativeServicesReady = false;
  int _nativeServicesGeneration = 0;
  Timer? _identityRepublishTimer;
  int _identityRetrySeconds = 6;
  bool _identityRetryInProgress = false;
  DateTime? _lastRouteRefresh;
  Timer? _routeRefreshTimer;
  bool _routeRefreshInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _accountTransferRecovery.addListener(_resumePendingAccountTransfer);
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
    final core = widget.nativeCore;
    _appSecurity =
        widget.appSecurity ??
        (core is NativeCoreClient
            ? AppSecurityController(command: core.securityCommandInBackground)
            : null);
    _appSecurity?.addListener(_onSecurityChanged);
    _privacySettings.addListener(_onPrivacyChanged);
    _veilidService.addListener(_onRouteChanged);
    _profileLoadFuture = _prepareLocalData();
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

  Future<void> _prepareLocalData() async {
    await _appSecurity?.initialize();
    _initialSecurityResolved = true;
    _lastSecurityLocked = _appSecurity?.locked ?? false;
    if (!_localDataAccessible) return;
    await _loadProfile();
  }

  bool get _localDataAccessible =>
      _appSecurity == null || (_appSecurity.loaded && !_appSecurity.locked);

  void _onSecurityChanged() {
    if (!mounted) return;
    if (!_initialSecurityResolved) {
      setState(() {});
      return;
    }
    final locked = !_localDataAccessible;
    if (locked == _lastSecurityLocked) {
      setState(() {});
      return;
    }
    _lastSecurityLocked = locked;
    if (locked) {
      _localGeneration++;
      _identityRepublishTimer?.cancel();
      _identityRepublishTimer = null;
      _routeRefreshTimer?.cancel();
      _routeRefreshTimer = null;
      _nativeServicesReady = false;
      _identityService.suspendForLock();
      if (_bridge is SylphyMessagingBridge) {
        _bridge.clearCachesAfterAccountImport();
      }
      _profile?.photoBytes?.fillRange(0, _profile!.photoBytes!.length, 0);
      _profile = null;
      _profileLoaded = false;
      _isEditingProfile = false;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } else {
      _runGuarded(
        _restoreAfterUnlock(),
        category: 'security',
        action: 'unlock_restore_failed',
      );
    }
    setState(() {});
  }

  Future<void> _restoreAfterUnlock() async {
    final generation = _localGeneration;
    await _loadProfile();
    if (!_localDataAccessible || generation != _localGeneration) return;
    _resumePendingAccountTransfer();
    await _privacySettings.load();
    if (!_localDataAccessible || generation != _localGeneration) return;
    _identityService.resumeAfterUnlock();
    await _initializeNativeServices();
  }

  Future<void> _initializeNativeServices() async {
    await _profileLoadFuture;
    if (!_localDataAccessible) return;
    final generation = _localGeneration;
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
      if (!_localDataAccessible || generation != _localGeneration) return;
      await _configureNativePrivacy();
      // Unlock the local identity before waiting for the P2P node to attach.
      // On a cold desktop start this makes the profile usable immediately.
      if (_profile != null) {
        await _publishProfile();
      }
      await _veilidService.start();
      if (!_localDataAccessible || generation != _localGeneration) return;
      if (_profile != null && !_identityService.snapshot.hasShortInvitation) {
        await _publishProfile();
      }
    } finally {
      if (_localDataAccessible && generation == _localGeneration) {
        _nativeServicesReady = true;
      }
      if (mounted && _localDataAccessible) {
        setState(() => _nativeServicesGeneration++);
      }
    }
  }

  Future<void> _publishProfile({bool forceRefresh = false}) async {
    if (!_localDataAccessible) return;
    await _identityService.initialize(
      profile: _profile,
      shareDisplayName: _privacySettings.value.shareDisplayName,
      shareProfilePhoto: _privacySettings.value.shareProfilePhoto,
      forceRefresh: forceRefresh,
      rotationIntervalSeconds:
          _privacySettings.value.identityRotationHours * 3600,
    );
    _scheduleShortInvitationRefresh();
  }

  void _scheduleRouteRefresh(Duration delay) {
    _routeRefreshTimer ??= Timer(delay, () {
      _routeRefreshTimer = null;
      if (mounted) _onRouteChanged();
    });
  }

  void _onRouteChanged() {
    if (!_nativeServicesReady ||
        !_localDataAccessible ||
        _profile == null ||
        _routeRefreshInProgress ||
        !_veilidService.snapshot.isAttached ||
        !_veilidService.snapshot.routeNeedsPublish) {
      return;
    }
    final now = DateTime.now();
    final elapsed = _lastRouteRefresh == null
        ? const Duration(seconds: 2)
        : now.difference(_lastRouteRefresh!);
    if (elapsed < const Duration(seconds: 2)) {
      _scheduleRouteRefresh(const Duration(seconds: 2) - elapsed);
      return;
    }
    _routeRefreshTimer?.cancel();
    _routeRefreshTimer = null;
    _lastRouteRefresh = now;
    _runGuarded(
      _refreshOwnRoute(),
      category: 'identity',
      action: 'route_republish_failed',
    );
  }

  Future<void> _refreshOwnRoute() async {
    _routeRefreshInProgress = true;
    try {
      await _publishProfile(forceRefresh: true);
      await _veilidService.refresh();
    } finally {
      _routeRefreshInProgress = false;
      if (mounted &&
          _localDataAccessible &&
          _veilidService.snapshot.routeNeedsPublish) {
        _scheduleRouteRefresh(const Duration(seconds: 5));
      }
    }
  }

  void _scheduleShortInvitationRefresh() {
    if (!_localDataAccessible || _profile == null) return;
    if (_identityService.snapshot.hasShortInvitation) {
      _identityRepublishTimer?.cancel();
      _identityRepublishTimer = null;
      _identityRetrySeconds = 6;
      return;
    }
    if (!mounted ||
        _identityRetryInProgress ||
        widget.nativeCore == null && widget.identityService == null) {
      return;
    }
    final foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _identityRepublishTimer ??= Timer(
      Duration(seconds: foreground ? _identityRetrySeconds : 60),
      () async {
        // Keep the timer assigned until completion to coalesce refreshes.
        _identityRetryInProgress = true;
        try {
          if (mounted && _veilidService.snapshot.isAttached) {
            await _publishProfile();
          }
        } on Object catch (error) {
          AppLog.instance.recordError(
            category: 'identity',
            action: 'short_invitation_refresh_failed',
            error: error,
          );
        } finally {
          _identityRetryInProgress = false;
          _identityRepublishTimer = null;
          _identityRetrySeconds = (_identityRetrySeconds * 2).clamp(6, 60);
          if (mounted) _scheduleShortInvitationRefresh();
        }
      },
    );
  }

  void _onPrivacyChanged() {
    if (mounted) setState(() {});
    if (!_nativeServicesReady || !_localDataAccessible) {
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
    final generation = _localGeneration;
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
    if (!mounted || generation != _localGeneration || !_localDataAccessible) {
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
    if (!mounted || !_localDataAccessible) return;
    _localGeneration++;
    if (_bridge is SylphyMessagingBridge) {
      _bridge.clearCachesAfterAccountImport();
    }
    _identityService.invalidateAfterAccountImport();
    setState(() {
      _profile = profile;
      _profileLoaded = true;
      _isEditingProfile = false;
      _nativeServicesGeneration++;
    });
    _runGuarded(
      _resumeNativeServices(),
      category: 'account',
      action: 'import_resume_failed',
    );
  }

  void _resumePendingAccountTransfer() {
    if (!mounted ||
        !_localDataAccessible ||
        !_accountTransferRecovery.hasDocument ||
        _transferRecoveryScheduled) {
      return;
    }
    _transferRecoveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _transferRecoveryScheduled = false;
      if (!mounted || !_localDataAccessible) {
        return;
      }
      if (_navigatorKey.currentState == null) {
        _resumePendingAccountTransfer();
        return;
      }
      final document = _accountTransferRecovery.take();
      if (document != null) _useExistingAccount(initialDocument: document);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _useExistingAccount({Uint8List? initialDocument}) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !_localDataAccessible) return;
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/account-transfer'),
          builder: (_) => AccountTransferPage(
            mode: AccountTransferMode.receive,
            veilidService: _veilidService,
            nativeCore: widget.nativeCore,
            profileStore: _profileStore,
            initialDocument: initialDocument,
            replaceExisting: _profile != null,
            onAccountImported: _accountImported,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _accountTransferRecovery.removeListener(_resumePendingAccountTransfer);
    _accountTransferRecovery.dispose();
    _appSecurity?.removeListener(_onSecurityChanged);
    _localGeneration++;
    if (_bridge is SylphyMessagingBridge) {
      _bridge.clearCachesAfterAccountImport();
    }
    _profile?.photoBytes?.fillRange(0, _profile!.photoBytes!.length, 0);
    _profile = null;
    final core = widget.nativeCore;
    if (core is NativeCoreClient) core.disposeActivityEvents();
    unawaited(_appSecurity?.close());
    if (widget.appSecurity == null) _appSecurity?.dispose();
    widget.updates?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _privacySettings.removeListener(_onPrivacyChanged);
    _veilidService.removeListener(_onRouteChanged);
    _routeRefreshTimer?.cancel();
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
  Future<AppExitResponse> didRequestAppExit() async {
    _accountTransferRecovery.clear();
    await _appSecurity?.close();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.instance.record(
      category: 'lifecycle',
      action: 'state_changed',
      result: state.name,
      verbose: true,
    );
    final foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.detached) {
      _accountTransferRecovery.clear();
      unawaited(_appSecurity?.close());
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _appSecurity?.backgrounded();
    }
    _veilidService.setForeground(foreground);
    _identityRepublishTimer?.cancel();
    _identityRepublishTimer = null;
    if (foreground) _identityRetrySeconds = 6;
    if (_profile != null) _scheduleShortInvitationRefresh();
    if (foreground) {
      _runGuarded(
        _checkSecurityAndResume(),
        category: 'lifecycle',
        action: 'resume_failed',
      );
    }
  }

  Future<void> _checkSecurityAndResume() async {
    await _appSecurity?.resumed();
    if (_localDataAccessible) await _resumeNativeServices();
  }

  Future<void> _resumeNativeServices() async {
    if (!_localDataAccessible) return;
    await _veilidService.refresh();
    if (_veilidService.snapshot.phase == VeilidPhase.offline ||
        _veilidService.snapshot.phase == VeilidPhase.error) {
      await _veilidService.start();
    }
    if (_profile != null) {
      await _publishProfile(
        forceRefresh: _veilidService.snapshot.routeNeedsPublish,
      );
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
        final contents = MediaQuery(
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
        return AccountTransferRecoveryScope(
          recovery: _accountTransferRecovery,
          child: _appSecurity == null
              ? contents
              : AppSecurityHost(controller: _appSecurity, child: contents),
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
              onUseExistingAccount: _isEditingProfile
                  ? null
                  : _useExistingAccount,
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
