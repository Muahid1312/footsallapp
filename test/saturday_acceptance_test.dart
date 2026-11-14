import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/core/storage/app_storage.dart';
import 'package:saturday_futsal/features/importing/domain/player_csv.dart';
import 'package:saturday_futsal/features/importing/data/player_import_repository.dart';
import 'package:saturday_futsal/features/teams/data/balance_repository.dart';
import 'package:saturday_futsal/features/matches/data/match_repository.dart';
import 'package:saturday_futsal/features/competitions/data/competition_repository.dart';
import 'package:saturday_futsal/features/statistics/data/statistics_repository.dart';
import 'package:saturday_futsal/features/posters/data/poster_repository.dart';
import 'package:saturday_futsal/features/posters/data/poster_renderer.dart';
import 'package:saturday_futsal/features/backup/data/backup_service.dart';
import 'support/test_clock.dart';
import 'support/test_photo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline Saturday data workflow survives poster export, backup, restore and restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
            'saturday-acceptance-',
          ),
          storage = AppStorage(root);
      var db = AppDatabase.file(File('${root.path}/saturday_futsal.sqlite'));
      try {
        final csv = CsvTable.parse(
          'First name,Last name,Position,Preferred foot\n${List.generate(9, (i) => 'Player,$i,${i < 3 ? 'Goalkeeper' : 'Winger'},Right').join('\n')}',
        );
        await PlayerImportRepository(
          db,
        ).apply(previewCsv(csv, csv.suggest(), const []));
        final photo = await testPhoto(
          File('${root.path}/player_photos/actual.png'),
        );
        final players = await db.players();
        for (final player in players) {
          await db.savePlayer(
            id: player.id,
            name: player.name,
            position: player.preferredPosition,
            photoPath: photo.path,
            skillRating: player.skillRating,
            preferredFoot: player.preferredFoot,
          );
        }
        final sid = await db.createSession(
          date: DateTime(2026, 11, 14),
          location: 'Saturday court',
          durationSeconds: 600,
          rotationMode: 'round_robin',
          playerIds: players.map((p) => p.id).toList(),
          teamCount: 3,
        );
        final balance = BalanceRepository(db),
            preview = await balance.preview(sid, seed: 17, iterations: 50);
        await balance.confirm(sid, preview);
        final teams = await db.teams(sid);
        expect(teams.every((t) => t.playerIds.length == 3), isTrue);
        expect(preview.result.metrics.every((m) => m.keepers == 1), isTrue);
        final clock = TestMatchClock(),
            engine = MatchRepository(db, clock),
            competition = CompetitionRepository(db, clock);
        final cid = await competition.create(
          sessionId: sid,
          teamIds: teams.map((t) => t.id).toList(),
          mode: 'round_robin',
          durationSeconds: 600,
          requestId: 'cup',
        );
        await expectLater(
          PosterRepository(db, competition).champions(cid),
          throwsStateError,
        );
        await competition.activate(cid, requestId: 'activate');
        final fixtures = (await competition.required(cid)).fixtures;
        for (final f in fixtures) {
          final game = (await engine.load(f.matchId))!;
          await engine.start(f.matchId, {
            game.teamA.id: game.teamA.playerIds.take(2).toList(),
            game.teamB.id: game.teamB.playerIds.take(2).toList(),
          }, requestId: 'start-${f.matchId}');
          clock.advance(10000);
          final winner =
                  teams.indexWhere((t) => t.id == game.teamA.id) <
                      teams.indexWhere((t) => t.id == game.teamB.id)
                  ? game.teamA
                  : game.teamB,
              loser = winner.id == game.teamA.id ? game.teamB : game.teamA;
          await engine.record(
            f.matchId,
            type: 'goal',
            teamId: winner.id,
            playerId: winner.playerIds.first,
            assistId: winner.playerIds[1],
            requestId: 'goal-${f.matchId}',
          );
          await engine.record(
            f.matchId,
            type: 'foul',
            teamId: loser.id,
            playerId: loser.playerIds.first,
            requestId: 'foul-${f.matchId}',
          );
          clock.advance(5000);
          await engine.finish(f.matchId, requestId: 'finish-${f.matchId}');
        }
        final standings = (await competition.required(cid)).table;
        expect(standings.first.teamId, teams.first.id);
        expect(standings.first.won, 2);
        await competition.complete(
          cid,
          reason: 'Completed Saturday cup',
          requestId: 'champion',
        );
        await db.completeSession(sid);
        final stats = StatisticsRepository(db), award = await stats.mvp(sid);
        expect(award.candidates.isNotEmpty, isTrue);
        await stats.confirmMvp(
          sid,
          playerId: award.leaders.first,
          requestId: 'mvp',
        );
        final poster = (await PosterRepository(
          db,
          competition,
        ).champions(cid)).single;
        expect(poster.teamId, teams.first.id);
        expect(poster.date, DateTime.utc(2026, 11, 14));
        expect(
          poster.players.map((p) => p.id).toSet(),
          teams.first.playerIds.toSet(),
        );
        await File(
          '${root.path}/winner.png',
        ).writeAsBytes(await PosterRenderer().render(poster));
        expect(
          await File('${root.path}/winner.png').length(),
          greaterThan(1000),
        );
        final before = (await stats.load()).matches
            .map(
              (m) =>
                  '${m.matchId}:${m.playerId}:${m.goals}:${m.assists}:${m.fouls}:${m.result}',
            )
            .toList();
        final backups = BackupService(storage),
            archive = await backups.create(db),
            ready = await backups.prepare(archive);
        await backups.activate(ready, db);
        db = AppDatabase.file(
          File(
            p.join(
              (await AppStorage(root).active()).path,
              'saturday_futsal.sqlite',
            ),
          ),
        );
        expect(
          (await StatisticsRepository(db).load()).matches
              .map(
                (m) =>
                    '${m.matchId}:${m.playerId}:${m.goals}:${m.assists}:${m.fouls}:${m.result}',
              )
              .toList(),
          before,
        );
        expect(
          (await StatisticsRepository(
            db,
          ).mvp(sid)).decisions.single['player_id'],
          award.leaders.first,
        );
        expect(
          (await db.rows(
            'SELECT champion_team_id FROM champion_decisions WHERE competition_id=?',
            [cid],
          )).single['champion_team_id'],
          teams.first.id,
        );
        await db.close();
        db = AppDatabase.file(
          File(
            p.join(
              (await AppStorage(root).active()).path,
              'saturday_futsal.sqlite',
            ),
          ),
        );
        expect((await db.players()).length, 9);
        expect(
          (await db.teams(sid)).map((t) => t.playerIds),
          teams.map((t) => t.playerIds),
        );
        expect(await db.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
