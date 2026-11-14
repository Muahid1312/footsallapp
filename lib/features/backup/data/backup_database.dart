import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../../../core/database/schema.dart';
import '../../../core/database/schema_v2.dart';
import '../../../core/database/schema_v3.dart';
import '../../../core/database/schema_v4.dart';
import '../../../core/database/schema_v5.dart';

/// Validate the untrusted database's complete schema before querying its views or
/// running migrations. Backups are app-specific, not arbitrary SQLite imports.
class BackupDatabase {
  static Map<String, String> _objects(Database db) => {
    for (final row in db.select(
      "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL",
    ))
      '${row['type']}:${row['name']}': (row['sql'] as String)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
  };
  static void validate(File file, int version) {
    if (version < 1 || version > 5) {
      throw const FormatException('Backup database schema is not supported.');
    }
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly),
        expected = sqlite3.openInMemory();
    try {
      db.execute('PRAGMA trusted_schema=OFF');
      if (db.select('PRAGMA user_version').single['user_version'] != version) {
        throw const FormatException(
          'Database schema version disagrees with the manifest.',
        );
      }
      for (final sql in [
        ...schemaV1,
        ...integrityTriggersV1,
        ...completedHistoryTriggersV1,
        if (version >= 2) ...[
          ...migrationV2,
          ...integrityTriggersV2,
          ...auditImmutabilityV2,
        ],
        if (version >= 3) ...[...migrationV3, ...integrityTriggersV3],
        if (version >= 4) ...[...migrationV4, ...integrityTriggersV4],
        if (version >= 5) ...migrationV5,
      ]) {
        expected.execute(sql);
      }
      final actual = _objects(db), canonical = _objects(expected);
      if (actual.length != canonical.length ||
          canonical.entries.any((e) => actual[e.key] != e.value)) {
        throw const FormatException(
          'Backup database structure is not a supported Saturday Futsal schema.',
        );
      }
      if (db.select('PRAGMA quick_check').any((r) => r.values.single != 'ok') ||
          db.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const FormatException('Backup database integrity check failed.');
      }
    } finally {
      db.dispose();
      expected.dispose();
    }
  }
}
