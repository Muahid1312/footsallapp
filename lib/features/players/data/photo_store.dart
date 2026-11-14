import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../../core/storage/device_files.dart';

class SafePhoto {
  static Future<ui.Image> read(File file, {int longest = 1600}) async {
    if (!await file.exists() || await file.length() > 20 * 1024 * 1024) {
      throw const FormatException('Photo is missing or larger than 20 MB.');
    }
    return decode(await file.readAsBytes(), longest: longest);
  }

  static Future<ui.Image> decode(Uint8List bytes, {int longest = 1600}) async {
    if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
      throw const FormatException('Invalid photo size.');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width > 16000 ||
          descriptor.height > 16000 ||
          descriptor.width * descriptor.height > 16000000) {
        throw const FormatException(
          'Photo dimensions exceed the supported limit.',
        );
      }
      final scale = min(
        1.0,
        longest / max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (descriptor.width * scale).round()),
        targetHeight: max(1, (descriptor.height * scale).round()),
      );
      return (await codec.getNextFrame()).image;
    } catch (_) {
      throw const FormatException(
        'This image is unsupported or damaged. Choose a JPEG, PNG, or WebP photo.',
      );
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static ui.Rect crop(
    ui.Image image, {
    double zoom = 1,
    double x = .5,
    double y = .5,
  }) {
    final side = min(image.width, image.height) / zoom.clamp(1, 3);
    return ui.Rect.fromLTWH(
      (image.width - side) * x.clamp(0, 1),
      (image.height - side) * y.clamp(0, 1),
      side,
      side,
    );
  }
}

class PhotoStore {
  PhotoStore({Future<Directory> Function()? root})
    : _root = root ?? getApplicationDocumentsDirectory;
  final Future<Directory> Function() _root;
  final _picker = ImagePicker();
  Future<XFile?> select({ImageSource source = ImageSource.gallery}) =>
      _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 88,
      );
  Future<String?> pick() async {
    final selected = await select();
    return selected == null ? null : store(selected);
  }

  Future<String> store(XFile selected) async {
    final image = await SafePhoto.read(File(selected.path));
    try {
      return await saveCrop(image, SafePhoto.crop(image));
    } finally {
      image.dispose();
    }
  }

  Future<String> saveCrop(ui.Image image, ui.Rect source) async {
    if (source.width <= 0 ||
        source.height <= 0 ||
        source.left < 0 ||
        source.top < 0 ||
        source.right > image.width + .001 ||
        source.bottom > image.height + .001) {
      throw const FormatException('Invalid photo crop.');
    }
    final recorder = ui.PictureRecorder(), canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      source,
      const ui.Rect.fromLTWH(0, 0, 1000, 1000),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(1000, 1000);
    picture.dispose();
    Uint8List bytes;
    try {
      bytes = (await cropped.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      cropped.dispose();
    }
    final extension = Platform.isAndroid ? 'jpg' : 'png';
    if (Platform.isAndroid) {
      bytes = await DeviceFiles().jpeg(bytes);
    }
    final directory = await Directory(
      path.join((await _root()).path, 'player_photos'),
    ).create(recursive: true);
    final file = File(
      path.join(directory.path, '${const Uuid().v4()}.$extension'),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<String?> recoverLostPhoto() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final response = await _picker.retrieveLostData();
    if (response.isEmpty) {
      return null;
    }
    if (response.exception != null) {
      throw response.exception!;
    }
    final files = response.files;
    return files == null || files.isEmpty ? null : store(files.first);
  }
}
