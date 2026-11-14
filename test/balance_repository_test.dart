import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/features/teams/data/balance_repository.dart';
import 'package:saturday_futsal/features/teams/domain/team_balancer.dart';

void main() {
  late AppDatabase db;
  late BalanceRepository repo;
  late String sid;
  setUp(() async {
    db = AppDatabase.memory();
    repo = BalanceRepository(db);
    final ids = <String>[];
    for (var i = 0; i < 7; i++) {
      ids.add(
        await db.savePlayer(
          name: 'Player $i',
          position: i < 2 ? 'Goalkeeper' : 'Winger',
          skillRating: i + 1,
        ),
      );
    }
    sid = await db.createSession(
      date: DateTime(2026, 11, 14),
      location: '',
      durationSeconds: 600,
      rotationMode: 'round_robin',
      playerIds: ids,
      teamCount: 2,
    );
  });
  tearDown(() async => db.close());
  test(
    'preview never mutates saved rosters; confirmation saves exact validated assignments',
    () async {
      final before = await db.teams(sid),
          preview = await repo.preview(sid, seed: 12, iterations: 20);
      expect(
        (await db.teams(sid)).map((t) => t.playerIds),
        before.map((t) => t.playerIds),
      );
      await repo.confirm(sid, preview);
      final saved = await db.teams(sid);
      for (final t in saved) {
        expect(t.playerIds, preview.result.assignments[t.id]);
      }
    },
  );
  test(
    'persistent locks survive repository reconstruction and all generation paths honor them',
    () async {
      final teams = await db.teams(sid), player = teams.first.playerIds.first;
      await repo.setLock(sid, player, teams.first.id);
      final reopened = BalanceRepository(db);
      final preview = await reopened.preview(sid, seed: 42, iterations: 10);
      expect(preview.result.assignments[teams.first.id], contains(player));
      await db.randomizeTeams(sid);
      expect((await db.teams(sid)).first.playerIds, contains(player));
      final roster = await db.teams(sid);
      await expectLater(
        db.swapPlayers(sid, player, roster.last.playerIds.first),
        throwsStateError,
      );
    },
  );
  test(
    'a rating edit invalidates a stale balance preview without replacing history',
    () async {
      final preview = await repo.preview(sid, iterations: 10),
          before = await db.teams(sid),
          p = (await db.attendees(sid)).first;
      await db.savePlayer(
        id: p.id,
        name: p.name,
        position: p.preferredPosition,
        skillRating: p.skillRating == 10 ? 9 : 10,
      );
      await expectLater(repo.confirm(sid, preview), throwsStateError);
      expect(
        (await db.teams(sid)).map((t) => t.playerIds),
        before.map((t) => t.playerIds),
      );
    },
  );
  test(
    'newly scheduled matches prevent a previously generated preview from overwriting rosters',
    () async {
      final preview = await repo.preview(sid, iterations: 10),
          teams = await db.teams(sid);
      await db.customStatement(
        "INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase) VALUES ('m',?,?,?,?, 'scheduled','scheduled')",
        [sid, teams.first.id, teams.last.id, 600],
      );
      await expectLater(repo.confirm(sid, preview), throwsStateError);
    },
  );
  test(
    'preview manual swaps revalidate complete membership before confirmation',
    () async {
      final preview = await repo.preview(sid, iterations: 10),
          map = {
            for (final e in preview.result.assignments.entries)
              e.key: [...e.value],
          };
      final a = preview.request.teams.first,
          b = preview.request.teams.last,
          pa = map[a]!.first,
          pb = map[b]!.first;
      map[a]![0] = pb;
      map[b]![0] = pa;
      final changed = BalancePreview(
        preview.request,
        describeBalance(preview.request, map),
        preview.fingerprint,
      );
      await repo.confirm(sid, changed);
      expect((await db.teams(sid)).first.playerIds, contains(pb));
    },
  );
  test('roster writes require an explicit override for uneven sizes', () async {
    final teams = await db.teams(sid),
        players = teams.expand((t) => t.playerIds).toList(),
        assignments = {
          teams.first.id: players.take(5).toList(),
          teams.last.id: players.skip(5).toList(),
        };
    await expectLater(db.replaceRosters(sid, assignments), throwsArgumentError);
    await db.replaceRosters(sid, assignments, allowUneven: true);
    await db.swapPlayers(sid, players.first, players.last);
    expect((await db.teams(sid)).map((t) => t.playerIds.length), [5, 2]);
  });
}
