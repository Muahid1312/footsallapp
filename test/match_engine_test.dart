import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/database/schema.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'package:saturday_futsal/features/teams/domain/team.dart';
import 'support/test_clock.dart';

// A real v1 Drift database creates an on-disk fixture, then v2 opens/migrates it.
class V1Database extends GeneratedDatabase {
  V1Database(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in [
        ...schemaV1,
        ...integrityTriggersV1,
        ...completedHistoryTriggersV1,
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
  late AppDatabase db;
  late TestMatchClock clock;
  late MatchRepository repo;
  late String sessionId, id;
  late List<SessionTeam> teams;
  setUp(() async {
    db = AppDatabase.memory();
    clock = TestMatchClock();
    repo = MatchRepository(db, clock);
    final players = <String>[];
    for (var i = 0; i < 8; i++) {
      players.add(
        await db.savePlayer(
          name: 'Player $i',
          position: 'Winger',
          skillRating: 5,
        ),
      );
    }
    sessionId = await db.createSession(
      date: DateTime(2026, 11, 14),
      location: 'Court',
      durationSeconds: 600,
      rotationMode: 'round_robin',
      playerIds: players,
      teamCount: 2,
    );
    teams = await db.teams(sessionId);
    id = await repo.create(
      sessionId: sessionId,
      teamAId: teams[0].id,
      teamBId: teams[1].id,
      durationSeconds: 600,
      requestId: 'match',
    );
  });
  tearDown(() async {
    await db.close();
  });
  Future<void> start() => repo.start(id, {
    for (final t in teams) t.id: t.playerIds.take(3).toList(),
  }, requestId: 'start');
  Future<String> goal({
    String key = 'goal',
    int side = 0,
    String? player,
    String? assist,
  }) => repo.record(
    id,
    type: 'goal',
    teamId: teams[side].id,
    playerId: player ?? teams[side].playerIds.first,
    assistId: assist,
    requestId: key,
  );

  test(
    'goal and assist derive the correct score and finalized career statistics',
    () async {
      await start();
      clock.advance(12345);
      await goal(assist: teams[0].playerIds[1]);
      final b = (await repo.load(id))!;
      expect(b.score(teams[0].id), 1);
      expect(b.score(teams[1].id), 0);
      expect(b.events.single.elapsedMillis, 12345);
      expect((await repo.career(teams[0].playerIds.first))['goals'], 0);
      await repo.finish(id, requestId: 'finish');
      expect((await repo.career(teams[0].playerIds.first))['goals'], 1);
      expect((await repo.career(teams[0].playerIds[1]))['assists'], 1);
      expect((await repo.career(teams[0].playerIds.last))['appearances'], 0);
    },
  );
  test(
    'rejects opposing team, benched scorer, and self assist without partial writes',
    () async {
      await start();
      await expectLater(
        goal(player: teams[1].playerIds.first),
        throwsArgumentError,
      );
      await expectLater(
        goal(player: teams[0].playerIds.last),
        throwsArgumentError,
      );
      await expectLater(
        goal(assist: teams[0].playerIds.first),
        throwsArgumentError,
      );
      await expectLater(
        goal(assist: teams[1].playerIds.first),
        throwsArgumentError,
      );
      expect((await repo.load(id))!.events, isEmpty);
    },
  );
  test(
    'double tap processing with the same request key records one goal',
    () async {
      await start();
      await Future.wait([goal(), goal()]);
      expect((await repo.load(id))!.score(teams[0].id), 1);
      await expectLater(
        goal(player: teams[0].playerIds[1]),
        throwsArgumentError,
      );
      expect(
        (await db.rows(
          "SELECT * FROM match_actions WHERE action_type='record'",
        )).length,
        1,
      );
    },
  );
  test(
    'undo is immutable, idempotent, and rejects a second independent undo',
    () async {
      await start();
      final event = await goal();
      await repo.undo(id, event, reason: 'Accidental goal', requestId: 'undo');
      await repo.undo(id, event, reason: 'Accidental goal', requestId: 'undo');
      expect((await repo.load(id))!.score(teams[0].id), 0);
      await expectLater(
        repo.undo(id, event, reason: 'Again', requestId: 'undo-again'),
        throwsStateError,
      );
      expect((await repo.load(id))!.events.single.isVoided, isTrue);
      await expectLater(
        db.customStatement("DELETE FROM match_actions WHERE id='undo'"),
        throwsA(isA<sqlite.SqliteException>()),
      );
    },
  );
  test(
    'correct scorer and assist then undo replacement preserves audit and totals',
    () async {
      await start();
      clock.advance(5000);
      final original = await goal();
      await repo.pause(id, requestId: 'pause');
      await repo.correctGoal(
        id,
        original,
        playerId: teams[0].playerIds[1],
        assistId: teams[0].playerIds[2],
        reason: 'Wrong scorer',
        requestId: 'fix',
      );
      var b = (await repo.load(id))!;
      expect(b.score(teams[0].id), 1);
      expect(
        b.events.where((e) => !e.isVoided).single.playerId,
        teams[0].playerIds[1],
      );
      expect(b.events.length, 2);
      await repo.undo(
        id,
        'event-fix',
        reason: 'Goal was disallowed',
        requestId: 'undo-fix',
      );
      b = (await repo.load(id))!;
      expect(b.score(teams[0].id), 0);
      await repo.finish(id, requestId: 'finish');
      expect((await repo.career(teams[0].playerIds[1]))['goals'], 0);
      expect((await repo.career(teams[0].playerIds[2]))['assists'], 0);
    },
  );
  test(
    'foul team counts are derived from active player fouls and undo',
    () async {
      await start();
      final foul = await repo.record(
        id,
        type: 'foul',
        teamId: teams[1].id,
        playerId: teams[1].playerIds.first,
        notes: 'Trip',
        requestId: 'foul',
      );
      expect((await repo.load(id))!.fouls(teams[1].id), 1);
      await repo.undo(id, foul, reason: 'Wrong player foul', requestId: 'undo');
      expect((await repo.load(id))!.fouls(teams[1].id), 0);
    },
  );
  test(
    'monotonic playing time survives pause, background intervals, and wall-clock changes',
    () async {
      await start();
      clock.advance(45000);
      await repo.checkpoint(id);
      clock.wallMillis -= 3600000;
      clock.tickMillis += 5000;
      var b = (await repo.load(id))!;
      expect(b.timer.elapsedMillis(b.match, clock), 50000);
      await repo.pause(id, requestId: 'pause');
      clock.advance(120000);
      b = (await repo.load(id))!;
      expect(b.timer.elapsedMillis(b.match, clock), 50000);
      await repo.resume(id, requestId: 'resume');
      clock.advance(20000);
      b = (await repo.load(id))!;
      expect(b.timer.elapsedMillis(b.match, clock), 70000);
    },
  );
  test(
    'new process recovers bounded timestamps paused and requires timer review',
    () async {
      await start();
      clock.advance(30000);
      await repo.checkpoint(id);
      final nextClock = TestMatchClock(
        runtimeId: 'process-b',
        wallMillis: clock.wallMillis + 20000,
      );
      final reopened = MatchRepository(db, nextClock);
      var b = (await reopened.load(id))!;
      expect(b.match.phase, 'paused');
      expect(b.timer.accumulatedMillis, 50000);
      expect(b.timer.recoveryRequired, isTrue);
      await expectLater(
        reopened.resume(id, requestId: 'resume'),
        throwsStateError,
      );
      await expectLater(
        reopened.finish(id, requestId: 'finish'),
        throwsStateError,
      );
      await reopened.reviewTimer(id, 50000, requestId: 'review');
      await reopened.resume(id, requestId: 'resume');
      nextClock.advance(10000);
      b = (await reopened.load(id))!;
      expect(b.timer.elapsedMillis(b.match, nextClock), 60000);
      expect(b.actions.where((a) => a.type == 'recovery').length, 1);
    },
  );
  test(
    'recovery handles backward clock and rejects review before recorded play',
    () async {
      await start();
      clock.advance(30000);
      await goal();
      final reopened = MatchRepository(
        db,
        TestMatchClock(runtimeId: 'b', wallMillis: clock.wallMillis - 3600000),
      );
      final b = (await reopened.load(id))!;
      expect(b.timer.accumulatedMillis, 30000);
      await expectLater(
        reopened.reviewTimer(id, 10000, requestId: 'bad-review'),
        throwsArgumentError,
      );
      await reopened.reviewTimer(id, 30000, requestId: 'review');
    },
  );
  test('a paused timer stays paused and unchanged across processes', () async {
    await start();
    clock.advance(17555);
    await repo.pause(id, requestId: 'pause');
    final reopened = MatchRepository(
      db,
      TestMatchClock(runtimeId: 'new', wallMillis: clock.wallMillis + 86400000),
    );
    final b = (await reopened.load(id))!;
    expect(b.match.phase, 'paused');
    expect(b.timer.accumulatedMillis, 17555);
    expect(b.timer.recoveryRequired, isFalse);
  });
  test(
    'only one match can run and repeated scheduling cannot duplicate a match',
    () async {
      final second = await repo.create(
        sessionId: sessionId,
        teamAId: teams[0].id,
        teamBId: teams[1].id,
        durationSeconds: 600,
        requestId: 'second',
      );
      expect(
        await repo.create(
          sessionId: sessionId,
          teamAId: teams[0].id,
          teamBId: teams[1].id,
          durationSeconds: 600,
          requestId: 'second',
        ),
        second,
      );
      await start();
      await expectLater(
        repo.start(second, {
          for (final t in teams) t.id: t.playerIds.take(3).toList(),
        }, requestId: 'second-start'),
        throwsStateError,
      );
      await repo.pause(id, requestId: 'pause');
      await repo.start(second, {
        for (final t in teams) t.id: t.playerIds.take(3).toList(),
      }, requestId: 'second-start');
      expect((await repo.load(second))!.match.phase, 'live');
    },
  );
  test(
    'expiration clamps time but does not finish, award a winner, or accept extra play',
    () async {
      await start();
      clock.advance(9999999);
      var b = (await repo.load(id))!;
      expect(b.timer.elapsedMillis(b.match, clock), 600000);
      expect(b.match.phase, 'live');
      await expectLater(goal(), throwsStateError);
      await repo.finish(id, requestId: 'finish');
      b = (await repo.load(id))!;
      expect(b.match.phase, 'finished');
      expect(b.result, 'Draw');
    },
  );
  test(
    'substitution tracks same-team participation and enforces on-field eligibility',
    () async {
      await start();
      clock.advance(20000);
      final outgoing = teams[0].playerIds.first,
          incoming = teams[0].playerIds.last;
      await expectLater(
        repo.substitute(
          id,
          teamId: teams[0].id,
          outgoingId: outgoing,
          incomingId: teams[1].playerIds.last,
          requestId: 'invalid',
        ),
        throwsArgumentError,
      );
      await repo.substitute(
        id,
        teamId: teams[0].id,
        outgoingId: outgoing,
        incomingId: incoming,
        requestId: 'sub',
      );
      await repo.substitute(
        id,
        teamId: teams[0].id,
        outgoingId: outgoing,
        incomingId: incoming,
        requestId: 'sub',
      );
      clock.advance(1000);
      await expectLater(goal(player: outgoing), throwsArgumentError);
      await goal(player: incoming);
      final b = (await repo.load(id))!;
      expect(b.onField(teams[0].id).map((p) => p.id), contains(incoming));
      expect(
        b.onField(teams[0].id).map((p) => p.id),
        isNot(contains(outgoing)),
      );
      expect(b.actions.where((a) => a.type == 'substitution').length, 1);
    },
  );
  test(
    'an observation before expiry can be confirmed after dialog entry delay',
    () async {
      await start();
      await expectLater(
        repo.record(
          id,
          type: 'goal',
          teamId: teams[0].id,
          playerId: teams[0].playerIds.first,
          occurredAtMillis: 1000,
          requestId: 'future',
        ),
        throwsArgumentError,
      );
      clock.advance(599000);
      final observed = clock.tickMillis;
      clock.advance(5000);
      await repo.record(
        id,
        type: 'goal',
        teamId: teams[0].id,
        playerId: teams[0].playerIds.first,
        occurredAtMillis: observed,
        requestId: 'pending-goal',
      );
      final b = (await repo.load(id))!;
      expect(b.events.single.elapsedMillis, 599000);
      expect(b.score(teams[0].id), 1);
      expect(b.match.phase, 'live');
      expect(b.timer.elapsedMillis(b.match, clock), 600000);
    },
  );
  test(
    'goal correction cannot assign a player who entered after the goal',
    () async {
      await start();
      clock.advance(1000);
      final event = await goal();
      clock.advance(10000);
      await repo.substitute(
        id,
        teamId: teams[0].id,
        outgoingId: teams[0].playerIds.first,
        incomingId: teams[0].playerIds.last,
        requestId: 'sub',
      );
      await expectLater(
        repo.correctGoal(
          id,
          event,
          playerId: teams[0].playerIds.last,
          reason: 'Wrong scorer',
          requestId: 'bad-fix',
        ),
        throwsArgumentError,
      );
      expect((await repo.load(id))!.score(teams[0].id), 1);
    },
  );
  test(
    'finished match rejects changes and has one finalization record',
    () async {
      await start();
      final event = await goal();
      clock.advance(10000);
      await repo.finish(id, requestId: 'finish');
      await repo.finish(id, requestId: 'finish');
      await expectLater(goal(key: 'new'), throwsStateError);
      await expectLater(
        repo.undo(id, event, reason: 'Late undo', requestId: 'undo'),
        throwsStateError,
      );
      await expectLater(
        repo.correctGoal(
          id,
          event,
          playerId: teams[0].playerIds[1],
          reason: 'Late fix',
          requestId: 'fix',
        ),
        throwsStateError,
      );
      await expectLater(
        repo.finish(id, requestId: 'finish-again'),
        throwsStateError,
      );
      await expectLater(
        db.customStatement("UPDATE matches SET phase='live' WHERE id=?", [id]),
        throwsA(isA<sqlite.SqliteException>()),
      );
      expect(
        (await repo.load(id))!.actions.where((a) => a.type == 'finish').length,
        1,
      );
    },
  );
  test(
    'match locks rosters and session completion waits for finished matches',
    () async {
      await expectLater(db.randomizeTeams(sessionId), throwsStateError);
      await expectLater(db.completeSession(sessionId), throwsStateError);
      final before = await db.teams(sessionId);
      await start();
      await repo.finish(id, requestId: 'finish');
      await db.completeSession(sessionId);
      final after = await db.teams(sessionId);
      expect(after.map((t) => t.playerIds), before.map((t) => t.playerIds));
      expect((await db.session(sessionId))!.status, 'completed');
    },
  );
  test(
    'v1 on-disk migration preserves IDs, events, roster history, and foreign keys',
    () async {
      final root = await Directory.systemTemp.createTemp('futsal-migration-');
      final file = File('${root.path}/legacy.sqlite');
      final old = V1Database(NativeDatabase(file));
      await old.customStatement(
        "INSERT INTO players VALUES ('p','Legacy',NULL,'Pivot',NULL,5,0,0,0)",
      );
      await old.customStatement(
        "INSERT INTO sessions VALUES ('s',0,'Court',600,'round_robin','planned',0)",
      );
      await old.customStatement(
        "INSERT INTO session_attendance VALUES ('a','s','p','available')",
      );
      await old.customStatement(
        "INSERT INTO session_teams VALUES ('t1','s','Green',4281643929,NULL,0)",
      );
      await old.customStatement(
        "INSERT INTO session_teams VALUES ('t2','s','Blue',4281643929,NULL,0)",
      );
      await old.customStatement(
        "INSERT INTO team_memberships VALUES ('membership','t1','s','p',0)",
      );
      await old.customStatement(
        "INSERT INTO matches VALUES ('legacy','s','t1','t2',600,'live',1000,NULL)",
      );
      await old.customStatement(
        "INSERT INTO matches VALUES ('unknown-start','s','t1','t2',600,'live',NULL,NULL)",
      );
      await old.customStatement(
        "INSERT INTO match_events VALUES ('legacy-goal','legacy','t1','p',NULL,'goal',20,21000)",
      );
      await old.close();
      final upgraded = AppDatabase.file(file);
      try {
        final engine = MatchRepository(upgraded, clock);
        final b = (await engine.load('legacy'))!;
        expect(b.match.phase, 'paused');
        expect(b.timer.recoveryRequired, isTrue);
        expect(b.score('t1'), 1);
        expect(b.events.single.id, 'legacy-goal');
        expect((await upgraded.teams('s')).first.playerIds, ['p']);
        expect((await upgraded.rows('PRAGMA foreign_key_check')), isEmpty);
        expect(
          (await upgraded.rows('PRAGMA user_version')).single.values.single,
          5,
        );
        await engine.reviewTimer(
          'unknown-start',
          0,
          requestId: 'legacy-review',
        );
        await engine.finish('unknown-start', requestId: 'legacy-finish');
        expect((await engine.load('unknown-start'))!.match.phase, 'finished');
      } finally {
        await upgraded.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'file reopening recovers a live timer and preserves scores and substitutions',
    () async {
      final root = await Directory.systemTemp.createTemp('futsal-engine-');
      final file = File('${root.path}/app.sqlite');
      var disk = AppDatabase.file(file);
      try {
        final players = <String>[];
        for (var i = 0; i < 6; i++) {
          players.add(
            await disk.savePlayer(
              name: 'Disk $i',
              position: 'Pivot',
              skillRating: 5,
            ),
          );
        }
        final sid = await disk.createSession(
          date: DateTime(2026, 11, 14),
          location: '',
          durationSeconds: 600,
          rotationMode: 'round_robin',
          playerIds: players,
          teamCount: 2,
        );
        final ts = await disk.teams(sid);
        var engine = MatchRepository(disk, clock);
        final mid = await engine.create(
          sessionId: sid,
          teamAId: ts.first.id,
          teamBId: ts.last.id,
          durationSeconds: 600,
          requestId: 'disk-match',
        );
        await engine.start(mid, {
          for (final t in ts) t.id: t.playerIds.take(2).toList(),
        }, requestId: 'disk-start');
        clock.advance(10000);
        await engine.substitute(
          mid,
          teamId: ts.first.id,
          outgoingId: ts.first.playerIds.first,
          incomingId: ts.first.playerIds.last,
          requestId: 'disk-sub',
        );
        clock.advance(5000);
        await engine.record(
          mid,
          type: 'goal',
          teamId: ts.first.id,
          playerId: ts.first.playerIds.last,
          requestId: 'disk-goal',
        );
        await disk.close();
        disk = AppDatabase.file(file);
        engine = MatchRepository(
          disk,
          TestMatchClock(
            runtimeId: 'reopened',
            wallMillis: clock.wallMillis + 5000,
          ),
        );
        final b = (await engine.load(mid))!;
        expect(b.score(ts.first.id), 1);
        expect(b.timer.accumulatedMillis, 20000);
        expect(b.match.phase, 'paused');
        expect(b.actions.where((a) => a.type == 'substitution').length, 1);
        expect(
          b.onField(ts.first.id).map((p) => p.id),
          contains(ts.first.playerIds.last),
        );
      } finally {
        await disk.close();
        await root.delete(recursive: true);
      }
    },
  );
}
