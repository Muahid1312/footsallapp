import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../../core/widgets/common.dart';
import '../data/photo_store.dart';

class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({super.key, required this.file, required this.store});
  final File file;
  final PhotoStore store;
  @override
  State<PhotoCropScreen> createState() => _PhotoCropState();
}

class _PhotoCropState extends State<PhotoCropScreen> {
  ui.Image? _image;
  String? _error;
  double _zoom = 1, _x = .5, _y = .5;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final image = await SafePhoto.read(widget.file);
      if (mounted) {
        setState(() => _image = image);
      } else {
        image.dispose();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'This image could not be opened. Choose a different photo.',
        );
      }
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final path = await widget.store.saveCrop(
        _image!,
        SafePhoto.crop(_image!, zoom: _zoom, x: _x, y: _y),
      );
      if (mounted) {
        Navigator.pop(context, path);
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Adjust player photo')),
      body: Content(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Keep the face inside the square. Photos are resized and saved privately on this device.',
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Text(_error!)
            else if (_image == null)
              const Center(child: CircularProgressIndicator())
            else ...[
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: CustomPaint(
                    painter: _CropPainter(
                      _image!,
                      SafePhoto.crop(_image!, zoom: _zoom, x: _x, y: _y),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Zoom'),
              Slider(
                value: _zoom,
                min: 1,
                max: 3,
                onChanged: _busy ? null : (v) => setState(() => _zoom = v),
              ),
              const Text('Horizontal position'),
              Slider(
                value: _x,
                onChanged: _busy ? null : (v) => setState(() => _x = v),
              ),
              const Text('Vertical position'),
              Slider(
                value: _y,
                onChanged: _busy ? null : (v) => setState(() => _y = v),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(_busy ? 'Saving photo…' : 'Use this photo'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.source);
  final ui.Image image;
  final Rect source;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawImageRect(
    image,
    source,
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.high,
  );
  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.source != source;
}
