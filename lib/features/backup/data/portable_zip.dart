import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// A deliberately small streaming ZIP STORE implementation for this backup format.
/// JPEG assets are already compressed. No extraction of arbitrary ZIPs, symlinks,
/// deflate streams, encrypted entries, ZIP64, or executable paths is supported.
class PortableZip {
  static const maxArchive = 512 * 1024 * 1024;
  static const maxExpanded = 256 * 1024 * 1024;
  static const maxFile = 64 * 1024 * 1024;
  static final _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var i = 0; i < 8; i++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });
  static int _crc(int crc, List<int> data) {
    var value = crc;
    for (final b in data) {
      value = _crcTable[(value ^ b) & 255] ^ (value >>> 8);
    }
    return value;
  }

  static bool validName(String name) =>
      name == 'database.sqlite' ||
      name == 'manifest.json' ||
      RegExp(
        r'^photos/[a-f0-9-]{36}\.(jpg|jpeg|png|webp|heic)$',
      ).hasMatch(name);
  static Uint8List _header(int size, Map<int, int> short, Map<int, int> long) {
    final bytes = Uint8List(size), data = ByteData.sublistView(bytes);
    short.forEach((k, v) => data.setUint16(k, v, Endian.little));
    long.forEach((k, v) => data.setUint32(k, v, Endian.little));
    return bytes;
  }

  static Future<void> create(File destination, Map<String, File> files) async {
    if (files.isEmpty ||
        files.length > 4096 ||
        files.keys.any((n) => !validName(n)) ||
        await destination.exists()) {
      throw const FormatException('Invalid backup entries or destination.');
    }
    final output = await destination.open(mode: FileMode.write);
    final directory = <({String name, int size, int crc, int offset})>[];
    var offset = 0, total = 0;
    try {
      for (final name in files.keys.toList()..sort()) {
        final file = files[name]!, size = await file.length();
        total += size;
        if (size > maxFile || total > maxExpanded) {
          throw const FormatException(
            'Backup exceeds the supported size limit.',
          );
        }
        var crc = 0xffffffff;
        await for (final chunk in file.openRead()) {
          crc = _crc(crc, chunk);
        }
        crc ^= 0xffffffff;
        final encoded = utf8.encode(name);
        directory.add((name: name, size: size, crc: crc, offset: offset));
        await output.writeFrom(
          _header(
            30,
            {4: 20, 6: 0x800, 8: 0, 12: 33, 26: encoded.length},
            {0: 0x04034b50, 14: crc, 18: size, 22: size},
          ),
        );
        await output.writeFrom(encoded);
        await for (final chunk in file.openRead()) {
          await output.writeFrom(chunk);
        }
        offset += 30 + encoded.length + size;
      }
      final centralOffset = offset;
      for (final e in directory) {
        final encoded = utf8.encode(e.name);
        await output.writeFrom(
          _header(
            46,
            {4: 20, 6: 20, 8: 0x800, 10: 0, 14: 33, 28: encoded.length},
            {0: 0x02014b50, 16: e.crc, 20: e.size, 24: e.size, 42: e.offset},
          ),
        );
        await output.writeFrom(encoded);
        offset += 46 + encoded.length;
      }
      await output.writeFrom(
        _header(
          22,
          {8: directory.length, 10: directory.length},
          {0: 0x06054b50, 12: offset - centralOffset, 16: centralOffset},
        ),
      );
      await output.flush();
    } catch (_) {
      await output.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
    await output.close();
  }

  static Future<Uint8List> _read(
    RandomAccessFile file,
    int offset,
    int count,
  ) async {
    await file.setPosition(offset);
    final bytes = await file.read(count);
    if (bytes.length != count) {
      throw const FormatException('Truncated backup archive.');
    }
    return bytes;
  }

  static Future<List<String>> extract(File archive, Directory root) async {
    final length = await archive.length();
    if (length < 22 || length > maxArchive) {
      throw const FormatException('Backup archive size is invalid.');
    }
    if (await root.exists()) {
      throw const FormatException('Restore staging directory already exists.');
    }
    await root.create(recursive: true);
    final input = await archive.open(),
        names = <String>[],
        intervals = <({int start, int end})>[];
    try {
      // Our versioned format emits no archive comment and requires a complete central directory.
      final end = ByteData.sublistView(await _read(input, length - 22, 22));
      int e16(int o) => end.getUint16(o, Endian.little);
      int e32(int o) => end.getUint32(o, Endian.little);
      if (e32(0) != 0x06054b50 ||
          e16(4) != 0 ||
          e16(6) != 0 ||
          e16(20) != 0 ||
          e16(8) != e16(10) ||
          e16(10) < 2 ||
          e16(10) > 4096 ||
          e32(16) + e32(12) != length - 22 ||
          e32(12) > 2 * 1024 * 1024) {
        throw const FormatException('Unsupported or incomplete backup ZIP.');
      }
      final central = ByteData.sublistView(
        await _read(input, e32(16), e32(12)),
      );
      var at = 0, total = 0;
      for (var i = 0; i < e16(10); i++) {
        if (at + 46 > central.lengthInBytes) {
          throw const FormatException('Invalid backup directory.');
        }
        int u16(int o) => central.getUint16(at + o, Endian.little);
        int u32(int o) => central.getUint32(at + o, Endian.little);
        final n = u16(28), size = u32(24), offset = u32(42), crc = u32(16);
        if (u32(0) != 0x02014b50 ||
            u16(6) > 20 ||
            u16(8) != 0x800 ||
            u16(10) != 0 ||
            u32(20) != size ||
            u16(30) != 0 ||
            u16(32) != 0 ||
            u16(34) != 0 ||
            ((u32(38) >>> 16) & 0xf000) == 0xa000 ||
            n < 1 ||
            n > 128 ||
            at + 46 + n > central.lengthInBytes) {
          throw const FormatException(
            'Unsupported ZIP entry. Only Saturday Futsal backups are accepted.',
          );
        }
        final name = utf8.decode(
          central.buffer.asUint8List(central.offsetInBytes + at + 46, n),
        );
        total += size;
        if (!validName(name) ||
            names.contains(name) ||
            size > maxFile ||
            total > maxExpanded ||
            (name == 'manifest.json' && size > 1024 * 1024) ||
            (name.startsWith('photos/') && size > 20 * 1024 * 1024) ||
            offset + 30 > e32(16)) {
          throw const FormatException(
            'Unsafe, duplicate, or oversized backup entry.',
          );
        }
        final local = ByteData.sublistView(await _read(input, offset, 30));
        int l16(int o) => local.getUint16(o, Endian.little);
        int l32(int o) => local.getUint32(o, Endian.little);
        if (l32(0) != 0x04034b50 ||
            l16(4) > 20 ||
            l16(6) != 0x800 ||
            l16(8) != 0 ||
            l32(14) != crc ||
            l32(18) != size ||
            l32(22) != size ||
            l16(26) != n ||
            l16(28) != 0 ||
            utf8.decode(await _read(input, offset + 30, n)) != name) {
          throw const FormatException('Backup ZIP metadata disagrees.');
        }
        final start = offset + 30 + n, finish = start + size;
        if (finish > e32(16) ||
            intervals.any((r) => offset < r.end && finish > r.start)) {
          throw const FormatException('Overlapping backup files.');
        }
        intervals.add((start: offset, end: finish));
        final destination = File(p.join(root.path, name));
        await destination.parent.create(recursive: true);
        final output = await destination.open(mode: FileMode.write);
        var remaining = size, computed = 0xffffffff;
        try {
          await input.setPosition(start);
          while (remaining > 0) {
            final chunk = await input.read(
              remaining > 65536 ? 65536 : remaining,
            );
            if (chunk.isEmpty) {
              throw const FormatException('Truncated backup file.');
            }
            computed = _crc(computed, chunk);
            await output.writeFrom(chunk);
            remaining -= chunk.length;
          }
          await output.flush();
        } finally {
          await output.close();
        }
        if ((computed ^ 0xffffffff) != crc) {
          throw const FormatException('Backup ZIP integrity check failed.');
        }
        names.add(name);
        at += 46 + n;
      }
      if (at != central.lengthInBytes ||
          !names.contains('manifest.json') ||
          !names.contains('database.sqlite')) {
        throw const FormatException(
          'Backup files are missing or inconsistent.',
        );
      }
      return names;
    } catch (_) {
      await input.close();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      rethrow;
    } finally {
      try {
        await input.close();
      } catch (_) {
        /* Already closed on failure. */
      }
    }
  }
}
