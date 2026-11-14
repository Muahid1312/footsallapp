import '../../players/domain/player.dart';

class StatisticsScope {
  const StatisticsScope({this.sessionId, this.recentSessions});
  final String? sessionId;
  final int? recentSessions;
  @override
  bool operator ==(Object other) =>
      other is StatisticsScope &&
      sessionId == other.sessionId &&
      recentSessions == other.recentSessions;
  @override
  int get hashCode => Object.hash(sessionId, recentSessions);
}

class PlayerMatchStatistics {
  PlayerMatchStatistics(this.row);
  final Map<String, dynamic> row;
  String get playerId => row['player_id'] as String;
  String get matchId => row['match_id'] as String;
  String get sessionId => row['session_id'] as String;
  String get teamName => row['team_name'] as String;
  DateTime get date => DateTime.fromMillisecondsSinceEpoch(
    row['session_date'] as int,
    isUtc: true,
  );
  int get goals => row['goals'] as int;
  int get assists => row['assists'] as int;
  int get fouls => row['fouls'] as int;
  int get playingMillis => row['playing_millis'] as int;
  int get goalsFor => row['goals_for'] as int;
  int get goalsAgainst => row['goals_against'] as int;
  String get result => goalsFor > goalsAgainst
      ? 'W'
      : goalsFor == goalsAgainst
      ? 'D'
      : 'L';
}

class CareerStatistics {
  CareerStatistics(this.playerId, this.matches);
  final String playerId;
  final List<PlayerMatchStatistics> matches;
  int get appearances => matches.length;
  int get goals => matches.fold(0, (v, m) => v + m.goals);
  int get assists => matches.fold(0, (v, m) => v + m.assists);
  int get fouls => matches.fold(0, (v, m) => v + m.fouls);
  int get wins => matches.where((m) => m.result == 'W').length;
  int get draws => matches.where((m) => m.result == 'D').length;
  int get losses => matches.where((m) => m.result == 'L').length;
  double? get goalsPerMatch => appearances == 0 ? null : goals / appearances;
  double? get assistsPerMatch =>
      appearances == 0 ? null : assists / appearances;
  Map<String, int> get counts => {
    'appearances': appearances,
    'goals': goals,
    'assists': assists,
    'fouls': fouls,
    'wins': wins,
    'draws': draws,
    'losses': losses,
  };
}

class LeaderboardEntry {
  LeaderboardEntry(this.player, this.stats, this.position, this.value);
  final Player player;
  final CareerStatistics stats;
  final int position;
  final double value;
}

class StatisticsBundle {
  StatisticsBundle(this.players, this.matches) {
    for (final match in matches) {
      (_matchesByPlayer[match.playerId] ??= []).add(match);
    }
  }
  final List<Player> players;
  final List<PlayerMatchStatistics> matches;
  final _matchesByPlayer = <String, List<PlayerMatchStatistics>>{};
  CareerStatistics career(String id) =>
      CareerStatistics(id, _matchesByPlayer[id] ?? const []);
  List<LeaderboardEntry> leaderboard(
    String metric, {
    int minimumAppearances = 3,
  }) {
    if (![
          'goals',
          'assists',
          'appearances',
          'wins',
          'goals_per_match',
          'assists_per_match',
        ].contains(metric) ||
        minimumAppearances < 1 ||
        minimumAppearances > 1000) {
      throw ArgumentError(
        'Choose a leaderboard and minimum appearances from 1–1000.',
      );
    }
    final rated = <({Player player, CareerStatistics stats, double value})>[];
    for (final p in players) {
      final s = career(p.id);
      if (s.appearances == 0) {
        continue;
      }
      if (metric.endsWith('_per_match') && s.appearances < minimumAppearances) {
        continue;
      }
      final value = switch (metric) {
        'goals_per_match' => s.goalsPerMatch!,
        'assists_per_match' => s.assistsPerMatch!,
        _ => s.counts[metric]!.toDouble(),
      };
      rated.add((player: p, stats: s, value: value));
    }
    rated.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) {
        return cmp;
      }
      final name = a.player.name.toLowerCase().compareTo(
        b.player.name.toLowerCase(),
      );
      return name != 0 ? name : a.player.id.compareTo(b.player.id);
    });
    final result = <LeaderboardEntry>[];
    for (var i = 0; i < rated.length; i++) {
      final position = i > 0 && rated[i].value == rated[i - 1].value
          ? result.last.position
          : i + 1;
      result.add(
        LeaderboardEntry(
          rated[i].player,
          rated[i].stats,
          position,
          rated[i].value,
        ),
      );
    }
    return result;
  }
}

class MvpWeights {
  const MvpWeights({
    this.goal = 4,
    this.assist = 3,
    this.win = 2,
    this.foul = -1,
  });
  final int goal, assist, win, foul;
  Map<String, int> toJson() => {
    'goal': goal,
    'assist': assist,
    'win': win,
    'foul': foul,
  };
}

class MvpCandidate {
  MvpCandidate(this.player, this.stats, this.weights);
  final Player player;
  final CareerStatistics stats;
  final MvpWeights weights;
  Map<String, int> get breakdown => {
    'goals': stats.goals * weights.goal,
    'assists': stats.assists * weights.assist,
    'wins': stats.wins * weights.win,
    'fouls': stats.fouls * weights.foul,
  };
  int get score => breakdown.values.fold(0, (v, s) => v + s);
  Map<String, Object> toJson() => {
    'player_id': player.id,
    'name': player.name,
    'score': score,
    'breakdown': breakdown,
    'statistics': stats.counts,
  };
}

class SessionMvp {
  SessionMvp(this.weights, this.candidates, this.decisions);
  final MvpWeights weights;
  final List<MvpCandidate> candidates;
  final List<Map<String, dynamic>> decisions;
  List<String> get leaders => candidates.isEmpty
      ? []
      : candidates
            .where((c) => c.score == candidates.first.score)
            .map((c) => c.player.id)
            .toList();
}
