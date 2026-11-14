import 'dart:math';
import '../../players/domain/player.dart';

enum PosterStyle { championsNight, matchdayVictory, minimalElite }

extension PosterStyleLabel on PosterStyle {
  String get label => switch (this) {
    PosterStyle.championsNight => 'Champions Night',
    PosterStyle.matchdayVictory => 'Matchday Victory',
    PosterStyle.minimalElite => 'Minimal Elite',
  };
}

class WinnerPoster {
  WinnerPoster({
    required this.competitionId,
    required this.sessionId,
    required this.date,
    required this.teamId,
    required this.teamName,
    required this.teamColor,
    required this.players,
    required this.summary,
    this.shared = false,
  });
  final String competitionId, sessionId, teamId, teamName, summary;
  final DateTime date;
  final int teamColor;
  final List<Player> players;
  final bool shared;
  List<List<Player>> pages({bool story = false, List<String>? order}) {
    final ids = order ?? players.map((p) => p.id).toList();
    if (ids.length != players.length ||
        ids.toSet().length != players.length ||
        ids.any((id) => !players.any((p) => p.id == id))) {
      throw ArgumentError(
        'Poster order must contain every champion-team player exactly once.',
      );
    }
    final sorted = ids
            .map((id) => players.singleWhere((p) => p.id == id))
            .toList(),
        capacity = story ? 15 : 9;
    return [
      for (var i = 0; i < sorted.length; i += capacity)
        sorted.sublist(i, min(i + capacity, sorted.length)),
    ];
  }
}
