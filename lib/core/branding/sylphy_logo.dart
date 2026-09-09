import 'package:flutter/material.dart';

class SylphyLogo extends StatelessWidget {
  const SylphyLogo({
    super.key,
    this.size = 48,
    this.excludeFromSemantics = false,
  });

  final double size;
  final bool excludeFromSemantics;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/sylphy-elf.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
    semanticLabel: 'Logo Sylphy',
    excludeFromSemantics: excludeFromSemantics,
  );
}
