import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Immutable generation directories plus one atomically replaced selection file.
/// Legacy installations remain in the original documents directory until restore.
class AppStorage {
  AppStorage(this.documents);
  final Directory documents;
  File get _pointer => File(p.join(documents.path, 'active_store.json'));
  String _relative(String value) {
    if (!RegExp(r'^stores/[a-f0-9-]{36}$').hasMatch(value)) {
      throw const FormatException('Invalid local data selection.');
    }
    return value;
  }

  Future<Map<String, dynamic>?> selection() async {
    if (!await _pointer.exists()) {
      return null;
    }
    if (await _pointer.length() > 1024) {
      throw const FormatException('Invalid data selection.');
    }
    final value =
        jsonDecode(await _pointer.readAsString()) as Map<String, dynamic>;
    if (value['current'] != 'legacy') {
      _relative(value['current'] as String);
    }
    if (value['previous'] != null && value['previous'] != 'legacy') {
      _relative(value['previous'] as String);
    }
    return value;
  }

  Future<Directory> active() async {
    final s = await selection();
    if (s == null || s['current'] == 'legacy') {
      return documents;
    }
    final root = Directory(p.join(documents.path, s['current'] as String));
    if (!await File(p.join(root.path, 'saturday_futsal.sqlite')).exists()) {
      throw StateError(
        'Selected data is unavailable. Open Settings to recover the previous data.',
      );
    }
    return root;
  }

  Future<void> activate(Directory staged) async {
    final relative = _relative(p.relative(staged.path, from: documents.path));
    final previous = (await selection())?['current'] ?? 'legacy';
    await _write({'current': relative, 'previous': previous});
  }

  Future<bool> get canRecover async => (await selection())?['previous'] != null;
  Future<void> recoverPrevious() async {
    final s = await selection(), previous = s?['previous'] as String?;
    if (previous == null) {
      throw StateError('No previous data generation is available.');
    }
    final root = previous == 'legacy'
        ? documents
        : Directory(p.join(documents.path, _relative(previous)));
    if (!await File(p.join(root.path, 'saturday_futsal.sqlite')).exists()) {
      throw StateError('Previous database is missing.');
    }
    await _write({'current': previous, 'previous': s!['current']});
  }

  Future<void> _write(Map<String, dynamic> value) async {
    final temp = File('${_pointer.path}.next');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(_pointer.path);
  }
}
