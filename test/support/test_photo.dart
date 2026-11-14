import 'dart:io';
import 'dart:ui' as ui;

Future<File> testPhoto(
  File destination, {
  int width = 80,
  int height = 120,
}) async {
  final recorder = ui.PictureRecorder(), canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF497B5C),
  );
  canvas.drawCircle(
    ui.Offset(width / 2, height / 3),
    width / 4,
    ui.Paint()..color = const ui.Color(0xFFE5C699),
  );
  final picture = recorder.endRecording(),
      image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    await destination.parent.create(recursive: true);
    return await destination.writeAsBytes(bytes, flush: true);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
