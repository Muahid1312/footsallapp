import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'package:saturday_futsal/features/matches/data/system_match_clock.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  Future<String> add([String name = 'Player']) =>
      db.savePlayer(name: name, position: 'Winger', skillRating: 6);
  Future<List<String>> squad(int n) async => [
    for (var i = 0; i < n; i++) await add('Player $i'),
  ];
  Future<String> session(List<String> ids, {int count = 2}) => db.createSession(
    date: DateTime(2026, 11, 14),
    location: 'Community court',
    durationSeconds: 600,
    rotationMode: 'round_robin',
    playerIds: ids,
    teamCount: count,
  );

  test(
    'creates and updates a player without changing identity or creation date',
    () async {
      final id = await add('  Ahmad  ');
      final original = (await db.player(id))!;
      expect(original.name, 'Ahmad');
      await db.savePlayer(
        id: id,
        name: 'Ahmad Khan',
        position: 'Pivot',
        jerseyNumber: 9,
        skillRating: 9,
        photoPath: '/photos/permanent.jpg',
      );
      final updated = (await db.player(id))!;
      expect(updated.name, 'Ahmad Khan');
      expect(updated.id, id);
      expect(updated.createdAt, original.createdAt);
      expect(updated.skillRating, 9);
      expect(updated.jerseyNumber, 9);
      expect(updated.photoPath, '/photos/permanent.jpg');
    },
  );
  test('rejects invalid player values', () async {
    await expectLater(
      db.savePlayer(name: ' ', position: 'Pivot', skillRating: 5),
      throwsArgumentError,
    );
    await expectLater(
      db.savePlayer(name: 'Ali', position: 'Pivot', skillRating: 11),
      throwsArgumentError,
    );
    await expectLater(
      db.savePlayer(
        name: 'Ali',
        position: 'Pivot',
        skillRating: 5,
        jerseyNumber: -1,
      ),
      throwsArgumentError,
    );
  });
  test(
    'archive hides from directory but preserves historical attendance and rosters',
    () async {
      final ids = await squad(4);
      final sid = await session(ids);
      await db.archivePlayer(ids.first);
      expect((await db.players()).length, 3);
      expect((await db.player(ids.first))!.isArchived, isTrue);
      expect((await db.attendees(sid)).length, 4);
      expect(
        (await db.teams(sid)).expand((t) => t.playerIds),
        contains(ids.first),
      );
      await expectLater(session(ids), throwsStateError);
      expect((await db.sessions()).length, 1); // Failed creation rolls back.
      await db.archivePlayer(ids.first, archived: false);
      expect((await db.players()).length, 4);
    },
  );
  test('creates session, attendance, and teams in one transaction', () async {
    final ids = await squad(6);
    final sid = await session(ids, count: 3);
    final s = (await db.session(sid))!;
    expect(s.date, DateTime.utc(2026, 11, 14));
    expect(s.locationName, 'Community court');
    expect(s.matchDurationSeconds, 600);
    expect(s.rotationMode, 'round_robin');
    expect(s.status, 'planned');
    expect((await db.attendees(sid)).map((p) => p.id).toSet(), ids.toSet());
    expect((await db.teams(sid)).length, 3);
  });
  test(
    'rejects invalid counts, duplicate attendance, and non-Saturdays',
    () async {
      final ids = await squad(3);
      await expectLater(session(ids, count: 4), throwsArgumentError);
      await expectLater(session([ids.first, ids.first]), throwsArgumentError);
      await expectLater(session(ids, count: 1), throwsArgumentError);
      await expectLater(
        db.createSession(
          date: DateTime(2026, 11, 15),
          location: '',
          durationSeconds: 600,
          rotationMode: 'round_robin',
          playerIds: ids,
          teamCount: 2,
        ),
        throwsArgumentError,
      );
      expect(await db.sessions(), isEmpty);
    },
  );
  test(
    'random generation includes every player once, balanced for uneven counts',
    () async {
      final ids = await squad(11);
      final sid = await session(ids, count: 3);
      await db.randomizeTeams(sid, random: Random(42));
      final teams = await db.teams(sid);
      expect(teams.map((t) => t.playerIds.length).toList()..sort(), [3, 4, 4]);
      final assignments = teams.expand((t) => t.playerIds).toList();
      expect(assignments.length, 11);
      expect(assignments.toSet(), ids.toSet());
      final first = teams.map((t) => t.playerIds.join(',')).join('|');
      await db.randomizeTeams(sid, random: Random(42));
      expect(
        (await db.teams(sid)).map((t) => t.playerIds.join(',')).join('|'),
        first,
      );
    },
  );
  test(
    'supports more teams than color palette and keeps every player',
    () async {
      final ids = await squad(20);
      final sid = await session(ids, count: 10);
      final teams = await db.teams(sid);
      expect(teams.length, 10);
      expect(teams.every((t) => t.playerIds.length == 2), isTrue);
      expect(teams.expand((t) => t.playerIds).toSet(), ids.toSet());
    },
  );
  test('manual swap exchanges players and clears a moved captain', () async {
    final sid = await session(await squad(4));
    final before = await db.teams(sid);
    final a = before.first,
        b = before.last,
        pa = a.playerIds.first,
        pb = b.playerIds.first;
    await db.updateTeam(
      sid,
      a.id,
      name: 'Emerald FC',
      colorValue: teamColors[0],
      captainPlayerId: pa,
    );
    await db.swapPlayers(sid, pa, pb);
    final after = await db.teams(sid);
    expect(after.first.playerIds, contains(pb));
    expect(after.first.playerIds, isNot(contains(pa)));
    expect(after.last.playerIds, contains(pa));
    expect(after.first.captainPlayerId, isNull);
    expect(after.first.name, 'Emerald FC');
    expect(after.map((t) => t.playerIds.length), [2, 2]);
  });
  test('manual move persists and prevents empty teams', () async {
    final sid = await session(await squad(4));
    var teams = await db.teams(sid);
    await db.movePlayer(
      sid,
      teams.first.playerIds.first,
      teams.last.id,
      allowUneven: true,
    );
    teams = await db.teams(sid);
    expect(teams.map((t) => t.playerIds.length), [1, 3]);
    await expectLater(
      db.movePlayer(
        sid,
        teams.first.playerIds.first,
        teams.last.id,
        allowUneven: true,
      ),
      throwsArgumentError,
    );
    expect((await db.teams(sid)).map((t) => t.playerIds.length), [1, 3]);
  });
  test('invalid roster replacement rolls back and preserves captain', () async {
    final sid = await session(await squad(4));
    final teams = await db.teams(sid);
    await db.updateTeam(
      sid,
      teams.first.id,
      name: 'Green',
      colorValue: teamColors.first,
      captainPlayerId: teams.first.playerIds.first,
    );
    await expectLater(
      db.replaceRosters(sid, {
        teams.first.id: teams.first.playerIds,
        teams.last.id: teams.first.playerIds,
      }),
      throwsArgumentError,
    );
    final after = await db.teams(sid);
    expect(after.first.playerIds, teams.first.playerIds);
    expect(after.first.captainPlayerId, teams.first.playerIds.first);
  });
  test(
    'new session and regeneration never overwrite historical teams',
    () async {
      final ids = await squad(8);
      final old = await session(ids);
      final before = await db.teams(old);
      final next = await session(ids, count: 3);
      await db.randomizeTeams(next, random: Random(9));
      final after = await db.teams(old);
      expect(after.map((t) => t.id), before.map((t) => t.id));
      for (var i = 0; i < before.length; i++) {
        expect(after[i].playerIds, before[i].playerIds);
      }
    },
  );
  test(
    'completed sessions are immutable through application operations',
    () async {
      final sid = await session(await squad(4));
      await db.completeSession(sid);
      await expectLater(db.randomizeTeams(sid), throwsStateError);
      final t = (await db.teams(sid)).first;
      await expectLater(
        db.updateTeam(sid, t.id, name: 'Other', colorValue: t.colorValue),
        throwsStateError,
      );
      await expectLater(
        db.customStatement('UPDATE session_teams SET name=? WHERE id=?', [
          'Changed',
          t.id,
        ]),
        throwsA(isA<SqliteException>()),
      );
      final outsider = await add('New attendee');
      await expectLater(
        db.customStatement('INSERT INTO session_attendance VALUES (?,?,?,?)', [
          'late',
          sid,
          outsider,
          'available',
        ]),
        throwsA(isA<SqliteException>()),
      );
    },
  );
  test(
    'SQLite constraints reject duplicate and cross-session memberships',
    () async {
      final ids = await squad(4);
      final sid = await session(ids);
      final other = await session(ids);
      final teams = await db.teams(sid);
      final foreign = (await db.teams(other)).first;
      final unassigned = await add('Available but unassigned');
      await db.customStatement(
        'INSERT INTO session_attendance VALUES (?,?,?,?)',
        ['extra-attendance', sid, unassigned, 'available'],
      );
      await expectLater(
        db.customStatement('INSERT INTO team_memberships VALUES (?,?,?,?,?)', [
          'duplicate',
          teams.last.id,
          sid,
          teams.first.playerIds.first,
          0,
        ]),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement('INSERT INTO team_memberships VALUES (?,?,?,?,?)', [
          'cross',
          foreign.id,
          sid,
          unassigned,
          0,
        ]),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.message,
            'message',
            contains('FOREIGN KEY'),
          ),
        ),
      );
      final outsider = await add('Not attending');
      await expectLater(
        db.customStatement('INSERT INTO team_memberships VALUES (?,?,?,?,?)', [
          'outsider',
          teams.first.id,
          sid,
          outsider,
          0,
        ]),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement('DELETE FROM players WHERE id=?', [ids.first]),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement('UPDATE players SET skill_rating=0 WHERE id=?', [
          ids.first,
        ]),
        throwsA(anything),
      );
    },
  );
  test(
    'captain must be on team, and raw captain membership deletion is rejected',
    () async {
      final sid = await session(await squad(4));
      final teams = await db.teams(sid);
      await expectLater(
        db.customStatement(
          'UPDATE session_teams SET captain_player_id=? WHERE id=?',
          [teams.last.playerIds.first, teams.first.id],
        ),
        throwsA(anything),
      );
      final captain = teams.first.playerIds.first;
      await db.updateTeam(
        sid,
        teams.first.id,
        name: 'Captain FC',
        colorValue: teamColors.first,
        captainPlayerId: captain,
      );
      await expectLater(
        db.customStatement(
          'DELETE FROM team_memberships WHERE team_id=? AND player_id=?',
          [teams.first.id, captain],
        ),
        throwsA(anything),
      );
    },
  );
  test(
    'future events validate teams, scorer, assist, and elapsed time; matches lock rosters',
    () async {
      final ids = await squad(6);
      final sid = await session(ids);
      final teams = await db.teams(sid);
      final outsider = await add('Outsider');
      final engine = MatchRepository(db, SystemMatchClock());
      await engine.create(
        sessionId: sid,
        teamAId: teams.first.id,
        teamBId: teams.last.id,
        durationSeconds: 600,
        requestId: 'match',
      );
      await engine.start('match', {
        for (final t in teams) t.id: t.playerIds,
      }, requestId: 'start-match');
      Future<void> event(
        String id,
        String team,
        String? player,
        String? assist,
        int elapsed,
      ) => db.customStatement(
        'INSERT INTO match_events(id,match_id,team_id,player_id,related_player_id,event_type,elapsed_seconds,created_at) VALUES (?,?,?,?,?,?,?,?)',
        [id, 'match', team, player, assist, 'goal', elapsed, 0],
      );
      await event(
        'goal',
        teams.first.id,
        teams.first.playerIds.first,
        teams.first.playerIds.last,
        40,
      );
      await expectLater(
        event('bad-player', teams.first.id, outsider, null, 50),
        throwsA(anything),
      );
      await expectLater(
        event(
          'bad-assist',
          teams.first.id,
          teams.first.playerIds.first,
          teams.last.playerIds.first,
          50,
        ),
        throwsA(anything),
      );
      await expectLater(
        event(
          'self-assist',
          teams.first.id,
          teams.first.playerIds.first,
          teams.first.playerIds.first,
          50,
        ),
        throwsA(anything),
      );
      await expectLater(
        event('late', teams.first.id, null, null, 601),
        throwsA(anything),
      );
      await expectLater(db.randomizeTeams(sid), throwsStateError);
      expect((await db.rows('SELECT * FROM match_events')).length, 1);
    },
  );

  test(
    'file database preserves players, session, captain, and rosters after reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp('futsal-test-');
      final file = File('${directory.path}/test.sqlite');
      var disk = AppDatabase.file(file);
      try {
        final a = await disk.savePlayer(
          name: 'Persistent A',
          position: 'Pivot',
          skillRating: 7,
        );
        final b = await disk.savePlayer(
          name: 'Persistent B',
          position: 'Goalkeeper',
          skillRating: 8,
        );
        final sid = await disk.createSession(
          date: DateTime(2026, 11, 14),
          location: 'Home court',
          durationSeconds: 900,
          rotationMode: 'winner_stays',
          playerIds: [a, b],
          teamCount: 2,
        );
        final before = await disk.teams(sid);
        await disk.updateTeam(
          sid,
          before.first.id,
          name: 'Evergreen',
          colorValue: teamColors.first,
          captainPlayerId: before.first.playerIds.first,
        );
        await disk.archivePlayer(a);
        await disk.close();
        disk = AppDatabase.file(file);
        expect((await disk.players(includeArchived: true)).length, 2);
        expect((await disk.player(a))!.isArchived, isTrue);
        expect((await disk.session(sid))!.rotationMode, 'winner_stays');
        final after = await disk.teams(sid);
        expect(after.first.name, 'Evergreen');
        expect(after.first.captainPlayerId, before.first.playerIds.first);
        for (var i = 0; i < before.length; i++) {
          expect(after[i].playerIds, before[i].playerIds);
        }
        expect((await disk.rows('PRAGMA foreign_key_check')), isEmpty);
        expect(
          (await disk.rows('PRAGMA integrity_check')).single.values.single,
          'ok',
        );
      } finally {
        await disk.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
