import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../players/data/photo_store.dart';
import '../domain/winner_poster.dart';

/// Original vector compositions, rendered at exact export dimensions offline.
/// Only one page's downsampled portraits and one output raster are retained.
class PosterRenderer {
  static void _text(
    Canvas c,
    String value,
    Rect rect,
    double font,
    Color color, {
    FontWeight weight = FontWeight.w700,
    int lines = 1,
    TextAlign align = TextAlign.center,
  }) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'sans-serif',
              fontSize: font,
              fontWeight: weight,
              maxLines: lines,
              ellipsis: '…',
              textAlign: align,
            ),
          )
          ..pushStyle(
            ui.TextStyle(color: color, letterSpacing: font > 60 ? -1 : 0),
          )
          ..addText(value);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: rect.width));
    c.drawParagraph(paragraph, rect.topLeft);
    paragraph.dispose();
  }

  static void _trophy(Canvas c, Offset center, Color color) {
    c.save();
    c.translate(center.dx, center.dy);
    final paint = Paint()..color = color;
    final cup = Path()
      ..moveTo(-35, -30)
      ..lineTo(35, -30)
      ..quadraticBezierTo(34, 21, 0, 30)
      ..quadraticBezierTo(-34, 21, -35, -30)
      ..close();
    c.drawPath(cup, paint);
    c.drawRect(const Rect.fromLTWH(-6, 26, 12, 24), paint);
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-31, 48, 62, 10),
        const Radius.circular(3),
      ),
      paint,
    );
    final handle = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7;
    c.drawArc(const Rect.fromLTWH(-56, -24, 38, 44), pi / 2, pi, false, handle);
    c.drawArc(const Rect.fromLTWH(18, -24, 38, 44), -pi / 2, pi, false, handle);
    c.restore();
  }

  static void _background(
    Canvas c,
    double h,
    PosterStyle style,
    Color team,
    bool useColor,
  ) {
    final accent = useColor ? team : const Color(0xFF32D98A);
    if (style == PosterStyle.minimalElite) {
      c.drawColor(const Color(0xFFF2F0E9), BlendMode.src);
      c.drawRect(
        Rect.fromLTWH(44, 44, 8, h - 88),
        Paint()..color = useColor ? team : const Color(0xFF14251F),
      );
      c.drawLine(
        const Offset(80, 140),
        const Offset(1000, 140),
        Paint()
          ..color = const Color(0xFFB9B8AF)
          ..strokeWidth = 2,
      );
      return;
    }
    c.drawRect(
      Rect.fromLTWH(0, 0, 1080, h),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(1080, h),
          style == PosterStyle.championsNight
              ? [
                  const Color(0xFF040914),
                  const Color(0xFF121D33),
                  const Color(0xFF060A12),
                ]
              : [
                  const Color(0xFF080D14),
                  accent.withValues(alpha: .38),
                  const Color(0xFF0B1420),
                ],
        ),
    );
    if (style == PosterStyle.championsNight) {
      for (final x in [0.0, 1080.0]) {
        c.drawCircle(
          Offset(x, 280),
          590,
          Paint()
            ..shader = ui.Gradient.radial(Offset(x, 280), 590, [
              const Color(0xFFDBBC6E).withValues(alpha: .23),
              Colors.transparent,
            ]),
        );
        final beam = Path()
          ..moveTo(x, 0)
          ..lineTo(x == 0 ? 760 : 320, h * .67)
          ..lineTo(x == 0 ? 480 : 600, h * .67)
          ..close();
        c.drawPath(
          beam,
          Paint()..color = const Color(0xFFDBBC6E).withValues(alpha: .035),
        );
      }
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(28, 28, 1024, h - 56),
          const Radius.circular(20),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFDBBC6E).withValues(alpha: .5),
      );
      for (var i = 0; i < 26; i++) {
        final x = (i * 197 % 1020 + 30).toDouble(),
            y = (i * 263 % (h.toInt() - 80) + 40).toDouble();
        c.drawCircle(
          Offset(x, y),
          i % 3 == 0 ? 3 : 1.5,
          Paint()..color = const Color(0xFFDBBC6E).withValues(alpha: .35),
        );
      }
    } else {
      final shapes = [
        Path()
          ..moveTo(680, 0)
          ..lineTo(1080, 0)
          ..lineTo(1080, h * .65)
          ..lineTo(250, h)
          ..lineTo(50, h)
          ..close(),
        Path()
          ..moveTo(0, h * .7)
          ..lineTo(1080, h * .3)
          ..lineTo(1080, h * .38)
          ..lineTo(0, h * .78)
          ..close(),
      ];
      for (var i = 0; i < shapes.length; i++) {
        c.drawPath(
          shapes[i],
          Paint()..color = accent.withValues(alpha: i == 0 ? .18 : .78),
        );
      }
      c.drawLine(
        Offset(0, h * .78),
        Offset(1080, h * .38),
        Paint()
          ..color = Colors.white.withValues(alpha: .7)
          ..strokeWidth = 3,
      );
    }
  }

  Future<Uint8List> render(
    WinnerPoster data, {
    PosterStyle style = PosterStyle.championsNight,
    bool story = false,
    bool teamColor = true,
    bool showSummary = true,
    String title = 'SATURDAY FUTSAL CHAMPIONSHIP',
    List<String>? order,
    int page = 0,
  }) async {
    if (title.trim().isEmpty || title.length > 70) {
      throw ArgumentError('Poster title must be 1–70 characters.');
    }
    final pages = data.pages(story: story, order: order);
    if (page < 0 || page >= pages.length) {
      throw ArgumentError('Choose a valid poster page.');
    }
    final h = story ? 1920.0 : 1350.0,
        recorder = ui.PictureRecorder(),
        canvas = Canvas(recorder),
        images = <ui.Image>[];
    final minimal = style == PosterStyle.minimalElite,
        ink = minimal ? const Color(0xFF14251F) : Colors.white,
        accent = style == PosterStyle.championsNight
            ? const Color(0xFFE1C47A)
            : teamColor
            ? Color(data.teamColor)
            : const Color(0xFF32D98A);
    ui.Picture? picture;
    ui.Image? output;
    try {
      _background(canvas, h, style, Color(data.teamColor), teamColor);
      _text(
        canvas,
        title.trim().toUpperCase(),
        const Rect.fromLTWH(85, 65, 910, 52),
        25,
        minimal ? ink : const Color(0xFFD8DCE4),
        weight: FontWeight.w500,
        lines: 2,
      );
      _text(
        canvas,
        DateFormat("'SATURDAY' · d MMMM yyyy").format(data.date).toUpperCase(),
        const Rect.fromLTWH(100, 125, 880, 36),
        22,
        minimal ? ink : const Color(0xFFCCD2DC),
        weight: FontWeight.w500,
      );
      _trophy(canvas, const Offset(540, 214), minimal ? ink : accent);
      _text(
        canvas,
        data.shared ? 'SHARED CHAMPIONS' : 'CHAMPIONS',
        const Rect.fromLTWH(65, 282, 950, 115),
        data.shared ? 74 : 112,
        minimal ? ink : accent,
        weight: FontWeight.w900,
      );
      _text(
        canvas,
        data.teamName,
        const Rect.fromLTWH(90, 403, 900, 92),
        46,
        ink,
        lines: 2,
      );
      final members = pages[page],
          columns = members.length <= 2 ? members.length : 3,
          rows = (members.length / columns).ceil();
      final body = Rect.fromLTWH(75, 515, 930, h - 655),
          cw = body.width / columns,
          ch = body.height / rows;
      for (var i = 0; i < members.length; i++) {
        final player = members[i], row = i ~/ columns, col = i % columns;
        final countInRow = min(columns, members.length - row * columns),
            left = body.left + (body.width - countInRow * cw) / 2 + col * cw;
        final diameter = min(
              cw - 34,
              ch - 75,
            ).clamp(50.0, columns == 1 ? 520.0 : 330.0).toDouble(),
            cx = left + cw / 2,
            top = body.top + row * ch + (ch - diameter - 75) / 2;
        final face = Rect.fromCenter(
          center: Offset(cx, top + diameter / 2),
          width: diameter,
          height: diameter,
        );
        canvas.drawCircle(
          face.center,
          diameter / 2 + 6,
          Paint()
            ..color = minimal
                ? const Color(0xFFCCCBC1)
                : accent.withValues(alpha: .8),
        );
        canvas.drawCircle(
          face.center,
          diameter / 2 + 2,
          Paint()
            ..color = minimal
                ? const Color(0xFFF2F0E9)
                : const Color(0xFF0C1422),
        );
        ui.Image? photo;
        if (player.photoPath != null) {
          try {
            photo = await SafePhoto.read(File(player.photoPath!), longest: 420);
            images.add(photo);
          } catch (_) {
            /* Honest initials fallback for missing/damaged historical assets. */
          }
        }
        canvas.save();
        canvas.clipPath(Path()..addOval(face));
        if (photo == null) {
          canvas.drawRect(
            face,
            Paint()
              ..color = minimal
                  ? const Color(0xFFE0DFD5)
                  : const Color(0xFF203149),
          );
          final initials = player.name
              .trim()
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .take(2)
              .map((s) => String.fromCharCode(s.runes.first))
              .join()
              .toUpperCase();
          _text(
            canvas,
            initials,
            Rect.fromLTWH(
              face.left,
              face.center.dy - diameter * .2,
              diameter,
              diameter * .5,
            ),
            diameter * .32,
            minimal ? ink : accent,
          );
        } else {
          canvas.drawImageRect(
            photo,
            SafePhoto.crop(photo),
            face,
            Paint()..filterQuality = FilterQuality.high,
          );
        }
        canvas.restore();
        _text(
          canvas,
          player.name,
          Rect.fromLTWH(left + 8, face.bottom + 14, cw - 16, 65),
          members.length <= 2 ? 28 : 23,
          ink,
          lines: 2,
        );
      }
      if (showSummary) {
        _text(
          canvas,
          data.summary,
          Rect.fromLTWH(80, h - 117, 920, 35),
          22,
          ink,
          weight: FontWeight.w500,
        );
      }
      _text(
        canvas,
        'SATURDAY FUTSAL  /  ${pages.length == 1 ? 'THE WINNING SQUAD' : 'SQUAD ${page + 1} OF ${pages.length}'}',
        Rect.fromLTWH(80, h - 69, 920, 30),
        18,
        minimal ? ink : const Color(0xFFCBD2DA),
        weight: FontWeight.w500,
      );
      picture = recorder.endRecording();
      output = await picture.toImage(1080, h.toInt());
      final bytes = await output.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw StateError('PNG export failed.');
      }
      return bytes.buffer.asUint8List();
    } finally {
      output?.dispose();
      picture?.dispose();
      if (picture == null && recorder.isRecording) {
        recorder.endRecording().dispose();
      }
      for (final image in images) {
        image.dispose();
      }
    }
  }
}
