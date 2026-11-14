import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/database/schema.dart';
import 'package:saturday_futsal/core/database/schema_v2.dart';
import 'package:saturday_futsal/core/database/schema_v3.dart';
import 'package:saturday_futsal/core/database/schema_v4.dart';
import 'package:saturday_futsal/features/settings/data/settings_repository.dart';

class V4Fixture extends GeneratedDatabase {
  V4Fixture(super.executor);
  @override
  int get schemaVersion => 4;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in [
        ...schemaV1,
        ...integrityTriggersV1,
        ...completedHistoryTriggersV1,
        ...migrationV2,
        ...integrityTriggersV2,
        ...auditImmutabilityV2,
        ...migrationV3,
        ...integrityTriggersV3,
        ...migrationV4,
        ...integrityTriggersV4,
      ]) {
        await customStatement(sql);
      }
    },
  );
}

void main() {
  test(
    'v4 upgrades additively and settings, feet, photos and rating history survive restart',
    () async {
      final root = await Directory.systemTemp.createTemp('v5-migration-'),
          file = File('${root.path}/app.sqlite'),
          old = V4Fixture(NativeDatabase(file));
      await old.customStatement(
        "INSERT INTO players(id,name,preferred_position,skill_rating,created_at,updated_at,photo_path,secondary_position,goalkeeper_eligible) VALUES ('p','Old Player','Winger',7,0,0,'/photos/old.jpg','Pivot',1)",
      );
      await old.close();
      var db = AppDatabase.file(file);
      try {
        final p = (await db.player('p'))!;
        expect(p.photoPath, '/photos/old.jpg');
        expect(p.secondaryPosition, 'Pivot');
        expect(p.goalkeeperEligible, isTrue);
        expect(p.preferredFoot, 'unknown');
        expect(
          (await db.rows('SELECT * FROM player_rating_history')).length,
          1,
        );
        expect((await db.rows('PRAGMA user_version')).single.values.single, 5);
        await SettingsRepository(db).save(
          const AppSettings(
            minutes: 15,
            generation: 'random',
            competition: 'winner_stays',
            policy: 'manual',
            limit: 12,
          ),
        );
        await db.savePlayer(
          id: p.id,
          name: p.name,
          position: p.preferredPosition,
          photoPath: p.photoPath,
          skillRating: p.skillRating,
          preferredFoot: 'both',
        );
        await db.close();
        db = AppDatabase.file(file);
        expect((await db.player('p'))!.preferredFoot, 'both');
        expect((await SettingsRepository(db).load()).minutes, 15);
        expect((await SettingsRepository(db).load()).policy, 'manual');
        expect(
          (await db.rows('SELECT * FROM player_rating_history')).length,
          1,
        );
        expect(await db.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'settings reject invalid defaults and never alter existing session rules',
    () async {
      final db = AppDatabase.memory();
      try {
        final settings = SettingsRepository(db);
        await expectLater(
          settings.save(const AppSettings(minutes: 0)),
          throwsArgumentError,
        );
        await settings.save(
          const AppSettings(minutes: 20, generation: 'random', win: 5),
        );
        expect((await settings.load()).win, 5);
        expect(
          (await db.rows('SELECT COUNT(*) AS n FROM sessions')).single['n'],
          0,
        );
      } finally {
        await db.close();
      }
    },
  );
}
