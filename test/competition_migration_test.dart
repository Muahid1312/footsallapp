import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/database/schema.dart';
import 'package:saturday_futsal/core/database/schema_v2.dart';
import 'package:saturday_futsal/features/competitions/data/competition_repository.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'support/test_clock.dart';

class V2FixtureDatabase extends GeneratedDatabase {
  V2FixtureDatabase(super.executor);
  @override
  int get schemaVersion => 2;
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
    'version 2 on-disk data, final match events, and timer survive version 3 migration',
    () async {
      final root = await Directory.systemTemp.createTemp('v2-to-v3-');
      final file = File('${root.path}/app.sqlite');
      final old = V2FixtureDatabase(NativeDatabase(file));
      for (final p in ['a', 'b']) {
        await old.customStatement(
          'INSERT INTO players VALUES (?,?,?,?,?,?,?,?,?)',
          [p, p, null, 'Pivot', null, 5, 0, 0, 0],
        );
      }
      await old.customStatement(
        "INSERT INTO sessions VALUES ('s',0,'Court',600,'round_robin','planned',0)",
      );
      for (final p in ['a', 'b']) {
        await old.customStatement(
          'INSERT INTO session_attendance VALUES (?,?,?,?)',
          ['attendance-$p', 's', p, 'available'],
        );
        await old.customStatement(
          'INSERT INTO session_teams VALUES (?,?,?,?,?,?)',
          ['team-$p', 's', p, 4294967295, null, 0],
        );
        await old.customStatement(
          'INSERT INTO team_memberships VALUES (?,?,?,?,?)',
          ['member-$p', 'team-$p', 's', p, 0],
        );
      }
      await old.customStatement(
        "INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase,started_at) VALUES ('old-match','s','team-a','team-b',600,'live','live',0)",
      );
      await old.customStatement(
        "INSERT INTO match_timer_state(match_id,accumulated_millis) VALUES ('old-match',1000)",
      );
      for (final p in ['a', 'b']) {
        await old.customStatement(
          'INSERT INTO match_lineup_stints VALUES (?,?,?,?,?,?)',
          ['stint-$p', 'old-match', 'team-$p', p, 0, null],
        );
      }
      await old.customStatement(
        "INSERT INTO match_events VALUES ('goal','old-match','team-a','a',NULL,'goal',1,1000,1000)",
      );
      await old.customStatement(
        "INSERT INTO match_actions VALUES ('record','old-match','record','goal',NULL,1000,1000,NULL,'[]')",
      );
      await old.customStatement(
        'UPDATE match_lineup_stints SET left_millis=1000',
      );
      await old.customStatement(
        "UPDATE matches SET phase='finished',status='completed',ended_at=1000 WHERE id='old-match'",
      );
      await old.customStatement(
        "INSERT INTO match_actions VALUES ('finish','old-match','finish',NULL,NULL,1000,1000,NULL,'[]')",
      );
      await old.close();
      final db = AppDatabase.file(file);
      try {
        final clock = TestMatchClock();
        final m = (await MatchRepository(db, clock).load('old-match'))!;
        expect(m.match.phase, 'finished');
        expect(m.score('team-a'), 1);
        expect(m.timer.accumulatedMillis, 1000);
        expect(m.events.single.id, 'goal');
        final repo = CompetitionRepository(db, clock);
        final id = await repo.create(
          sessionId: 's',
          teamIds: ['team-a', 'team-b'],
          mode: 'round_robin',
          durationSeconds: 600,
          requestId: 'new-competition',
        );
        await repo.activate(id, requestId: 'generate');
        expect((await repo.required(id)).fixtures.length, 1);
        expect((await db.rows('SELECT * FROM matches')).length, 2);
        expect((await db.rows('PRAGMA user_version')).single.values.single, 5);
        expect(await db.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
