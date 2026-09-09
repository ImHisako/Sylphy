// Run from the repository root: dart run tool/generate_app_icons.dart
// The source artwork must already have a genuine transparent background.
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

void main() {
  final source = img.decodePng(
    File('assets/branding/sylphy-elf.png').readAsBytesSync(),
  );
  if (source == null || source.width != source.height) {
    throw StateError('The mascot must be a square PNG.');
  }
  if (source.numChannels != 4 || source.getPixel(0, 0).a != 0) {
    throw StateError('The mascot must have an actual transparent background.');
  }

  img.Image resize(int size) => img.copyResize(
    source,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );

  void write(String path, List<int> bytes) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  for (final density in {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  }.entries) {
    write(
      'android/app/src/main/res/mipmap-${density.key}/sylphy_launcher.png',
      img.encodePng(resize(density.value)),
    );
    // Android tints notification icons: use the mascot's alpha silhouette.
    final notification = resize(density.value ~/ 2);
    for (final pixel in notification) {
      pixel.r = 255;
      pixel.g = 255;
      pixel.b = 255;
    }
    write(
      'android/app/src/main/res/drawable-${density.key}/sylphy_notification.png',
      img.encodePng(notification),
    );
  }

  write('linux/runner/resources/sylphy.png', img.encodePng(resize(512)));

  // Windows supports PNG-compressed ICO frames, preserving the alpha channel.
  const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  final frames = [for (final size in sizes) img.encodePng(resize(size))];
  final directory = ByteData(6 + sizes.length * 16);
  directory.setUint16(2, 1, Endian.little);
  directory.setUint16(4, sizes.length, Endian.little);
  var offset = directory.lengthInBytes;
  for (var i = 0; i < sizes.length; i++) {
    final entry = 6 + i * 16;
    directory.setUint8(entry, sizes[i] == 256 ? 0 : sizes[i]);
    directory.setUint8(entry + 1, sizes[i] == 256 ? 0 : sizes[i]);
    directory.setUint16(entry + 4, 1, Endian.little);
    directory.setUint16(entry + 6, 32, Endian.little);
    directory.setUint32(entry + 8, frames[i].length, Endian.little);
    directory.setUint32(entry + 12, offset, Endian.little);
    offset += frames[i].length;
  }
  final ico = BytesBuilder()..add(directory.buffer.asUint8List());
  for (final frame in frames) {
    ico.add(frame);
  }
  write('windows/runner/resources/sylphy_icon.ico', ico.takeBytes());
  stdout.writeln('Generated transparent Android, Windows and Linux icons.');
}
