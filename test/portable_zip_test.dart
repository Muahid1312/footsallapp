import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/features/backup/data/portable_zip.dart';

void main() {
  late Directory root;
  late File zip;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('zip-test-');
    zip = File('${root.path}/backup.zip');
    final db = await File(
          '${root.path}/database.sqlite',
        ).writeAsString('snapshot'),
        manifest = await File('${root.path}/manifest.json').writeAsString('{}');
    await PortableZip.create(zip, {
      'database.sqlite': db,
      'manifest.json': manifest,
    });
  });
  tearDown(() async => root.delete(recursive: true));
  test('streamed portable ZIP round trips its exact files and bytes', () async {
    final out = Directory('${root.path}/out'),
        names = await PortableZip.extract(zip, out);
    expect(names.toSet(), {'database.sqlite', 'manifest.json'});
    expect(
      await File('${out.path}/database.sqlite').readAsString(),
      'snapshot',
    );
  });
  test(
    'corrupt file data is rejected with no partial staging retained',
    () async {
      final bytes = await zip.readAsBytes(), pattern = utf8.encode('snapshot');
      var offset = -1;
      for (var i = 0; i <= bytes.length - pattern.length; i++) {
        if (List.generate(
          pattern.length,
          (j) => bytes[i + j] == pattern[j],
        ).every((v) => v)) {
          offset = i;
          break;
        }
      }
      expect(offset, greaterThanOrEqualTo(0));
      bytes[offset] ^= 1;
      await zip.writeAsBytes(bytes);
      final out = Directory('${root.path}/out');
      await expectLater(PortableZip.extract(zip, out), throwsFormatException);
      expect(await out.exists(), isFalse);
    },
  );
  test('path traversal names are rejected before extraction', () async {
    final bytes = await zip.readAsBytes(),
        before = utf8.encode('database.sqlite'),
        after = utf8.encode('../outside.data');
    for (var i = 0; i <= bytes.length - before.length; i++) {
      if (List.generate(
        before.length,
        (j) => bytes[i + j] == before[j],
      ).every((v) => v)) {
        bytes.setRange(i, i + after.length, after);
      }
    }
    await zip.writeAsBytes(bytes);
    await expectLater(
      PortableZip.extract(zip, Directory('${root.path}/out')),
      throwsFormatException,
    );
    expect(await File('${root.path}/outside.data').exists(), isFalse);
  });
  test(
    'compressed entries outside the app backup format are rejected',
    () async {
      final bytes = await zip.readAsBytes(), data = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length - 46; i++) {
        if (data.getUint32(i, Endian.little) == 0x02014b50) {
          data.setUint16(i + 10, 8, Endian.little);
          break;
        }
      }
      await zip.writeAsBytes(bytes);
      await expectLater(
        PortableZip.extract(zip, Directory('${root.path}/out')),
        throwsFormatException,
      );
    },
  );
  test(
    'oversized declared files are rejected without allocating their declared size',
    () async {
      final bytes = await zip.readAsBytes(), data = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length - 46; i++) {
        if (data.getUint32(i, Endian.little) == 0x02014b50) {
          data.setUint32(i + 20, PortableZip.maxFile + 1, Endian.little);
          data.setUint32(i + 24, PortableZip.maxFile + 1, Endian.little);
          break;
        }
      }
      await zip.writeAsBytes(bytes);
      await expectLater(
        PortableZip.extract(zip, Directory('${root.path}/out')),
        throwsFormatException,
      );
    },
  );
  test(
    'symbolic-link entries cannot create or redirect restored assets',
    () async {
      final bytes = await zip.readAsBytes(), data = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length - 46; i++) {
        if (data.getUint32(i, Endian.little) == 0x02014b50) {
          data.setUint16(i + 4, 0x0314, Endian.little);
          data.setUint32(i + 38, 0xa1ff0000, Endian.little);
          break;
        }
      }
      await zip.writeAsBytes(bytes);
      await expectLater(
        PortableZip.extract(zip, Directory('${root.path}/out')),
        throwsFormatException,
      );
      expect(await Directory('${root.path}/out').exists(), isFalse);
    },
  );
}
