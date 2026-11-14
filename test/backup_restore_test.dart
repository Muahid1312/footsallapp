import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/storage/app_storage.dart';
import 'package:saturday_futsal/features/backup/data/backup_service.dart';
import 'package:saturday_futsal/features/backup/data/backup_database.dart';
import 'package:saturday_futsal/features/backup/data/portable_zip.dart';
import 'package:saturday_futsal/features/settings/data/settings_repository.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'support/test_clock.dart';
import 'support/test_photo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late BackupService service;
  late AppStorage storage;
  late String player;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-test-');
    storage = AppStorage(root);
    service = BackupService(storage);
    db = AppDatabase.file(File('${root.path}/saturday_futsal.sqlite'));
    final photo = await testPhoto(
      File('${root.path}/player_photos/original.png'),
    );
    player = await db.savePlayer(
      name: 'Backup Player',
      position: 'Pivot',
      skillRating: 8,
      photoPath: photo.path,
      preferredFoot: 'left',
    );
    await SettingsRepository(db).save(const AppSettings(minutes: 12, win: 4));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<File> rewrite(
    File source,
    Future<void> Function(Directory) edit,
  ) async {
    final work = Directory('${root.path}/edited'),
        names = await PortableZip.extract(source, work);
    await edit(work);
    final out = File('${root.path}/modified.zip');
    await PortableZip.create(out, {
      for (final name in names) name: File(p.join(work.path, name)),
    });
    return out;
  }

  test(
    'backup includes consistent WAL snapshot, photos, ratings, settings and integrity manifest',
    () async {
      await db.rows('PRAGMA journal_mode=WAL');
      final archive = await service.create(db),
          out = Directory('${root.path}/inspection'),
          names = await PortableZip.extract(archive, out);
      final manifest =
          jsonDecode(await File('${out.path}/manifest.json').readAsString())
              as Map<String, dynamic>;
      expect(manifest['schema'], 5);
      expect(manifest['snapshot'], 'sqlite-vacuum-into');
      expect((manifest['files'] as Map).length, names.length - 1);
      expect(names.where((n) => n.startsWith('photos/')).length, 1);
      BackupDatabase.validate(File('${out.path}/database.sqlite'), 5);
      final copy = AppDatabase.file(File('${out.path}/database.sqlite'));
      try {
        expect((await copy.player(player))!.skillRating, 8);
        expect((await copy.player(player))!.photoPath, startsWith('photos/'));
        expect((await SettingsRepository(copy).load()).minutes, 12);
      } finally {
        await copy.close();
      }
    },
  );
  test(
    'validated restore selects a complete store and persists after application restart',
    () async {
      final archive = await service.create(db);
      await db.savePlayer(
        id: player,
        name: 'Later edit',
        position: 'Winger',
        skillRating: 6,
      );
      final prepared = await service.prepare(archive);
      expect((await db.player(player))!.name, 'Later edit');
      await service.activate(prepared, db);
      var restored = AppDatabase.file(
        File(
          p.join(
            (await AppStorage(root).active()).path,
            'saturday_futsal.sqlite',
          ),
        ),
      );
      try {
        final p1 = (await restored.player(player))!;
        expect(p1.name, 'Backup Player');
        expect(p1.preferredFoot, 'left');
        expect(await File(p1.photoPath!).exists(), isTrue);
        expect((await SettingsRepository(restored).load()).win, 4);
        await restored.close();
        restored = AppDatabase.file(
          File(
            p.join(
              (await AppStorage(root).active()).path,
              'saturday_futsal.sqlite',
            ),
          ),
        );
        expect((await restored.player(player))!.name, 'Backup Player');
      } finally {
        await restored.close();
      }
      expect(await storage.canRecover, isTrue);
      await storage.recoverPrevious();
      final previous = AppDatabase.file(
        File(p.join((await storage.active()).path, 'saturday_futsal.sqlite')),
      );
      try {
        expect((await previous.player(player))!.name, 'Later edit');
      } finally {
        await previous.close();
      }
    },
  );
  test(
    'a valid ZIP with an altered database fails SHA-256 and preserves current records',
    () async {
      final archive = await service.create(db),
          corrupt = await rewrite(archive, (work) async {
            final f = File('${work.path}/database.sqlite'),
                bytes = await f.readAsBytes();
            bytes[bytes.length - 1] ^= 1;
            await f.writeAsBytes(bytes);
          });
      await expectLater(service.prepare(corrupt), throwsFormatException);
      expect((await db.player(player))!.name, 'Backup Player');
      expect((await storage.active()).path, root.path);
    },
  );
  test(
    'future schema and archive versions are rejected before switching data',
    () async {
      final archive = await service.create(db),
          future = await rewrite(archive, (work) async {
            final f = File('${work.path}/manifest.json'),
                m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
            m['schema'] = 6;
            await f.writeAsString(jsonEncode(m));
          });
      await expectLater(service.prepare(future), throwsFormatException);
      expect(await File('${root.path}/active_store.json').exists(), isFalse);
      expect((await db.players()).length, 1);
    },
  );
  test(
    'corrupt archives never remove the current database or photos',
    () async {
      final archive = await File(
        '${root.path}/broken.zip',
      ).writeAsBytes([1, 2, 3]);
      await expectLater(service.prepare(archive), throwsFormatException);
      expect((await db.player(player))!.skillRating, 8);
      expect(
        await File((await db.player(player))!.photoPath!).exists(),
        isTrue,
      );
    },
  );
  test(
    'restore rejects a staged file changed after preview validation',
    () async {
      final ready = await service.prepare(await service.create(db));
      await File(
        p.join(ready.root.path, 'saturday_futsal.sqlite'),
      ).writeAsBytes([0], mode: FileMode.append);
      await expectLater(service.activate(ready, db), throwsFormatException);
      expect((await db.player(player))!.name, 'Backup Player');
      await service.discard(ready);
    },
  );
  test(
    'missing source photos are reported without fabricating image assets',
    () async {
      await File((await db.player(player))!.photoPath!).delete();
      final prepared = await service.prepare(await service.create(db));
      expect(prepared.manifest['missing_photo_player_ids'], [player]);
      final copy = AppDatabase.file(
        File(p.join(prepared.root.path, 'saturday_futsal.sqlite')),
      );
      try {
        expect((await copy.player(player))!.photoPath, isNull);
      } finally {
        await copy.close();
      }
      await service.discard(prepared);
    },
  );
  test(
    'unexpected database triggers are rejected before migrations or data changes',
    () async {
      await db.customStatement(
        "CREATE TRIGGER unexpected AFTER UPDATE ON players BEGIN DELETE FROM app_settings; END",
      );
      expect(
        () => BackupDatabase.validate(
          File('${root.path}/saturday_futsal.sqlite'),
          5,
        ),
        throwsFormatException,
      );
      expect((await SettingsRepository(db).load()).minutes, 12);
      expect((await db.players()).length, 1);
    },
  );
  test(
    'restored live matches pause at the snapshot checkpoint even in the same runtime',
    () async {
      final other = await db.savePlayer(
        name: 'Opponent',
        position: 'Winger',
        skillRating: 5,
      );
      final sid = await db.createSession(
            date: DateTime(2026, 11, 14),
            location: '',
            durationSeconds: 600,
            rotationMode: 'round_robin',
            playerIds: [player, other],
            teamCount: 2,
          ),
          teams = await db.teams(sid),
          clock = TestMatchClock(),
          engine = MatchRepository(db, clock);
      final mid = await engine.create(
        sessionId: sid,
        teamAId: teams.first.id,
        teamBId: teams.last.id,
        durationSeconds: 600,
        requestId: 'live',
      );
      await engine.start(mid, {
        for (final t in teams) t.id: t.playerIds,
      }, requestId: 'start');
      clock.advance(12345);
      await engine.checkpointRunning();
      final archive = await service.create(db);
      clock.advance(90000);
      final ready = await service.prepare(archive);
      expect((await engine.load(mid))!.match.phase, 'live');
      expect(ready.manifest['paused_live_matches'], 1);
      await service.activate(ready, db);
      final restored = AppDatabase.file(
        File(p.join((await storage.active()).path, 'saturday_futsal.sqlite')),
      );
      try {
        final reopened = await MatchRepository(restored, clock).load(mid);
        expect(reopened!.match.phase, 'paused');
        expect(reopened.timer.accumulatedMillis, 12345);
        expect(reopened.timer.recoveryRequired, isTrue);
        expect(
          (await restored.rows(
            "SELECT notes FROM match_actions WHERE match_id=? AND action_type='recovery'",
            [mid],
          )).single['notes'],
          contains('Restored from backup'),
        );
      } finally {
        await restored.close();
      }
    },
  );
}
