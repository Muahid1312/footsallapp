import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';
import '../../../core/storage/app_storage.dart';
import '../../players/data/photo_store.dart';
import 'backup_database.dart';
import 'portable_zip.dart';

Future<String> _digest(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();
Future<void> _zipJob(Map<String, String> input) =>
    PortableZip.create(File(input['output']!), {
      for (final e in input.entries.where((e) => e.key != 'output'))
        e.key: File(e.value),
    });
Future<List<String>> _unzipJob(List<String> input) =>
    PortableZip.extract(File(input[0]), Directory(input[1]));

class PreparedRestore {
  PreparedRestore(this.root, this.manifest, this.seal);
  final Directory root;
  final Map<String, dynamic> manifest;
  final Map<String, String> seal;
}

class BackupService {
  BackupService(this.storage);
  final AppStorage storage;
  Future<File> create(AppDatabase db) async {
    final work = await Directory(
      p.join(storage.documents.path, 'backup_work', const Uuid().v4()),
    ).create(recursive: true);
    final snapshot = File(p.join(work.path, 'database.sqlite'));
    try {
      // SQLite obtains a consistent snapshot, including committed WAL pages.
      // VACUUM INTO must run outside a transaction and is serialized by Drift.
      await db.customStatement('VACUUM INTO ?', [snapshot.path]);
      BackupDatabase.validate(snapshot, db.schemaVersion);
      final copy = AppDatabase.file(snapshot),
          files = <String, File>{'database.sqlite': snapshot},
          missing = <String>[];
      try {
        final active = await storage.active(),
            players = await copy.players(includeArchived: true);
        final allowed = [
          p.join(active.path, 'player_photos'),
          p.join(storage.documents.path, 'player_photos'),
          p.join(active.path, 'photos'),
        ];
        final reused = <String, String>{};
        for (final player in players) {
          if (player.photoPath == null) {
            continue;
          }
          final source = File(player.photoPath!);
          String? portable;
          if (await source.exists()) {
            final real = await source.resolveSymbolicLinks();
            if (allowed.any((root) => p.isWithin(p.normalize(root), real)) &&
                await source.length() <= 20 * 1024 * 1024) {
              portable = reused[real];
              if (portable == null) {
                final image = await SafePhoto.read(source, longest: 32);
                image.dispose();
                final ext = p.extension(real).toLowerCase();
                if (![
                  '.jpg',
                  '.jpeg',
                  '.png',
                  '.webp',
                  '.heic',
                ].contains(ext)) {
                  throw const FormatException(
                    'A stored photo has an unsupported format. Replace it before backing up.',
                  );
                }
                portable = 'photos/${const Uuid().v4()}$ext';
                final destination = File(p.join(work.path, portable));
                await destination.parent.create(recursive: true);
                await source.copy(destination.path);
                files[portable] = destination;
                reused[real] = portable;
              }
            }
          }
          if (portable == null) {
            missing.add(player.id);
          }
          await copy.customStatement(
            'UPDATE players SET photo_path=? WHERE id=?',
            [portable, player.id],
          );
        }
        await copy.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        await copy.close();
      }
      final checks = <String, Object>{};
      final manifest = <String, Object>{
        'format': 'saturday-futsal',
        'version': 1,
        'schema': db.schemaVersion,
        'app_version': '1.0.0+1',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'snapshot': 'sqlite-vacuum-into',
        'files': checks,
        'missing_photo_player_ids': missing,
      };
      final countDb = AppDatabase.file(snapshot);
      try {
        manifest['summary'] = {
          for (final table in [
            'players',
            'sessions',
            'matches',
            'competitions',
          ])
            table:
                (await countDb.rows(
                      'SELECT COUNT(*) AS n FROM $table',
                    )).single['n']
                    as int,
        };
      } finally {
        await countDb.close();
      }
      for (final e in files.entries) {
        checks[e.key] = {
          'size': await e.value.length(),
          'sha256': await _digest(e.value),
        };
      }
      final manifestFile = File(p.join(work.path, 'manifest.json'));
      await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
      files['manifest.json'] = manifestFile;
      final output = File(
        p.join(
          work.path,
          'saturday_futsal_backup_${DateTime.now().toIso8601String().substring(0, 10)}.zip',
        ),
      );
      await compute(_zipJob, {
        'output': output.path,
        for (final e in files.entries) e.key: e.value.path,
      });
      // Only the finished archive is retained for save/share/retry.
      for (final f in files.values) {
        await f.delete();
      }
      return output;
    } catch (_) {
      if (await work.exists()) {
        await work.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<PreparedRestore> prepare(File archive) async {
    final root = Directory(
      p.join(storage.documents.path, 'stores', const Uuid().v4()),
    );
    try {
      final names = await compute(_unzipJob, [archive.path, root.path]);
      final manifest =
          jsonDecode(
                await File(p.join(root.path, 'manifest.json')).readAsString(),
              )
              as Map<String, dynamic>;
      if (manifest['format'] != 'saturday-futsal' ||
          manifest['version'] != 1 ||
          manifest['schema'] is! int ||
          (manifest['schema'] as int) < 1 ||
          (manifest['schema'] as int) > 5) {
        throw const FormatException(
          'This backup version is not supported by this app.',
        );
      }
      final checks = manifest['files'] as Map<String, dynamic>;
      final created = manifest['created_at'];
      if (created is! String ||
          created.length > 40 ||
          DateTime.tryParse(created) == null) {
        throw const FormatException('Backup date is invalid.');
      }
      if (checks.length != names.length - 1 ||
          checks.keys.any((n) => n == 'manifest.json' || !names.contains(n))) {
        throw const FormatException(
          'Backup manifest does not match its files.',
        );
      }
      for (final e in checks.entries) {
        final f = File(p.join(root.path, e.key)),
            value = e.value as Map<String, dynamic>;
        if (await f.length() != value['size'] ||
            await _digest(f) != value['sha256']) {
          throw const FormatException(
            'Backup checksum verification failed. Current data has not changed.',
          );
        }
      }
      final snapshot = File(p.join(root.path, 'database.sqlite'));
      BackupDatabase.validate(snapshot, manifest['schema'] as int);
      for (final name in checks.keys.where((n) => n.startsWith('photos/'))) {
        final image = await SafePhoto.read(
          File(p.join(root.path, name)),
          longest: 32,
        );
        image.dispose();
      }
      final databaseFile = await snapshot.rename(
        p.join(root.path, 'saturday_futsal.sqlite'),
      );
      final db = AppDatabase.file(databaseFile);
      try {
        await db.rows(
          'SELECT 1',
        ); // Migrate the isolated copy before activation.
        await db.transaction(() async {
          for (final player in await db.players(includeArchived: true)) {
            final photo = player.photoPath;
            if (photo == null) {
              continue;
            }
            if (!photo.startsWith('photos/') ||
                !PortableZip.validName(photo) ||
                !checks.containsKey(photo)) {
              throw const FormatException(
                'A player photo reference is unsafe or missing.',
              );
            }
            await db.customStatement(
              'UPDATE players SET photo_path=? WHERE id=?',
              [p.join(root.path, photo), player.id],
            );
          }
          if ((await db.rows('PRAGMA foreign_key_check')).isNotEmpty ||
              (await db.rows(
                'PRAGMA integrity_check',
              )).any((r) => r.values.single != 'ok')) {
            throw const FormatException(
              'Restored database did not pass integrity checks.',
            );
          }
          manifest['paused_live_matches'] = await pauseForRecovery(db);
          if ((await db.rows(
                'SELECT id FROM app_settings WHERE id=1',
              )).length !=
              1) {
            throw const FormatException('Backup settings are missing.');
          }
          manifest['summary'] = {
            for (final table in [
              'players',
              'sessions',
              'matches',
              'competitions',
            ])
              table:
                  (await db.rows(
                        'SELECT COUNT(*) AS n FROM $table',
                      )).single['n']
                      as int,
          };
        });
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        await db.close();
      }
      final seal = <String, String>{
        databaseFile.path: await _digest(databaseFile),
      };
      for (final name in checks.keys.where((n) => n.startsWith('photos/'))) {
        final f = File(p.join(root.path, name));
        seal[f.path] = await _digest(f);
      }
      return PreparedRestore(root, manifest, seal);
    } catch (_) {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      rethrow;
    }
  }

  static Future<int> pauseForRecovery(
    AppDatabase db,
  ) => db.transaction(() async {
    final running = await db.rows(
      "SELECT m.id,m.result_revision,t.accumulated_millis FROM matches m JOIN match_timer_state t ON t.match_id=m.id WHERE m.phase='live'",
    );
    for (final match in running) {
      await db.customStatement(
        '''UPDATE match_timer_state SET running_since_utc_millis=NULL,
        running_since_tick_millis=NULL,runtime_id=NULL,recovery_required=1 WHERE match_id=?''',
        [match['id']],
      );
      await db.customStatement(
        "UPDATE matches SET phase='paused',status='live' WHERE id=?",
        [match['id']],
      );
      await db.customStatement(
        '''INSERT INTO match_actions(id,match_id,action_type,elapsed_millis,created_at,notes,payload,result_revision)
        VALUES (?,?,'recovery',?,?,?,?,?)''',
        [
          const Uuid().v4(),
          match['id'],
          match['accumulated_millis'],
          DateTime.now().millisecondsSinceEpoch,
          'Restored from backup or previous local data. Paused at the saved checkpoint; review the timer before resuming.',
          '[]',
          match['result_revision'],
        ],
      );
    }
    return running.length;
  });

  Future<void> activate(PreparedRestore prepared, AppDatabase? current) async {
    if (!p.isWithin(
      p.join(storage.documents.path, 'stores'),
      prepared.root.path,
    )) {
      throw const FormatException('Invalid restore staging location.');
    }
    for (final e in prepared.seal.entries) {
      if (!await File(e.key).exists() ||
          await _digest(File(e.key)) != e.value) {
        throw const FormatException(
          'Validated restore files changed. Select the backup again.',
        );
      }
    }
    await current?.close();
    await storage.activate(
      prepared.root,
    ); // One atomic pointer replacement; original files stay intact.
  }

  Future<void> discard(PreparedRestore value) async {
    if ((await storage.active()).path != value.root.path &&
        await value.root.exists()) {
      await value.root.delete(recursive: true);
    }
  }
}
