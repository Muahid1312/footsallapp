import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/features/competitions/data/competition_repository.dart';
import 'package:saturday_futsal/features/competitions/domain/competition.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'support/test_clock.dart';

CompetitionFixture result(
  String a,
  String b,
  int ga,
  int gb, {
  String phase = 'finished',
  String kind = 'league',
}) => CompetitionFixture({
  'id': '$a-$b',
  'match_id': '$a-$b',
  'team_a_id': a,
  'team_b_id': b,
  'score_a': ga,
  'score_b': gb,
  'phase': phase,
  'status': phase == 'finished' ? 'finished' : 'pending',
  'kind': kind,
  'sequence': 1,
  'cycle': 1,
  'round_number': 1,
  'result_revision': 0,
});
void main() {
  group('deterministic fixture generation', () {
    test('two teams play once per cycle', () {
      final p = roundRobin(['a', 'b'], 1);
      expect(p.length, 1);
      expect({p.single.a, p.single.b}, {'a', 'b'});
    });
    test('three teams follow the requested order', () {
      expect(roundRobin(['a', 'b', 'c'], 1).map((f) => '${f.a}${f.b}'), [
        'ab',
        'bc',
        'ca',
      ]);
    });
    test('four teams have six unique pairs', () {
      final p = roundRobin(['a', 'b', 'c', 'd'], 1);
      expect(p.length, 6);
      expect(p.map((f) => ([f.a, f.b]..sort()).join()).toSet().length, 6);
    });
    test('odd teams have exactly one bye per round and one each per cycle', () {
      final p = roundRobin(['a', 'b', 'c', 'd', 'e'], 1), byes = <String>[];
      for (var r = 1; r <= 5; r++) {
        final used = p
            .where((f) => f.round == r)
            .expand((f) => [f.a, f.b])
            .toSet();
        expect(used.length, 4);
        byes.add(
          ['a', 'b', 'c', 'd', 'e'].singleWhere((t) => !used.contains(t)),
        );
      }
      expect(byes.toSet().length, 5);
    });
    test(
      'multiple cycles are deterministic and do not duplicate a cycle pair',
      () {
        final ids = ['a', 'b', 'c', 'd', 'e'];
        final p = roundRobin(ids, 3), again = roundRobin(ids, 3);
        expect(p.length, 30);
        expect(
          p.map((f) => '${f.cycle}:${f.a}:${f.b}'),
          again.map((f) => '${f.cycle}:${f.a}:${f.b}'),
        );
        for (var c = 1; c <= 3; c++) {
          expect(
            p
                .where((f) => f.cycle == c)
                .map((f) => ([f.a, f.b]..sort()).join())
                .toSet()
                .length,
            10,
          );
        }
      },
    );
  });
  group('winner stays rules', () {
    test('winner stays and loser goes to FIFO queue tail', () {
      final s = rotate(
        RotationState.initial(['a', 'b', 'c', 'd']),
        goalsA: 2,
        goalsB: 1,
        policy: 'both_rotate',
        sequence: 1,
        matchId: 'm',
      );
      expect(s.playing, ['a', 'c']);
      expect(s.queue, ['d', 'b']);
    });
    test('both rotate on a draw when two waiters exist', () {
      final s = rotate(
        RotationState.initial(['a', 'b', 'c', 'd']),
        goalsA: 1,
        goalsB: 1,
        policy: 'both_rotate',
        sequence: 1,
        matchId: 'm',
      );
      expect(s.playing, ['c', 'd']);
      expect(s.queue, ['a', 'b']);
    });
    test(
      'three-team draw rotates oldest tenure with an explicit equal-tenure rule',
      () {
        final s = rotate(
          RotationState.initial(['a', 'b', 'c']),
          goalsA: 0,
          goalsB: 0,
          policy: 'both_rotate',
          sequence: 1,
          matchId: 'm',
        );
        expect(s.playing, ['b', 'c']);
        expect(s.queue, ['a']);
      },
    );
    test('manual draw waits without inventing a winner', () {
      final s = rotate(
        RotationState.initial(['a', 'b', 'c']),
        goalsA: 1,
        goalsB: 1,
        policy: 'manual',
        sequence: 1,
        matchId: 'm',
      );
      expect(s.awaitingMatch, 'm');
      expect(s.playing, ['a', 'b']);
    });
    test('two-team mode permits a rematch', () {
      final s = rotate(
        RotationState.initial(['a', 'b']),
        goalsA: 0,
        goalsB: 2,
        policy: 'longest',
        sequence: 1,
        matchId: 'm',
      );
      expect(s.playing.toSet(), {'a', 'b'});
      expect(s.queue, isEmpty);
    });
    test('a persistent winner cannot exclude any waiter', () {
      var s = RotationState.initial(['a', 'b', 'c', 'd', 'e']);
      final entrants = <String>{};
      for (var i = 1; i <= 8; i++) {
        s = rotate(
          s,
          goalsA: 1,
          goalsB: 0,
          policy: 'longest',
          sequence: i,
          matchId: '$i',
        );
        entrants.add(s.playing.last);
      }
      expect(entrants, {'b', 'c', 'd', 'e'});
    });
  });
  group('derived standings', () {
    test(
      'counts actual results, points, goals, and excludes unfinished/playoff games',
      () {
        final s = standings(
          ['a', 'b', 'c'],
          [
            result('a', 'b', 2, 0),
            result('b', 'c', 1, 1),
            result('a', 'c', 99, 0, phase: 'live'),
            result('a', 'c', 99, 0, kind: 'playoff'),
          ],
          win: 3,
          draw: 1,
          loss: 0,
        );
        final a = s.singleWhere((s) => s.teamId == 'a'),
            b = s.singleWhere((s) => s.teamId == 'b');
        expect(a.points, 3);
        expect(a.played, 1);
        expect(a.goalsFor, 2);
        expect(b.played, 2);
        expect(b.points, 1);
        expect(b.difference, -2);
      },
    );
    test('goal difference separates equal points', () {
      final s = standings(
        ['a', 'b', 'c', 'd'],
        [result('a', 'c', 3, 0), result('b', 'd', 1, 0)],
        win: 3,
        draw: 1,
        loss: 0,
      );
      expect(s.first.teamId, 'a');
    });
    test('balanced head-to-head resolves equal global totals', () {
      final s = standings(
        ['a', 'b', 'c', 'd'],
        [
          result('a', 'b', 1, 0),
          result('a', 'c', 0, 1),
          result('a', 'd', 0, 0),
          result('b', 'c', 1, 0),
          result('b', 'd', 0, 0),
          result('c', 'd', 1, 0),
        ],
        win: 3,
        draw: 1,
        loss: 0,
      );
      final a = s.singleWhere((r) => r.teamId == 'a'),
          b = s.singleWhere((r) => r.teamId == 'b');
      expect(a.rankKey, b.rankKey);
      expect(a.position, lessThan(b.position));
    });
    test('an unresolved cyclic tie uses shared positions', () {
      final s = standings(
        ['a', 'b', 'c'],
        [
          result('a', 'b', 1, 0),
          result('b', 'c', 1, 0),
          result('c', 'a', 1, 0),
        ],
        win: 3,
        draw: 1,
        loss: 0,
      );
      expect(s.map((r) => r.position), [1, 1, 1]);
    });
  });
  group('persisted competition and Phase 2 integration', () {
    late AppDatabase db;
    late TestMatchClock clock;
    late CompetitionRepository comp;
    late MatchRepository matches;
    late String sid;
    setUp(() async {
      db = AppDatabase.memory();
      clock = TestMatchClock();
      comp = CompetitionRepository(db, clock);
      matches = MatchRepository(db, clock);
      final players = <String>[];
      for (var i = 0; i < 9; i++) {
        players.add(
          await db.savePlayer(
            name: 'Player $i',
            position: 'Pivot',
            skillRating: 5,
          ),
        );
      }
      sid = await db.createSession(
        date: DateTime(2026, 11, 14),
        location: 'Court',
        durationSeconds: 600,
        rotationMode: 'round_robin',
        playerIds: players,
        teamCount: 3,
      );
    });
    tearDown(() async => db.close());
    Future<String> create({
      String mode = 'round_robin',
      String policy = 'both_rotate',
      int? count,
      int limit = 3,
      String criterion = 'points',
    }) async {
      final teams = await db.teams(sid);
      return comp.create(
        sessionId: sid,
        teamIds: teams.take(count ?? teams.length).map((t) => t.id).toList(),
        mode: mode,
        durationSeconds: 600,
        drawPolicy: policy,
        matchLimit: limit,
        criterion: criterion,
        requestId: 'competition',
      );
    }

    Future<void> play(CompetitionFixture f, {bool goal = false}) async {
      final b = (await matches.load(f.matchId))!;
      await matches.start(f.matchId, {
        b.teamA.id: b.teamA.playerIds,
        b.teamB.id: b.teamB.playerIds,
      }, requestId: 'start-${f.matchId}');
      clock.advance(10000);
      if (goal) {
        await matches.record(
          f.matchId,
          type: 'goal',
          teamId: f.a,
          playerId: b.teamA.playerIds.first,
          requestId: 'goal-${f.matchId}',
        );
      }
      await matches.finish(f.matchId, requestId: 'finish-${f.matchId}');
    }

    test(
      'draft/active settings persist and a conflicting competition is rejected',
      () async {
        final id = await create();
        await comp.activate(id, requestId: 'activate');
        await comp.activate(id, requestId: 'activate');
        expect((await comp.required(id)).fixtures.length, 3);
        await expectLater(
          comp.activate(id, requestId: 'regenerate'),
          throwsStateError,
        );
        await expectLater(
          comp.create(
            sessionId: sid,
            teamIds: (await db.teams(sid)).map((t) => t.id).toList(),
            mode: 'round_robin',
            durationSeconds: 600,
            requestId: 'other',
          ),
          throwsStateError,
        );
      },
    );
    test('draft rule edits are audited and lock at activation', () async {
      final id = await create();
      await comp.updateDraft(
        id,
        mode: 'round_robin',
        durationSeconds: 300,
        win: 5,
        draw: 2,
        loss: 0,
        cycles: 2,
        drawPolicy: 'longest',
        criterion: 'points',
        matchLimit: 6,
        requestId: 'settings',
      );
      await comp.activate(id, requestId: 'activate');
      final b = await comp.required(id);
      expect(b.competition.win, 5);
      expect(b.fixtures.length, 6);
      expect(
        (await matches.load(b.fixtures.first.matchId))!.match.durationSeconds,
        300,
      );
      await expectLater(
        comp.updateDraft(
          id,
          mode: 'round_robin',
          durationSeconds: 600,
          win: 3,
          draw: 1,
          loss: 0,
          cycles: 1,
          drawPolicy: 'longest',
          criterion: 'points',
          matchLimit: 6,
          requestId: 'late-settings',
        ),
        throwsStateError,
      );
    });
    test(
      'compatible unplayed matches are reused even with reversed teams',
      () async {
        final teams = await db.teams(sid);
        await matches.create(
          sessionId: sid,
          teamAId: teams[1].id,
          teamBId: teams[0].id,
          durationSeconds: 600,
          requestId: 'existing',
        );
        final id = await create(mode: 'winner_stays');
        await comp.activate(id, requestId: 'activate');
        final first = (await comp.required(id)).fixtures.single;
        expect(first.matchId, 'existing');
        expect((await db.rows('SELECT * FROM matches')).length, 1);
        await play(first, goal: true);
        expect(
          (await comp.required(id)).competition.rotation.playing.first,
          teams[1].id,
        );
      },
    );
    test(
      'finalizing advances FIFO once and repeated finish creates no duplicate match',
      () async {
        final id = await create(mode: 'winner_stays');
        await comp.activate(id, requestId: 'activate');
        final first = (await comp.required(id)).fixtures.single;
        await play(first, goal: true);
        await matches.finish(
          first.matchId,
          requestId: 'finish-${first.matchId}',
        );
        final b = await comp.required(id);
        expect(b.fixtures.length, 2);
        expect(b.competition.rotation.playing.first, first.a);
        expect(b.table.singleWhere((r) => r.teamId == first.a).won, 1);
        expect(
          (await db.rows('SELECT * FROM competition_applications')).length,
          1,
        );
      },
    );
    test('manual draw creates no fixture until explicitly resolved', () async {
      final id = await create(mode: 'winner_stays', policy: 'manual');
      await comp.activate(id, requestId: 'activate');
      final first = (await comp.required(id)).fixtures.single;
      await play(first);
      expect((await comp.required(id)).fixtures.length, 1);
      await comp.resolveDraw(
        id,
        stayer: first.b,
        reason: 'Agreed rotation',
        requestId: 'resolve',
      );
      await comp.resolveDraw(
        id,
        stayer: first.b,
        reason: 'Agreed rotation',
        requestId: 'resolve',
      );
      final b = await comp.required(id);
      expect(b.fixtures.length, 2);
      expect(b.competition.rotation.playing.first, first.b);
      expect(b.table.every((r) => r.won == 0), isTrue);
    });
    test(
      'postpone/restore/cancel preserve match identity and require explicit early completion',
      () async {
        final id = await create();
        await comp.activate(id, requestId: 'activate');
        var b = await comp.required(id);
        final first = b.fixtures.first;
        await comp.manageFixture(
          id,
          first.id,
          'postpone',
          reason: 'Team resting',
          requestId: 'postpone',
        );
        final match = (await matches.load(first.matchId))!;
        await expectLater(
          matches.start(first.matchId, {
            match.teamA.id: match.teamA.playerIds,
            match.teamB.id: match.teamB.playerIds,
          }, requestId: 'start-blocked'),
          throwsStateError,
        );
        await comp.manageFixture(
          id,
          first.id,
          'restore',
          reason: 'Ready',
          requestId: 'restore',
        );
        await play(first, goal: true);
        for (final f in (await comp.required(id)).fixtures.skip(1)) {
          await comp.manageFixture(
            id,
            f.id,
            'cancel',
            reason: 'Weather',
            requestId: 'cancel-${f.id}',
          );
        }
        await expectLater(
          comp.complete(id, reason: '', requestId: 'complete'),
          throwsStateError,
        );
        await comp.complete(
          id,
          endEarly: true,
          reason: 'Weather ended play',
          requestId: 'complete',
        );
        b = await comp.required(id);
        expect(b.competition.status, 'completed');
        expect(b.decision!['champion_team_id'], first.a);
      },
    );
    test(
      'unresolved ties remain explicit and a shared title is persisted',
      () async {
        final id = await create(count: 2);
        await comp.activate(id, requestId: 'activate');
        await play((await comp.required(id)).fixtures.single);
        await expectLater(
          comp.complete(id, reason: '', requestId: 'end'),
          throwsStateError,
        );
        await comp.complete(
          id,
          shared: true,
          reason: 'Shared title agreed',
          requestId: 'shared',
        );
        final b = await comp.required(id);
        expect(b.decision!['method'], 'shared');
        expect(b.decision!['champion_team_id'], isNull);
      },
    );
    test(
      'a decisive playoff determines the champion without changing league standings',
      () async {
        final id = await create(count: 2);
        await comp.activate(id, requestId: 'activate');
        await play((await comp.required(id)).fixtures.single);
        final game = await comp.playoff(id, requestId: 'playoff');
        expect(await comp.playoff(id, requestId: 'playoff'), game);
        final f = (await comp.required(id)).fixtures.last;
        await play(f, goal: true);
        await comp.complete(id, reason: '', requestId: 'complete');
        final b = await comp.required(id);
        expect(b.decision!['method'], 'playoff');
        expect(b.decision!['champion_team_id'], f.a);
        expect(b.table.map((r) => r.played), [1, 1]);
      },
    );
    test('most-wins criterion identifies the configured winner', () async {
      final id = await create(
        mode: 'winner_stays',
        count: 2,
        limit: 2,
        criterion: 'wins',
      );
      await comp.activate(id, requestId: 'activate');
      await play((await comp.required(id)).fixtures.last, goal: true);
      await play((await comp.required(id)).fixtures.last, goal: true);
      await comp.complete(id, reason: '', requestId: 'complete');
      final b = await comp.required(id);
      expect(b.decision!['method'], 'wins');
      expect(b.decision!['champion_team_id'], b.teams.first.id);
    });
    test(
      'latest rotation result correction rewinds only unplayed dependencies',
      () async {
        final id = await create(mode: 'winner_stays');
        await comp.activate(id, requestId: 'activate');
        final first = (await comp.required(id)).fixtures.single;
        await play(first, goal: true);
        await comp.reopen(
          id,
          first.matchId,
          reason: 'Goal entered twice',
          requestId: 'reopen',
        );
        final event = (await matches.load(first.matchId))!.activeEvents.single;
        await matches.undo(
          first.matchId,
          event.id,
          reason: 'Incorrect goal',
          requestId: 'undo',
        );
        await matches.addCorrectionGoal(
          first.matchId,
          teamId: first.b,
          playerId: (await matches.load(first.matchId))!.teamB.playerIds.first,
          elapsedMillis: 5000,
          reason: 'Missed away goal',
          requestId: 'missing',
        );
        await matches.finish(first.matchId, requestId: 'refinish');
        final b = await comp.required(id);
        expect(b.fixtures.where((f) => f.phase == 'scheduled').length, 1);
        expect(b.competition.rotation.playing.first, first.b);
        expect(b.fixtures.where((f) => f.phase == 'cancelled').length, 1);
        expect(
          (await db.rows('SELECT * FROM competition_applications')).length,
          2,
        );
      },
    );
    test(
      'earlier winner-stays results cannot overwrite an already played rotation',
      () async {
        final id = await create(mode: 'winner_stays');
        await comp.activate(id, requestId: 'activate');
        final first = (await comp.required(id)).fixtures.single;
        await play(first, goal: true);
        await play((await comp.required(id)).fixtures.last, goal: true);
        await expectLater(
          comp.reopen(
            id,
            first.matchId,
            reason: 'Late change',
            requestId: 'bad-reopen',
          ),
          throwsStateError,
        );
      },
    );
    test(
      'reconstructing repositories restores queue, current match, and old session rosters',
      () async {
        final id = await create(mode: 'winner_stays');
        await comp.activate(id, requestId: 'activate');
        final before = await db.teams(sid);
        await play((await comp.required(id)).fixtures.first, goal: true);
        final rebuilt = CompetitionRepository(
          db,
          TestMatchClock(runtimeId: 'restarted'),
        );
        final b = await rebuilt.required(id);
        expect(b.competition.status, 'active');
        expect(b.fixtures.length, 2);
        expect(b.competition.rotation.queue.length, 1);
        final players = (await db.players()).map((p) => p.id).toList();
        await db.createSession(
          date: DateTime(2026, 11, 21),
          location: 'Other',
          durationSeconds: 600,
          rotationMode: 'winner_stays',
          playerIds: players,
          teamCount: 3,
        );
        expect(
          (await db.teams(sid)).map((t) => t.playerIds),
          before.map((t) => t.playerIds),
        );
      },
    );
  });
  test('active competition and queue survive actual file reopening', () async {
    final root = await Directory.systemTemp.createTemp('competition-reopen-');
    var db = AppDatabase.file(File('${root.path}/app.sqlite'));
    final clock = TestMatchClock();
    try {
      final ids = <String>[];
      for (var i = 0; i < 6; i++) {
        ids.add(
          await db.savePlayer(name: 'P$i', position: 'Pivot', skillRating: 5),
        );
      }
      final sid = await db.createSession(
        date: DateTime(2026, 11, 14),
        location: '',
        durationSeconds: 600,
        rotationMode: 'winner_stays',
        playerIds: ids,
        teamCount: 3,
      );
      var repo = CompetitionRepository(db, clock);
      final comp = await repo.create(
        sessionId: sid,
        teamIds: (await db.teams(sid)).map((t) => t.id).toList(),
        mode: 'winner_stays',
        durationSeconds: 600,
        requestId: 'comp',
      );
      await repo.activate(comp, requestId: 'activate');
      final fixture = (await repo.required(comp)).fixtures.first;
      final engine = MatchRepository(db, clock),
          m = (await MatchRepository(db, clock).load(fixture.matchId))!;
      await engine.start(m.match.id, {
        m.teamA.id: m.teamA.playerIds,
        m.teamB.id: m.teamB.playerIds,
      }, requestId: 'start');
      clock.advance(12000);
      await engine.checkpoint(m.match.id);
      await db.close();
      db = AppDatabase.file(File('${root.path}/app.sqlite'));
      repo = CompetitionRepository(
        db,
        TestMatchClock(runtimeId: 'restart', wallMillis: clock.wallMillis),
      );
      final b = await repo.required(comp);
      expect(b.fixtures.single.matchId, fixture.matchId);
      expect(b.competition.rotation.queue.length, 1);
      final recovered = (await MatchRepository(
        db,
        TestMatchClock(runtimeId: 'restart', wallMillis: clock.wallMillis),
      ).load(fixture.matchId))!;
      expect(recovered.match.phase, 'paused');
      expect((await db.rows('PRAGMA foreign_key_check')), isEmpty);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
