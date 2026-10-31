import 'package:flutter/material.dart';

import 'app_palette.dart';

/// A static, sparse wallpaper that leaves the content and gestures untouched.
class HalloweenBackground extends StatelessWidget {
  const HalloweenBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const ValueKey('theme-wallpaper'),
      painter: AppPalette.themeName == 'halloween'
          ? const _HalloweenPainter()
          : null,
      child: child,
    );
  }
}

class _HalloweenPainter extends CustomPainter {
  const _HalloweenPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF160F1B),
    );
    final paint = Paint()..color = const Color(0xFF48324F);
    final bat = Path()
      ..moveTo(0, -0.18)
      ..lineTo(-0.07, -0.38)
      ..lineTo(-0.14, -0.10)
      ..cubicTo(-0.30, -0.12, -0.42, -0.40, -0.50, -0.32)
      ..cubicTo(-0.47, -0.10, -0.48, 0.08, -0.32, 0.22)
      ..quadraticBezierTo(-0.31, 0.02, -0.20, 0.10)
      ..quadraticBezierTo(-0.22, 0.30, -0.08, 0.25)
      ..quadraticBezierTo(0, 0.42, 0.08, 0.25)
      ..quadraticBezierTo(0.22, 0.30, 0.20, 0.10)
      ..quadraticBezierTo(0.31, 0.02, 0.32, 0.22)
      ..cubicTo(0.48, 0.08, 0.47, -0.10, 0.50, -0.32)
      ..cubicTo(0.42, -0.40, 0.30, -0.12, 0.14, -0.10)
      ..lineTo(0.07, -0.38)
      ..close();
    final span = (size.shortestSide * 0.17).clamp(44.0, 100.0);
    for (final (x, y, scale, angle) in const [
      (0.15, 0.19, 0.75, -0.22),
      (0.81, 0.31, 1.0, 0.18),
      (0.25, 0.54, 0.8, -0.14),
      (0.83, 0.73, 0.9, 0.25),
      (0.17, 0.91, 0.65, -0.18),
    ]) {
      canvas.save();
      canvas.translate(size.width * x, size.height * y);
      canvas.rotate(angle);
      canvas.scale(span * scale);
      canvas.drawPath(bat, paint);
      canvas.restore();
    }
  }

  @override
  bool hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant _HalloweenPainter oldDelegate) => false;
}
