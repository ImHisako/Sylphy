import 'package:flutter/material.dart';

/// Shared palette for the existing custom-painted messenger surfaces.
class AppPalette {
  static String themeName = 'sylphy';
  static bool get isLight => themeName == 'white';
  static Color get primary => switch (themeName) {
    'cyan' => const Color(0xFF72DCFF),
    'pink' => const Color(0xFFFFA6D8),
    'white' => const Color(0xFF496A08),
    _ => const Color(0xFFCFF36A),
  };

  static Color color(int value) {
    final original = Color(value);
    if (value == 0xFFCFF36A) return primary;
    final r = (value >> 16) & 255;
    final g = (value >> 8) & 255;
    final b = value & 255;
    final high = [r, g, b].reduce((a, b) => a > b ? a : b);
    final low = [r, g, b].reduce((a, b) => a < b ? a : b);
    final neutral = high - low < 45;
    if (neutral && isLight) {
      final shade = 255 - ((r + g + b) ~/ 3);
      return Color.fromARGB(255, shade, shade, shade);
    }
    if (isLight && high > 140) {
      // Status/link accents also need contrast against light surfaces.
      // Contact avatars and images do not pass through this palette.
      final hsl = HSLColor.fromColor(original);
      return hsl.withLightness(hsl.lightness.clamp(0.0, 0.32)).toColor();
    }
    if (neutral && high < 45 && themeName == 'amoled') return Colors.black;
    if (neutral && high < 45 && themeName == 'black') {
      final shade = (r + g + b) ~/ 3;
      return Color.fromARGB(255, shade, shade, shade);
    }
    return original;
  }
}
