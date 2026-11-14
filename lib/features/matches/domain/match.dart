import 'dart:math' as math;
import '../../players/domain/player.dart';
import '../../teams/domain/team.dart';

abstract interface class MatchClock {
  int get wallMillis;
  int get tickMillis;
  String get runtimeId;
  Future<void> synchronize();
}

class MatchRecord {
  const MatchRecord({
    required this.id,
    required this.sessionId,
    required this.teamAId,
    required this.teamBId,
    required this.durationSeconds,
    required this.phase,
    this.resultRevision = 0,
    this.startedAt,
    this.endedAt,
  });
  final String id, sessionId, teamAId, teamBId, phase;
  final int durationSeconds;
  final int resultRevision;
  final int? startedAt, endedAt;
  bool get isOpen => phase == 'live' || phase == 'paused';
  bool get isFinal => phase == 'finished' || phase == 'cancelled';
  factory MatchRecord.fromRow(Map<String, dynamic> r) => MatchRecord(
    id: r['id'] as String,
    sessionId: r['session_id'] as String,
    teamAId: r['team_a_id'] as String,
    teamBId: r['team_b_id'] as String,
    durationSeconds: r['duration_seconds'] as int,
    phase: r['phase'] as String,
    resultRevision: (r['result_revision'] as int?) ?? 0,
    startedAt: r['started_at'] as int?,
    endedAt: r['ended_at'] as int?,
  );
}

class MatchTimerState {
  const MatchTimerState({
    required this.accumulatedMillis,
    required this.recoveryRequired,
    this.runningSinceUtcMillis,
    this.runningSinceTickMillis,
    this.runtimeId,
  });
  final int accumulatedMillis;
  final int? runningSinceUtcMillis, runningSinceTickMillis;
  final String? runtimeId;
  final bool recoveryRequired;
  factory MatchTimerState.fromRow(Map<String, dynamic> r) => MatchTimerState(
    accumulatedMillis: r['accumulated_millis'] as int,
    runningSinceUtcMillis: r['running_since_utc_millis'] as int?,
    runningSinceTickMillis: r['running_since_tick_millis'] as int?,
    runtimeId: r['runtime_id'] as String?,
    recoveryRequired: r['recovery_required'] == 1,
  );
  int elapsedMillis(MatchRecord match, MatchClock clock) {
    final delta =
        match.phase == 'live' &&
            runtimeId == clock.runtimeId &&
            runningSinceTickMillis != null
        ? math.max(0, clock.tickMillis - runningSinceTickMillis!)
        : 0;
    return (accumulatedMillis + delta)
        .clamp(0, match.durationSeconds * 1000)
        .toInt();
  }
}

class MatchEvent {
  const MatchEvent({
    required this.id,
    required this.teamId,
    required this.type,
    required this.elapsedMillis,
    this.playerId,
    this.assistId,
    required this.isVoided,
  });
  final String id, teamId, type;
  final String? playerId, assistId;
  final int elapsedMillis;
  final bool isVoided;
  factory MatchEvent.fromRow(Map<String, dynamic> r) => MatchEvent(
    id: r['id'] as String,
    teamId: r['team_id'] as String,
    type: r['event_type'] as String,
    playerId: r['player_id'] as String?,
    assistId: r['related_player_id'] as String?,
    elapsedMillis:
        (r['elapsed_millis'] ?? (r['elapsed_seconds'] as int) * 1000) as int,
    isVoided: r['is_voided'] == 1,
  );
}

class LineupStint {
  const LineupStint(
    this.playerId,
    this.teamId,
    this.enteredMillis,
    this.leftMillis,
  );
  final String playerId, teamId;
  final int enteredMillis;
  final int? leftMillis;
  bool get onField => leftMillis == null;
  bool contains(int time) =>
      enteredMillis <= time && (leftMillis == null || leftMillis! >= time);
}

class MatchAction {
  const MatchAction({
    required this.id,
    required this.type,
    required this.elapsedMillis,
    required this.createdAt,
    this.eventId,
    this.targetEventId,
    this.notes,
    this.teamId,
    this.outgoingId,
    this.incomingId,
  });
  final String id, type;
  final int elapsedMillis, createdAt;
  final String? eventId, targetEventId, notes, teamId, outgoingId, incomingId;
  factory MatchAction.fromRow(Map<String, dynamic> r) => MatchAction(
    id: r['id'] as String,
    type: r['action_type'] as String,
    elapsedMillis: r['elapsed_millis'] as int,
    createdAt: r['created_at'] as int,
    eventId: r['event_id'] as String?,
    targetEventId: r['target_event_id'] as String?,
    notes: r['notes'] as String?,
    teamId: r['team_id'] as String?,
    outgoingId: r['outgoing_player_id'] as String?,
    incomingId: r['incoming_player_id'] as String?,
  );
}

class MatchBundle {
  const MatchBundle({
    required this.match,
    required this.timer,
    required this.teamA,
    required this.teamB,
    required this.players,
    required this.events,
    required this.actions,
    required this.stints,
  });
  final MatchRecord match;
  final MatchTimerState timer;
  final SessionTeam teamA, teamB;
  final List<Player> players;
  final List<MatchEvent> events;
  final List<MatchAction> actions;
  final List<LineupStint> stints;
  Iterable<MatchEvent> get activeEvents => events.where((e) => !e.isVoided);
  int score(String teamId) => activeEvents
      .where(
        (e) =>
            e.type == 'goal' && e.teamId == teamId ||
            e.type == 'own_goal' && e.teamId != teamId,
      )
      .length;
  int fouls(String teamId) =>
      activeEvents.where((e) => e.type == 'foul' && e.teamId == teamId).length;
  List<Player> onField(String teamId) => players
      .where(
        (p) => stints.any(
          (s) => s.teamId == teamId && s.playerId == p.id && s.onField,
        ),
      )
      .toList();
  Player? player(String? id) => players.where((p) => p.id == id).firstOrNull;
  String playerName(String? id) => player(id)?.name ?? 'Unattributed player';
  String teamName(String? id) => id == teamA.id
      ? teamA.name
      : id == teamB.id
      ? teamB.name
      : 'Match';
  String get result => score(teamA.id) == score(teamB.id)
      ? 'Draw'
      : '${score(teamA.id) > score(teamB.id) ? teamA.name : teamB.name} win';
}

String matchTime(int millis, {bool countdown = false}) {
  final seconds = countdown ? (millis / 1000).ceil() : millis ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
