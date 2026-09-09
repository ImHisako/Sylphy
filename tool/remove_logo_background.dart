// Removes the mint backdrop from the original generated Sylphy artwork.
// Run from the repository root: dart run tool/remove_logo_background.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

void main() {
  final source = img.decodePng(
    File('assets/branding/sylphy-elf-source.png').readAsBytesSync(),
  )!;
  final width = source.width;
  final height = source.height;
  final background = List<bool>.filled(width * height, false);
  // The mint backdrop is distinct from the warm white hair and darker clothes.
  for (final p in source) {
    background[p.y * width + p.x] =
        p.g > p.r + 7 && p.g > p.b + 4 && p.r > 165 && p.b > 175;
  }
  final result = img.Image(width: width, height: height, numChannels: 4);
  var transparentPixels = 0;
  for (final p in source) {
    if (background[p.y * width + p.x]) {
      transparentPixels++;
      continue;
    }
    // Recover the alpha and remove mint spill on the antialiased silhouette.
    img.Pixel? backdrop;
    img.Pixel? foreground;
    var farthestColor = 0.0;
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final x = p.x + dx;
        final y = p.y + dy;
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        if (background[y * width + x]) backdrop = source.getPixel(x, y);
      }
    }
    if (backdrop != null) {
      for (var dy = -3; dy <= 3; dy++) {
        for (var dx = -3; dx <= 3; dx++) {
          final x = p.x + dx;
          final y = p.y + dy;
          if (x < 0 || y < 0 || x >= width || y >= height) continue;
          if (background[y * width + x]) continue;
          final candidate = source.getPixel(x, y);
          final distance = _distance(candidate, backdrop);
          if (distance > farthestColor) {
            farthestColor = distance;
            foreground = candidate;
          }
        }
      }
    }
    if (backdrop != null && foreground != null && farthestColor > 100) {
      final br = backdrop.r.toDouble();
      final bg = backdrop.g.toDouble();
      final bb = backdrop.b.toDouble();
      final fr = foreground.r - br;
      final fg = foreground.g - bg;
      final fb = foreground.b - bb;
      final alpha =
          (((p.r - br) * fr + (p.g - bg) * fg + (p.b - bb) * fb) /
                  farthestColor)
              .clamp(0.0, 1.0);
      if (alpha < 0.05) {
        transparentPixels++;
        continue;
      }
      int unmatte(num value, double background) =>
          ((value - (1 - alpha) * background) / alpha).round().clamp(0, 255);
      result.setPixelRgba(
        p.x,
        p.y,
        unmatte(p.r, br),
        unmatte(p.g, bg),
        unmatte(p.b, bb),
        (alpha * 255).round(),
      );
    } else {
      result.setPixelRgba(p.x, p.y, p.r, p.g, p.b, 255);
    }
  }
  File(
    'assets/branding/sylphy-elf.png',
  ).writeAsBytesSync(img.encodePng(result));
  stdout.writeln(
    'Exported RGBA mascot: $transparentPixels transparent pixels.',
  );
  // A review sheet makes colored fringes and accidental holes easy to see.
  final thumbnail = img.copyResize(
    result,
    width: 384,
    height: 384,
    interpolation: img.Interpolation.average,
  );
  final preview = img.Image(width: 768, height: 384, numChannels: 4);
  img.fill(preview, color: img.ColorRgba8(248, 248, 248, 255));
  img.fillRect(
    preview,
    x1: 384,
    y1: 0,
    x2: 767,
    y2: 383,
    color: img.ColorRgba8(21, 24, 30, 255),
  );
  img.compositeImage(preview, thumbnail);
  img.compositeImage(preview, thumbnail, dstX: 384);
  final review = File('build/branding/transparency-preview.png');
  review.parent.createSync(recursive: true);
  review.writeAsBytesSync(img.encodePng(preview));
}

double _distance(img.Pixel a, img.Pixel b) =>
    math.pow(a.r - b.r, 2).toDouble() +
    math.pow(a.g - b.g, 2).toDouble() +
    math.pow(a.b - b.b, 2).toDouble();
