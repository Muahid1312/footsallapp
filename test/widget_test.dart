import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/app/app.dart';
import 'package:saturday_futsal/app/providers.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/routing/app_router.dart';
import 'package:saturday_futsal/core/utilities/dates.dart';
import 'package:saturday_futsal/core/widgets/common.dart';
import 'package:saturday_futsal/features/players/domain/player.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'support/test_clock.dart';
import 'package:saturday_futsal/features/statistics/data/statistics_repository.dart';
import 'package:saturday_futsal/features/competitions/data/competition_repository.dart';
import 'package:saturday_futsal/features/settings/data/settings_repository.dart';

void main() {
  testWidgets('settings persist match defaults and new sessions load them', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    appRouter.go('/settings');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          matchClockProvider.overrideWithValue(TestMatchClock()),
        ],
        child: const SaturdayFutsalApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Match minutes'),
      '15',
    );
    await tester.scrollUntilVisible(
      find.text('Save defaults'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save defaults'));
    await tester.pumpAndSettle();
    expect((await SettingsRepository(db).load()).minutes, 15);
    appRouter.go('/sessions/new');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Match minutes'),
          )
          .controller!
          .text,
      '15',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  test('next Saturday includes today and crosses month boundaries', () {
    expect(nextSaturday(DateTime(2026, 11, 14, 18)), DateTime(2026, 11, 14));
    expect(nextSaturday(DateTime(2026, 11, 29)), DateTime(2026, 12, 5));
  });
  testWidgets(
    'dashboard launches, registers player, and displays persisted profile',
    (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      appRouter.go('/');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const SaturdayFutsalApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Same friends.\nNew game.'), findsOneWidget);
      appRouter.push('/players/new');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Player name'),
        'New teammate',
      );
      await tester.scrollUntilVisible(
        find.text('Save player'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save player'));
      await tester.pumpAndSettle();
      expect((await db.players()).single.name, 'New teammate');
      appRouter.go('/players');
      await tester.pumpAndSettle();
      expect(find.text('New teammate'), findsOneWidget);
      await tester.tap(find.text('New teammate'));
      await tester.pumpAndSettle();
      expect(find.text('Career statistics'), findsOneWidget);
      expect(find.textContaining('Career totals appear after'), findsOneWidget);
    },
  );
  testWidgets('creates a session and persists a team identity edit', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    for (var i = 0; i < 5; i++) {
      await db.savePlayer(name: 'Squad $i', position: 'Winger', skillRating: 5);
    }
    appRouter.go('/sessions/new');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
        child: const SaturdayFutsalApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Select all'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Create session & generate teams'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Create session & generate teams'));
    await tester.pumpAndSettle();
    final session = (await db.sessions()).single;
    final teams = await db.teams(session.id);
    expect(teams.map((t) => t.playerIds.length).toList()..sort(), [2, 3]);
    expect(teams.expand((t) => t.playerIds).toSet().length, 5);
    await tester.scrollUntilVisible(
      find.byTooltip('Edit Team 1'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('Edit Team 1'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Team name'),
      'Emerald United',
    );
    await tester.tap(find.text('Save team'));
    await tester.pumpAndSettle();
    expect((await db.teams(session.id)).first.name, 'Emerald United');
    appRouter.go('/sessions/${session.id}');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Emerald United'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Emerald United'), findsOneWidget);
  });

  testWidgets('missing photo falls back to player initials', (tester) async {
    final now = DateTime(2026);
    final player = Player(
      id: 'photo',
      name: 'Ahmad Khan',
      photoPath: '/missing/player.jpg',
      preferredPosition: 'Pivot',
      skillRating: 5,
      createdAt: now,
      updatedAt: now,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerAvatar(player))),
    );
    await tester.pumpAndSettle();
    expect(find.text('AK'), findsOneWidget);
  });
  testWidgets(
    'Match Center starts, records a goal, and reopens a final summary',
    (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final clock = TestMatchClock();
      final repo = MatchRepository(db, clock);
      final players = <String>[];
      for (var i = 0; i < 6; i++) {
        players.add(
          await db.savePlayer(
            name: 'Match player $i',
            position: 'Winger',
            skillRating: 5,
          ),
        );
      }
      final session = await db.createSession(
        date: DateTime(2026, 11, 14),
        location: 'Court',
        durationSeconds: 600,
        rotationMode: 'round_robin',
        playerIds: players,
        teamCount: 2,
      );
      final teams = await db.teams(session);
      final id = await repo.create(
        sessionId: session,
        teamAId: teams.first.id,
        teamBId: teams.last.id,
        durationSeconds: 600,
        requestId: 'ui-match',
      );
      appRouter.go('/matches/$id');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            matchClockProvider.overrideWithValue(clock),
          ],
          child: const SaturdayFutsalApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Select lineups & start'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Select lineups & start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start match'));
      await tester.pumpAndSettle();
      clock.advance(12000);
      await tester.scrollUntilVisible(
        find.text('Goal'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Goal'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Scorer'),
      );
      await tester.pumpAndSettle();
      final scorer = (await db.player(teams.first.playerIds.first))!;
      await tester.tap(find.text(scorer.name).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect((await repo.load(id))!.score(teams.first.id), 1);
      await tester.scrollUntilVisible(
        find.text('Finish match'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Finish match'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Finish match'));
      await tester.pumpAndSettle();
      expect((await repo.load(id))!.match.phase, 'finished');
      appRouter.go('/matches/$id/summary');
      await tester.pumpAndSettle();
      expect(find.text('Match summary'), findsOneWidget);
      expect(find.text('${teams.first.name} win'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'competition dashboard generates fixtures and opens the existing Match Center',
    (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final clock = TestMatchClock();
      final players = <String>[];
      for (var i = 0; i < 6; i++) {
        players.add(
          await db.savePlayer(
            name: 'Squad $i',
            position: 'Winger',
            skillRating: 5,
          ),
        );
      }
      final sid = await db.createSession(
        date: DateTime(2026, 11, 14),
        location: 'Court',
        durationSeconds: 600,
        rotationMode: 'round_robin',
        playerIds: players,
        teamCount: 3,
      );
      final repo = CompetitionRepository(db, clock);
      final id = await repo.create(
        sessionId: sid,
        teamIds: (await db.teams(sid)).map((t) => t.id).toList(),
        mode: 'round_robin',
        durationSeconds: 600,
        requestId: 'ui-competition',
      );
      appRouter.go('/competitions/$id');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            matchClockProvider.overrideWithValue(clock),
          ],
          child: const SaturdayFutsalApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Generate fixtures & activate'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Generate fixtures & activate'));
      await tester.pumpAndSettle();
      expect((await repo.required(id)).fixtures.length, 3);
      final next = (await repo.required(id)).fixtures.first;
      final b = await repo.required(id);
      await tester.scrollUntilVisible(
        find.text('Next: ${b.teamName(next.a)} vs ${b.teamName(next.b)}'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.text('Next: ${b.teamName(next.a)} vs ${b.teamName(next.b)}'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Match Center'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'session leaderboard, career analytics, and final MVP use persisted match data',
    (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final clock = TestMatchClock();
      final engine = MatchRepository(db, clock),
          stats = StatisticsRepository(db);
      final ids = <String>[];
      for (var i = 0; i < 6; i++) {
        ids.add(
          await db.savePlayer(
            name: 'Career player $i',
            position: 'Winger',
            skillRating: 5,
          ),
        );
      }
      final sid = await db.createSession(
        date: DateTime(2026, 11, 14),
        location: 'Court',
        durationSeconds: 600,
        rotationMode: 'round_robin',
        playerIds: ids,
        teamCount: 2,
      );
      final teams = await db.teams(sid),
          scorer = teams.first.playerIds.first,
          bench = teams.first.playerIds.last;
      final mid = await engine.create(
        sessionId: sid,
        teamAId: teams.first.id,
        teamBId: teams.last.id,
        durationSeconds: 600,
        requestId: 'stats-game',
      );
      await engine.start(mid, {
        for (final t in teams) t.id: t.playerIds.take(2).toList(),
      }, requestId: 'stats-start');
      clock.advance(10000);
      await engine.record(
        mid,
        type: 'goal',
        teamId: teams.first.id,
        playerId: scorer,
        requestId: 'stats-goal',
      );
      await engine.finish(mid, requestId: 'stats-finish');
      await db.completeSession(sid);
      appRouter.go('/statistics?session=$sid');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            matchClockProvider.overrideWithValue(clock),
          ],
          child: const SaturdayFutsalApp(),
        ),
      );
      await tester.pumpAndSettle();
      final name = (await db.player(scorer))!.name,
          benchName = (await db.player(bench))!.name;
      await tester.scrollUntilVisible(
        find.text(name),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(benchName), findsNothing);
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
      expect(find.text('Career & history'), findsOneWidget);
      appRouter.go('/sessions/$sid/mvp');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Confirm award'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Confirm award'));
      await tester.pumpAndSettle();
      expect((await stats.mvp(sid)).decisions.single['player_id'], scorer);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
