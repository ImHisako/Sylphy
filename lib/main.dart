import 'package:flutter/material.dart';

import 'core/messaging/secure_messaging_bridge.dart';
import 'core/native/native_core.dart';
import 'features/messenger/messenger_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SylphyApp(nativeCore: NativeCoreClient.tryLoad()));
}

class SylphyApp extends StatelessWidget {
  const SylphyApp({super.key, this.bridge, this.nativeCore});

  final SecureMessagingBridge? bridge;
  final NativeCoreClient? nativeCore;

  @override
  Widget build(BuildContext context) {
    const surface = Color(0xFF111318);
    const primary = Color(0xFFD4F66A);
    const onSurface = Color(0xFFF5F6F8);
    const outline = Color(0xFF3A404A);
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
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: surface,
          foregroundColor: onSurface,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1A1E25),
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
      ),
      home: MessengerHome(
        bridge: bridge ?? LocalDemoMessagingBridge.seeded(),
        nativeCore: nativeCore,
      ),
    );
  }
}
