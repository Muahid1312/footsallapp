import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/database/schema.dart';
import 'package:saturday_futsal/core/database/schema_v2.dart';
import 'package:saturday_futsal/core/database/schema_v3.dart';
import 'package:saturday_futsal/features/statistics/data/statistics_repository.dart';

class V3FixtureDatabase extends GeneratedDatabase {
  V3FixtureDatabase(super.executor);
  @override
  int get schemaVersion => 3;
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
      ]) {
        await customStatement(sql);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys=ON');
    },
  );
}

void main() {
  test(
    'v3 to v4 preserves profiles, events, teams, competition champion, and persisted award after reopening',
    () async {
      final root = await Directory.systemTemp.createTemp('phase4-migrate-');
      final file = File('${root.path}/app.sqlite');
      final old = V3FixtureDatabase(NativeDatabase(file));
      for (final p in ['a', 'b']) {
        await old
            .customStatement('INSERT INTO players VALUES (?,?,?,?,?,?,?,?,?)', [
              p,
              'Old $p',
              '/permanent/$p.jpg',
              p == 'a' ? 'Goalkeeper' : 'Pivot',
              null,
              p == 'a' ? 7 : 5,
              0,
              0,
              0,
            ]);
      }
      await old.customStatement(
        "INSERT INTO sessions VALUES ('s',0,'Old court',600,'round_robin','planned',0)",
      );
      for (final p in ['a', 'b']) {
        await old.customStatement(
          'INSERT INTO session_attendance VALUES (?,?,?,?)',
          ['attendance-$p', 's', p, 'available'],
        );
        await old.customStatement(
          'INSERT INTO session_teams VALUES (?,?,?,?,?,?)',
          ['t$p', 's', 'Team $p', 4294967295, null, 0],
        );
        await old.customStatement(
          'INSERT INTO team_memberships VALUES (?,?,?,?,?)',
          ['member-$p', 't$p', 's', p, 0],
        );
      }
      const rotation =
          '{"playing":["ta","tb"],"queue":[],"entered":{"ta":0,"tb":0},"awaiting":null}';
      await old.customStatement(
        "INSERT INTO competitions VALUES ('c','s','round_robin','draft',600,3,1,0,1,'both_rotate','points',1,?,0)",
        [rotation],
      );
      for (var i = 0; i < 2; i++) {
        await old.customStatement(
          'INSERT INTO competition_teams VALUES (?,?,?,?)',
          ['c', 's', i == 0 ? 'ta' : 'tb', i],
        );
      }
      await old.customStatement(
        "INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase) VALUES ('m','s','ta','tb',600,'scheduled','scheduled')",
      );
      await old.customStatement(
        "INSERT INTO match_timer_state(match_id) VALUES ('m')",
      );
      await old.customStatement(
        "INSERT INTO competition_fixtures VALUES ('f','c','m','ta','tb',1,1,1,'league','pending',1,'1:ta|tb')",
      );
      await old.customStatement(
        "UPDATE competitions SET status='active' WHERE id='c'",
      );
      await old.customStatement(
        "UPDATE matches SET phase='live',status='live',started_at=0 WHERE id='m'",
      );
      for (final p in ['a', 'b']) {
        await old.customStatement(
          'INSERT INTO match_lineup_stints VALUES (?,?,?,?,?,?)',
          ['stint-$p', 'm', 't$p', p, 0, null],
        );
      }
      await old.customStatement(
        "INSERT INTO match_events VALUES ('goal','m','ta','a',NULL,'goal',1,1000,1000)",
      );
      await old.customStatement(
        'UPDATE match_lineup_stints SET left_millis=10000',
      );
      await old.customStatement(
        "UPDATE match_timer_state SET accumulated_millis=10000 WHERE match_id='m'",
      );
      await old.customStatement(
        "UPDATE matches SET phase='finished',status='completed',ended_at=10000 WHERE id='m'",
      );
      await old.customStatement(
        "UPDATE competition_fixtures SET status='finished' WHERE id='f'",
      );
      await old.customStatement(
        "INSERT INTO competition_applications VALUES ('m',0,'c','f',?,?,0,10000)",
        [rotation, rotation],
      );
      await old.customStatement(
        "INSERT INTO champion_decisions VALUES ('c','ta','standings','[\"ta\"]','Recorded result',0,'[]',10000)",
      );
      await old.customStatement(
        "UPDATE competitions SET status='completed' WHERE id='c'",
      );
      await old.customStatement(
        "UPDATE sessions SET status='completed' WHERE id='s'",
      );
      await old.close();
      var db = AppDatabase.file(file);
      try {
        var stats = StatisticsRepository(db);
        final p = (await db.player('a'))!;
        expect(p.name, 'Old a');
        expect(p.photoPath, '/permanent/a.jpg');
        expect(p.skillRating, 7);
        expect(p.goalkeeperEligible, isTrue);
        expect(p.secondaryPosition, isNull);
        expect((await stats.load()).career('a').goals, 1);
        expect((await stats.load()).career('a').wins, 1);
        expect(
          (await db.rows(
            "SELECT champion_team_id FROM champion_decisions WHERE competition_id='c'",
          )).single['champion_team_id'],
          'ta',
        );
        expect(
          (await db.rows(
            "SELECT player_id FROM team_memberships WHERE team_id='ta'",
          )).single['player_id'],
          'a',
        );
        expect((await stats.ratingHistory('a')).length, 1);
        await db.savePlayer(
          id: 'a',
          name: p.name,
          photoPath: p.photoPath,
          position: p.preferredPosition,
          skillRating: 8,
          goalkeeperEligible: true,
        );
        await stats.confirmMvp('s', playerId: 'a', requestId: 'award');
        await db.close();
        db = AppDatabase.file(file);
        stats = StatisticsRepository(db);
        expect((await stats.mvp('s')).decisions.single['player_id'], 'a');
        expect((await stats.ratingHistory('a')).length, 2);
        expect((await stats.load()).career('a').goals, 1);
        expect((await db.rows('PRAGMA user_version')).single.values.single, 5);
        expect(await db.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
