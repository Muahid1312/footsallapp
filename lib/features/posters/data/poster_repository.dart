import 'dart:convert';
import '../../../core/database/app_database.dart';
import '../../competitions/data/competition_repository.dart';
import '../domain/winner_poster.dart';

class PosterRepository {
  PosterRepository(this.db, this.competitions);
  final AppDatabase db;
  final CompetitionRepository competitions;
  Future<List<WinnerPoster>> champions(String id) => db.transaction(() async {
    final b = await competitions.required(id), decision = b.decision;
    if (b.competition.status != 'completed' || decision == null) {
      throw StateError(
        'Confirm the competition champion before creating a winner poster.',
      );
    }
    final session = await db.session(b.competition.sessionId);
    if (session == null) {
      throw StateError('Saturday session not found.');
    }
    final shared = decision['champion_team_id'] == null;
    final selected = shared
        ? List<String>.from(
            jsonDecode(decision['tied_teams_json'] as String) as List,
          )
        : [decision['champion_team_id'] as String];
    final players = await db.players(includeArchived: true);
    return selected.map((id) {
      final team = b.teams.singleWhere((t) => t.id == id),
          standing = b.table.singleWhere((s) => s.teamId == id);
      final members = team.playerIds
          .map((id) => players.singleWhere((p) => p.id == id))
          .toList();
      if (members.isEmpty) {
        throw StateError('This confirmed champion has no saved roster.');
      }
      return WinnerPoster(
        competitionId: b.competition.id,
        sessionId: session.id,
        date: session.date,
        teamId: id,
        teamName: team.name,
        teamColor: team.colorValue,
        players: members,
        shared: shared,
        summary:
            '${standing.played} played · ${standing.won} wins · ${standing.points} points · ${standing.goalsFor} goals',
      );
    }).toList();
  });
}
