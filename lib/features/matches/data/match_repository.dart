import 'dart:convert';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';
import '../domain/match.dart';
import '../../competitions/data/competition_repository.dart';
import '../../statistics/data/statistics_repository.dart';

class MatchRepository {
  MatchRepository(this.db, this.clock);
  final AppDatabase db;
  final MatchClock clock;
  static const _uuid = Uuid();

  Future<List<MatchRecord>> forSession(String sessionId) async =>
      (await db.rows(
        'SELECT * FROM matches WHERE session_id=? ORDER BY rowid DESC',
        [sessionId],
      )).map(MatchRecord.fromRow).toList();

  Future<String> create({
    required String sessionId,
    required String teamAId,
    required String teamBId,
    required int durationSeconds,
    required String requestId,
  }) async => db.transaction(() async {
    final existing = await db.rows('SELECT * FROM matches WHERE id=?', [
      requestId,
    ]);
    if (existing.isNotEmpty) {
      final m = MatchRecord.fromRow(existing.single);
      if (m.sessionId != sessionId ||
          m.teamAId != teamAId ||
          m.teamBId != teamBId ||
          m.durationSeconds != durationSeconds) {
        throw ArgumentError(
          'This request was already used for a different match.',
        );
      }
      return requestId;
    }
    final session = await db.session(sessionId);
    if (session == null || session.status != 'planned') {
      throw StateError('Only open sessions can schedule matches.');
    }
    if (teamAId == teamBId || durationSeconds < 60 || durationSeconds > 10800) {
      throw ArgumentError('Choose different teams and 1–180 minutes.');
    }
    final teams = await db.teams(sessionId);
    for (final id in [teamAId, teamBId]) {
      final t = teams.where((t) => t.id == id).firstOrNull;
      if (t == null || t.playerIds.isEmpty) {
        throw ArgumentError('Both teams need saved rosters in this session.');
      }
    }
    await db.customStatement(
      'INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase) VALUES (?,?,?,?,?,?,?)',
      [
        requestId,
        sessionId,
        teamAId,
        teamBId,
        durationSeconds,
        'scheduled',
        'scheduled',
      ],
    );
    await db.customStatement(
      'INSERT INTO match_timer_state(match_id) VALUES (?)',
      [requestId],
    );
    return requestId;
  });

  Future<MatchBundle?> load(String id) async {
    await clock.synchronize();
    return db.transaction(() async {
      final rows = await db.rows('SELECT * FROM matches WHERE id=?', [id]);
      if (rows.isEmpty) {
        return null;
      }
      var match = MatchRecord.fromRow(rows.single);
      var timer = MatchTimerState.fromRow(
        (await db.rows('SELECT * FROM match_timer_state WHERE match_id=?', [
          id,
        ])).single,
      );
      if (match.phase == 'live' &&
          (timer.runtimeId != clock.runtimeId ||
              timer.runningSinceTickMillis == null ||
              clock.tickMillis < timer.runningSinceTickMillis!)) {
        // A new process has no trustworthy monotonic anchor. Recover a bounded
        // UTC candidate, pause, and demand explicit administrator review.
        final wallDelta = timer.runningSinceUtcMillis == null
            ? 0
            : math.max(0, clock.wallMillis - timer.runningSinceUtcMillis!);
        final candidate = (timer.accumulatedMillis + wallDelta)
            .clamp(0, match.durationSeconds * 1000)
            .toInt();
        await _saveTimer(id, candidate, running: false, recovery: true);
        await _phase(id, 'paused');
        await _action(
          _uuid.v4(),
          id,
          'recovery',
          candidate,
          '[]',
          notes:
              'Recovered paused. Review elapsed time: clock changes cannot be verified across process restarts.',
        );
        match = MatchRecord.fromRow(
          (await db.rows('SELECT * FROM matches WHERE id=?', [id])).single,
        );
        timer = MatchTimerState.fromRow(
          (await db.rows('SELECT * FROM match_timer_state WHERE match_id=?', [
            id,
          ])).single,
        );
      }
      final teams = await db.teams(match.sessionId);
      final players = await db.attendees(match.sessionId);
      final events = (await db.rows(
        '''SELECT e.*,EXISTS(SELECT 1 FROM match_actions a WHERE a.target_event_id=e.id) AS is_voided
      FROM match_events e WHERE e.match_id=? ORDER BY COALESCE(e.elapsed_millis,e.elapsed_seconds*1000),e.rowid''',
        [id],
      )).map(MatchEvent.fromRow).toList();
      final actions = (await db.rows(
        '''SELECT a.*,s.team_id,s.outgoing_player_id,s.incoming_player_id FROM match_actions a
      LEFT JOIN substitutions s ON s.id=a.id WHERE a.match_id=? ORDER BY a.rowid''',
        [id],
      )).map(MatchAction.fromRow).toList();
      final stints =
          (await db.rows(
                'SELECT * FROM match_lineup_stints WHERE match_id=? ORDER BY rowid',
                [id],
              ))
              .map(
                (r) => LineupStint(
                  r['player_id'] as String,
                  r['team_id'] as String,
                  r['entered_millis'] as int,
                  r['left_millis'] as int?,
                ),
              )
              .toList();
      return MatchBundle(
        match: match,
        timer: timer,
        teamA: teams.singleWhere((t) => t.id == match.teamAId),
        teamB: teams.singleWhere((t) => t.id == match.teamBId),
        players: players,
        events: events,
        actions: actions,
        stints: stints,
      );
    });
  }

  Future<MatchBundle> _required(String id) async {
    final match = await load(id);
    if (match == null) {
      throw StateError('Match not found.');
    }
    return match;
  }

  Future<bool> _already(String key, String matchId, String payload) async {
    final rows = await db.rows(
      'SELECT match_id,payload FROM match_actions WHERE id=?',
      [key],
    );
    if (rows.isEmpty) {
      return false;
    }
    if (rows.single['match_id'] != matchId ||
        rows.single['payload'] != payload) {
      throw ArgumentError(
        'Request key has already been used for another action.',
      );
    }
    return true;
  }

  Future<void> _action(
    String key,
    String id,
    String type,
    int elapsed,
    String payload, {
    String? eventId,
    String? target,
    String? notes,
  }) async {
    final revision = (await db.rows(
      'SELECT result_revision FROM matches WHERE id=?',
      [id],
    )).single['result_revision'];
    await db.customStatement(
      '''INSERT INTO match_actions
      (id,match_id,action_type,event_id,target_event_id,elapsed_millis,created_at,notes,payload,result_revision) VALUES (?,?,?,?,?,?,?,?,?,?)''',
      [
        key,
        id,
        type,
        eventId,
        target,
        elapsed,
        clock.wallMillis,
        notes,
        payload,
        revision,
      ],
    );
  }

  Future<void> _phase(String id, String phase) =>
      db.customStatement('UPDATE matches SET phase=?,status=? WHERE id=?', [
        phase,
        phase == 'finished'
            ? 'completed'
            : phase == 'scheduled'
            ? 'scheduled'
            : 'live',
        id,
      ]);
  Future<void> _saveTimer(
    String id,
    int elapsed, {
    required bool running,
    bool recovery = false,
  }) => db.customStatement(
    '''UPDATE match_timer_state SET
    accumulated_millis=?,running_since_utc_millis=?,running_since_tick_millis=?,runtime_id=?,recovery_required=? WHERE match_id=?''',
    [
      elapsed,
      running ? clock.wallMillis : null,
      running ? clock.tickMillis : null,
      clock.runtimeId,
      recovery ? 1 : 0,
      id,
    ],
  );
  void _open(MatchBundle b) {
    if (!b.match.isOpen) {
      throw StateError('Finished and scheduled matches cannot be changed.');
    }
  }

  void _live(MatchBundle b) {
    if (b.match.phase != 'live' || b.timer.recoveryRequired) {
      throw StateError('Start or resume the match before recording play.');
    }
    if (b.timer.elapsedMillis(b.match, clock) >=
        b.match.durationSeconds * 1000) {
      throw StateError(
        'Time has expired. Finish the match or correct existing events.',
      );
    }
  }

  Future<void> _noOtherLive(String id) async {
    if ((await db.rows(
      "SELECT id FROM matches WHERE phase='live' AND id!=? LIMIT 1",
      [id],
    )).isNotEmpty) {
      throw StateError('Pause or finish the other live match first.');
    }
  }

  Future<void> start(
    String id,
    Map<String, List<String>> starters, {
    required String requestId,
  }) async => db.transaction(() async {
    final canonical = starters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final payload = jsonEncode([
      'start',
      for (final e in canonical) [e.key, (e.value.toList()..sort())],
    ]);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    if (b.match.phase != 'scheduled') {
      throw StateError('This match has already started.');
    }
    await CompetitionRepository(db, clock).validateStart(id);
    if (starters.length != 2 ||
        !starters.keys.toSet().containsAll([b.teamA.id, b.teamB.id])) {
      throw ArgumentError('Choose both starting lineups.');
    }
    for (final team in [b.teamA, b.teamB]) {
      final ids = starters[team.id]!;
      if (ids.isEmpty ||
          ids.length > 5 ||
          ids.toSet().length != ids.length ||
          !team.playerIds.toSet().containsAll(ids)) {
        throw ArgumentError(
          'Select 1–5 unique starters from each team. The rest stay on the bench.',
        );
      }
    }
    await _noOtherLive(id);
    await _phase(id, 'live');
    await db.customStatement('UPDATE matches SET started_at=? WHERE id=?', [
      clock.wallMillis,
      id,
    ]);
    await _saveTimer(id, 0, running: true);
    for (final e in starters.entries) {
      for (final player in e.value) {
        await _enter(id, e.key, player, 0);
      }
    }
    await _action(requestId, id, 'start', 0, payload);
  });

  Future<void> pause(String id, {required String requestId}) async =>
      db.transaction(() async {
        final payload = jsonEncode(['pause']);
        if (await _already(requestId, id, payload)) {
          return;
        }
        final b = await _required(id);
        if (b.match.phase != 'live') {
          throw StateError('Only a live match can be paused.');
        }
        final elapsed = b.timer.elapsedMillis(b.match, clock);
        await _saveTimer(id, elapsed, running: false);
        await _phase(id, 'paused');
        await _action(requestId, id, 'pause', elapsed, payload);
      });
  Future<void> resume(
    String id, {
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode(['resume']);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    if (b.match.phase != 'paused' || b.timer.recoveryRequired) {
      throw StateError('Review the recovered timer before resuming.');
    }
    await CompetitionRepository(db, clock).validateStart(id);
    if (b.match.resultRevision > 0) {
      throw StateError(
        'A result review cannot resume playing time. Save the corrected final result instead.',
      );
    }
    if (b.timer.accumulatedMillis >= b.match.durationSeconds * 1000) {
      throw StateError('Time has expired. Finish the match.');
    }
    if (b.onField(b.teamA.id).isEmpty || b.onField(b.teamB.id).isEmpty) {
      throw StateError(
        'Legacy match has no recoverable lineup. Finish it and schedule a new match.',
      );
    }
    await _noOtherLive(id);
    await _saveTimer(id, b.timer.accumulatedMillis, running: true);
    await _phase(id, 'live');
    await _action(requestId, id, 'resume', b.timer.accumulatedMillis, payload);
  });
  Future<void> checkpoint(String id) async => db.transaction(() async {
    final b = await _required(id);
    if (b.match.phase == 'live') {
      await _saveTimer(
        id,
        b.timer.elapsedMillis(b.match, clock),
        running: true,
      );
    }
  });
  Future<void> checkpointRunning() async {
    final ids = await db.rows("SELECT id FROM matches WHERE phase='live'");
    for (final row in ids) {
      await checkpoint(row['id'] as String);
    }
  }

  Future<void> reviewTimer(
    String id,
    int elapsedMillis, {
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode(['timer_review', elapsedMillis]);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    if (b.match.phase != 'paused' || !b.timer.recoveryRequired) {
      throw StateError('This timer does not need recovery review.');
    }
    // Never move the clock behind recorded play or a substitution.
    final minimum = b.actions
        .where((a) => ['record', 'substitution', 'correction'].contains(a.type))
        .fold<int>(0, (v, a) => math.max(v, a.elapsedMillis));
    if (elapsedMillis < minimum ||
        elapsedMillis > b.match.durationSeconds * 1000) {
      throw ArgumentError(
        'Elapsed time must be between ${matchTime(minimum, countdown: true)} and ${matchTime(b.match.durationSeconds * 1000)}.',
      );
    }
    await _saveTimer(id, elapsedMillis, running: false);
    await _action(
      requestId,
      id,
      'timer_review',
      elapsedMillis,
      payload,
      notes:
          'Administrator reviewed recovered elapsed time (previous candidate ${matchTime(b.timer.accumulatedMillis)}).',
    );
  });

  void _participant(MatchBundle b, String team, String player, int time) {
    if (![b.teamA.id, b.teamB.id].contains(team) ||
        !b.stints.any(
          (s) => s.teamId == team && s.playerId == player && s.contains(time),
        )) {
      throw ArgumentError(
        'Select a player who participated for this team at the event time.',
      );
    }
  }

  Future<String> record(
    String id, {
    required String type,
    required String teamId,
    required String playerId,
    String? assistId,
    String? notes,
    int? occurredAtMillis,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([
      'record',
      type,
      teamId,
      playerId,
      assistId,
      notes?.trim(),
      occurredAtMillis,
    ]);
    if (await _already(requestId, id, payload)) {
      return 'event-$requestId';
    }
    final b = await _required(id);
    if (occurredAtMillis == null) {
      _live(b);
    } else if (b.match.phase != 'live' || b.timer.recoveryRequired) {
      throw StateError('Pending play can only be confirmed in its live match.');
    }
    if (!['goal', 'foul'].contains(type)) {
      throw ArgumentError('Choose a goal or player foul.');
    }
    final currentElapsed = b.timer.elapsedMillis(b.match, clock);
    final elapsed = occurredAtMillis ?? currentElapsed;
    if (elapsed < 0 ||
        elapsed > currentElapsed ||
        elapsed >= b.match.durationSeconds * 1000) {
      throw ArgumentError(
        'The event must have been observed during playing time.',
      );
    }
    _participant(b, teamId, playerId, elapsed);
    if (occurredAtMillis == null &&
        !b.onField(teamId).any((p) => p.id == playerId)) {
      throw ArgumentError(
        'The scorer or offender must currently be on the pitch.',
      );
    }
    if (assistId != null) {
      if (type != 'goal' || assistId == playerId) {
        throw ArgumentError('An assist needs a different teammate.');
      }
      _participant(b, teamId, assistId, elapsed);
      if (occurredAtMillis == null &&
          !b.onField(teamId).any((p) => p.id == assistId)) {
        throw ArgumentError('The assister must be on the pitch.');
      }
    }
    if ((notes?.length ?? 0) > 300) {
      throw ArgumentError('Keep notes within 300 characters.');
    }
    final event = 'event-$requestId';
    await _insertEvent(event, id, teamId, playerId, assistId, type, elapsed);
    await _action(
      requestId,
      id,
      'record',
      elapsed,
      payload,
      eventId: event,
      notes: notes?.trim(),
    );
    await _saveTimer(id, b.timer.elapsedMillis(b.match, clock), running: true);
    return event;
  });
  Future<void> _insertEvent(
    String event,
    String match,
    String team,
    String player,
    String? assist,
    String type,
    int elapsed,
  ) => db.customStatement(
    '''INSERT INTO match_events(id,match_id,team_id,player_id,related_player_id,event_type,elapsed_seconds,created_at,elapsed_millis)
      VALUES (?,?,?,?,?,?,?,?,?)''',
    [
      event,
      match,
      team,
      player,
      assist,
      type,
      elapsed ~/ 1000,
      clock.wallMillis,
      elapsed,
    ],
  );

  Future<void> undo(
    String id,
    String eventId, {
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode(['undo', eventId, reason.trim()]);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    _open(b);
    final event = b.events.where((e) => e.id == eventId).firstOrNull;
    if (event == null ||
        event.isVoided ||
        !['goal', 'foul'].contains(event.type)) {
      throw StateError('This event is already voided or cannot be undone.');
    }
    if (reason.trim().isEmpty || reason.length > 300) {
      throw ArgumentError('Enter a correction reason (up to 300 characters).');
    }
    await _action(
      requestId,
      id,
      'undo',
      b.timer.elapsedMillis(b.match, clock),
      payload,
      target: eventId,
      notes: reason.trim(),
    );
  });
  Future<void> correctGoal(
    String id,
    String eventId, {
    required String playerId,
    String? assistId,
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([
      'correction',
      eventId,
      playerId,
      assistId,
      reason.trim(),
    ]);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    _open(b);
    final event = b.events.where((e) => e.id == eventId).firstOrNull;
    if (event == null || event.isVoided || event.type != 'goal') {
      throw StateError('Choose an active goal to correct.');
    }
    if (reason.trim().isEmpty || reason.length > 300) {
      throw ArgumentError('Enter a correction reason (up to 300 characters).');
    }
    _participant(b, event.teamId, playerId, event.elapsedMillis);
    if (assistId == playerId) {
      throw ArgumentError('The scorer cannot assist their own goal.');
    }
    if (assistId != null) {
      _participant(b, event.teamId, assistId, event.elapsedMillis);
    }
    final replacement = 'event-$requestId';
    await _insertEvent(
      replacement,
      id,
      event.teamId,
      playerId,
      assistId,
      'goal',
      event.elapsedMillis,
    );
    await _action(
      requestId,
      id,
      'correction',
      b.timer.elapsedMillis(b.match, clock),
      payload,
      eventId: replacement,
      target: eventId,
      notes: reason.trim(),
    );
  });

  Future<void> _enter(
    String id,
    String team,
    String player,
    int time,
  ) => db.customStatement(
    'INSERT INTO match_lineup_stints(id,match_id,team_id,player_id,entered_millis) VALUES (?,?,?,?,?)',
    [_uuid.v4(), id, team, player, time],
  );
  Future<void> substitute(
    String id, {
    required String teamId,
    required String outgoingId,
    required String incomingId,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([
      'substitution',
      teamId,
      outgoingId,
      incomingId,
    ]);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    _live(b);
    final team = [b.teamA, b.teamB].where((t) => t.id == teamId).firstOrNull;
    if (team == null ||
        outgoingId == incomingId ||
        !team.playerIds.contains(incomingId) ||
        !b.onField(teamId).any((p) => p.id == outgoingId) ||
        b.onField(teamId).any((p) => p.id == incomingId)) {
      throw ArgumentError(
        'Choose an on-field player and a benched player from the same team.',
      );
    }
    final elapsed = b.timer.elapsedMillis(b.match, clock);
    await db.customStatement(
      'UPDATE match_lineup_stints SET left_millis=? WHERE match_id=? AND player_id=? AND left_millis IS NULL',
      [elapsed, id, outgoingId],
    );
    await _enter(id, teamId, incomingId, elapsed);
    await _action(requestId, id, 'substitution', elapsed, payload);
    await db.customStatement('INSERT INTO substitutions VALUES (?,?,?,?,?,?)', [
      requestId,
      id,
      teamId,
      outgoingId,
      incomingId,
      elapsed,
    ]);
    await _saveTimer(id, b.timer.elapsedMillis(b.match, clock), running: true);
  });
  Future<void> finish(
    String id, {
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode(['finish']);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    _open(b);
    if (b.timer.recoveryRequired) {
      throw StateError('Review the recovered timer before finishing.');
    }
    final elapsed = b.timer.elapsedMillis(b.match, clock);
    await db.customStatement(
      'UPDATE match_lineup_stints SET left_millis=? WHERE match_id=? AND left_millis IS NULL',
      [elapsed, id],
    );
    await _saveTimer(id, elapsed, running: false);
    await db.customStatement('UPDATE matches SET ended_at=? WHERE id=?', [
      b.match.resultRevision > 0
          ? b.match.endedAt
          : b.match.startedAt == null
          ? null
          : math.max(clock.wallMillis, b.match.startedAt!),
      id,
    ]);
    await _phase(id, 'finished');
    await _action(
      requestId,
      id,
      'finish',
      elapsed,
      payload,
      notes: b.match.resultRevision > 0
          ? 'Corrected final result revision ${b.match.resultRevision}'
          : null,
    );
    await CompetitionRepository(db, clock).onMatchFinished(id);
  });

  Future<void> addCorrectionGoal(
    String id, {
    required String teamId,
    required String playerId,
    String? assistId,
    required int elapsedMillis,
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([
      'missing_goal',
      teamId,
      playerId,
      assistId,
      elapsedMillis,
      reason.trim(),
    ]);
    if (await _already(requestId, id, payload)) {
      return;
    }
    final b = await _required(id);
    if (b.match.phase != 'paused' || b.match.resultRevision == 0) {
      throw StateError(
        'Reopen a competition result explicitly before adding a missing goal.',
      );
    }
    if (reason.trim().isEmpty ||
        reason.length > 300 ||
        elapsedMillis < 0 ||
        elapsedMillis > b.timer.accumulatedMillis) {
      throw ArgumentError(
        'Enter a valid original goal time and correction reason.',
      );
    }
    _participant(b, teamId, playerId, elapsedMillis);
    if (assistId == playerId) {
      throw ArgumentError('Scorer cannot assist their own goal.');
    }
    if (assistId != null) {
      _participant(b, teamId, assistId, elapsedMillis);
    }
    final event = 'event-$requestId';
    await _insertEvent(
      event,
      id,
      teamId,
      playerId,
      assistId,
      'goal',
      elapsedMillis,
    );
    await _action(
      requestId,
      id,
      'record',
      elapsedMillis,
      payload,
      eventId: event,
      notes: 'Result correction: ${reason.trim()}',
    );
  });

  Future<Map<String, int>> career(String playerId) async {
    final c = (await StatisticsRepository(db).load()).career(playerId);
    return {
      'appearances': c.appearances,
      'goals': c.goals,
      'assists': c.assists,
      'fouls': c.fouls,
    };
  }

  Future<MatchBundle?> recentFinished() async {
    final rows = await db.rows(
      "SELECT m.id FROM matches m WHERE m.phase='finished' ORDER BY COALESCE(m.ended_at,(SELECT MAX(a.created_at) FROM match_actions a WHERE a.match_id=m.id AND a.action_type='finish'),0) DESC,m.rowid DESC LIMIT 1",
    );
    if (rows.isEmpty) {
      return null;
    }
    return load(rows.single['id'] as String);
  }
}
