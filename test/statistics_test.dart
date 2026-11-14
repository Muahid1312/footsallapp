import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'package:saturday_futsal/features/statistics/data/statistics_repository.dart';
import 'package:saturday_futsal/features/statistics/domain/statistics.dart';
import 'package:saturday_futsal/features/teams/data/balance_repository.dart';
import 'support/test_clock.dart';

void main() {
  late AppDatabase db;
  late TestMatchClock clock;
  late MatchRepository matches;
  late StatisticsRepository stats;
  late String sid, mid, a, assist, bench, b;
  setUp(() async {
    db = AppDatabase.memory();
    clock = TestMatchClock();
    matches = MatchRepository(db, clock);
    stats = StatisticsRepository(db);
    final ids = <String>[];
    for (var i = 0; i < 6; i++) {
      ids.add(
        await db.savePlayer(
          name: 'Player $i',
          position: i == 0 ? 'Goalkeeper' : 'Winger',
          skillRating: 5,
        ),
      );
    }
    sid = await db.createSession(
      date: DateTime(2026, 11, 14),
      location: 'Court',
      durationSeconds: 600,
      rotationMode: 'round_robin',
      playerIds: ids,
      teamCount: 2,
    );
    final teams = await db.teams(sid);
    a = teams.first.playerIds.first;
    assist = teams.first.playerIds[1];
    bench = teams.first.playerIds.last;
    b = teams.last.playerIds.first;
    mid = await matches.create(
      sessionId: sid,
      teamAId: teams.first.id,
      teamBId: teams.last.id,
      durationSeconds: 600,
      requestId: 'match',
    );
    await matches.start(mid, {
      for (final t in teams) t.id: t.playerIds.take(2).toList(),
    }, requestId: 'start');
  });
  tearDown(() async => db.close());
  Future<void> play({bool undo = false}) async {
    clock.advance(10000);
    final m = (await matches.load(mid))!;
    final goal = await matches.record(
      mid,
      type: 'goal',
      teamId: m.teamA.id,
      playerId: a,
      assistId: assist,
      requestId: 'goal',
    );
    await matches.record(
      mid,
      type: 'foul',
      teamId: m.teamB.id,
      playerId: b,
      notes: 'Trip',
      requestId: 'foul',
    );
    if (undo) {
      await matches.undo(
        mid,
        goal,
        reason: 'Goal not awarded',
        requestId: 'undo',
      );
    }
    clock.advance(10000);
    await matches.finish(mid, requestId: 'finish');
  }

  test(
    'career goals, assists, fouls, WDL and rates use eligible finalized data',
    () async {
      await play();
      final all = await stats.load();
      final scorer = all.career(a),
          assister = all.career(assist),
          offender = all.career(b);
      expect(scorer.appearances, 1);
      expect(scorer.goals, 1);
      expect(scorer.wins, 1);
      expect(scorer.goalsPerMatch, 1);
      expect(assister.assists, 1);
      expect(assister.assistsPerMatch, 1);
      expect(offender.fouls, 1);
      expect(offender.losses, 1);
      expect(all.career(bench).appearances, 0);
      expect(all.career(bench).goalsPerMatch, isNull);
    },
  );
  test(
    'voided goals and assists disappear from careers and team results',
    () async {
      await play(undo: true);
      final all = await stats.load();
      expect(all.career(a).goals, 0);
      expect(all.career(assist).assists, 0);
      expect(all.career(a).draws, 1);
      expect(all.career(b).draws, 1);
    },
  );
  test(
    'live games and bench-only session attendance never fabricate appearances',
    () async {
      expect((await stats.load()).matches, isEmpty);
      await play();
      expect((await stats.load()).career(bench).appearances, 0);
      expect((await stats.playerHistory(bench)).single['session_id'], sid);
    },
  );
  test(
    'leaderboards share tied ranks and enforce configurable rate samples',
    () async {
      await play();
      final all = await stats.load();
      expect(all.leaderboard('goals').first.player.id, a);
      final appearances = all.leaderboard('appearances');
      expect(appearances.length, 4);
      expect(appearances.every((r) => r.position == 1), isTrue);
      expect(all.leaderboard('goals_per_match'), isEmpty);
      expect(
        all.leaderboard('goals_per_match', minimumAppearances: 1).first.value,
        1,
      );
      expect(all.leaderboard('assists').first.player.id, assist);
    },
  );
  test(
    'archived historical participants remain in career leaderboards',
    () async {
      await play();
      await db.archivePlayer(a);
      final all = await stats.load();
      expect(all.leaderboard('goals').first.player.isArchived, isTrue);
      expect(all.career(a).goals, 1);
    },
  );
  test(
    'session and recent-played filters exclude unrelated and unplayed sessions',
    () async {
      await play();
      final ids = (await db.players()).map((p) => p.id).toList();
      final empty = await db.createSession(
        date: DateTime(2026, 11, 21),
        location: 'Future',
        durationSeconds: 600,
        rotationMode: 'round_robin',
        playerIds: ids,
        teamCount: 2,
      );
      expect(
        (await stats.load(StatisticsScope(sessionId: empty))).matches,
        isEmpty,
      );
      expect(
        (await stats.load(
          const StatisticsScope(recentSessions: 1),
        )).matches.every((m) => m.sessionId == sid),
        isTrue,
      );
      expect(
        (await stats.load(StatisticsScope(sessionId: sid))).career(a).goals,
        1,
      );
    },
  );
  test(
    'MVP default weights produce a transparent breakdown and ignore injuries',
    () async {
      await play();
      var m = await stats.mvp(sid);
      expect(m.leaders, [a]);
      expect(m.candidates.first.score, 6);
      expect(m.candidates.first.breakdown, {
        'goals': 4,
        'assists': 0,
        'wins': 2,
        'fouls': 0,
      });
      await db.customStatement(
        'INSERT INTO injuries(id,player_id,session_id,description,occurred_at) VALUES (?,?,?,?,?)',
        ['injury', a, sid, 'Ankle', 0],
      );
      m = await stats.mvp(sid);
      expect(m.candidates.first.score, 6);
    },
  );
  test(
    'MVP confirmation is provisional until session completion and idempotent afterward',
    () async {
      await play();
      await expectLater(
        stats.confirmMvp(sid, playerId: a, requestId: 'award'),
        throwsStateError,
      );
      await db.completeSession(sid);
      await stats.confirmMvp(sid, playerId: a, requestId: 'award');
      await stats.confirmMvp(sid, playerId: a, requestId: 'award');
      final m = await stats.mvp(sid);
      expect(m.decisions.length, 1);
      expect(m.decisions.first['method'], 'calculated');
      expect(
        jsonDecode(m.decisions.first['calculation_json'] as String)['weights'],
        {'goal': 4, 'assist': 3, 'win': 2, 'foul': -1},
      );
    },
  );
  test(
    'MVP overrides retain prior decisions and reject ineligible bench players',
    () async {
      await play();
      await db.completeSession(sid);
      await stats.confirmMvp(sid, playerId: a, requestId: 'award');
      await expectLater(
        stats.confirmMvp(sid, playerId: bench, requestId: 'bench'),
        throwsArgumentError,
      );
      await stats.confirmMvp(
        sid,
        playerId: assist,
        reason: 'Administrator choice',
        requestId: 'override',
      );
      final m = await stats.mvp(sid);
      expect(m.decisions.length, 2);
      expect(m.decisions.first['revision'], 2);
      expect(m.decisions.first['method'], 'override');
      expect(m.decisions.last['player_id'], a);
    },
  );
  test(
    'MVP ties are shared explicitly and confirmed weights are immutable',
    () async {
      await play();
      await stats.setMvpWeights(
        sid,
        const MvpWeights(goal: 0, assist: 0, win: 0, foul: 0),
      );
      expect((await stats.mvp(sid)).leaders.length, 4);
      await db.completeSession(sid);
      await stats.confirmMvp(sid, shared: true, requestId: 'shared');
      expect((await stats.mvp(sid)).decisions.first['method'], 'shared');
      await expectLater(
        stats.setMvpWeights(sid, const MvpWeights()),
        throwsStateError,
      );
    },
  );
  test(
    'manual rating changes are audited without changing match statistics',
    () async {
      await play();
      final p = (await db.player(a))!;
      await db.savePlayer(
        id: a,
        name: p.name,
        position: p.preferredPosition,
        skillRating: 8,
        secondaryPosition: 'Pivot',
        updateSecondaryPosition: true,
        goalkeeperEligible: true,
      );
      final history = await stats.ratingHistory(a);
      expect(history.length, 2);
      expect(history.first['old_rating'], 5);
      expect(history.first['new_rating'], 8);
      expect((await db.player(a))!.secondaryPosition, 'Pivot');
      expect((await stats.load()).career(a).goals, 1);
      await db.completeSession(sid);
      await stats.confirmMvp(sid, playerId: a, requestId: 'award');
      expect((await db.player(a))!.skillRating, 8);
    },
  );
  test('scheduled match rosters cannot be regenerated or relocked', () async {
    final repo = BalanceRepository(db);
    await expectLater(repo.preview(sid), throwsStateError);
    await expectLater(
      repo.setLock(sid, a, (await db.teams(sid)).first.id),
      throwsStateError,
    );
  });
}
