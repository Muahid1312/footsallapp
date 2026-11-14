import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';
import '../domain/statistics.dart';

class StatisticsRepository {
  StatisticsRepository(this.db);
  final AppDatabase db;
  Future<StatisticsBundle> load([
    StatisticsScope scope = const StatisticsScope(),
  ]) async => db.transaction(() async {
    if (scope.sessionId != null && scope.recentSessions != null) {
      throw ArgumentError('Choose a session or recent sessions, not both.');
    }
    String clause = '';
    final args = <Object?>[];
    if (scope.sessionId != null) {
      clause = 'WHERE session_id=?';
      args.add(scope.sessionId);
    }
    if (scope.recentSessions != null) {
      final n = scope.recentSessions!;
      if (n < 1 || n > 20) {
        throw ArgumentError('Use 1–20 recent played sessions.');
      }
      clause =
          '''WHERE session_id IN (SELECT ss.id FROM sessions ss WHERE EXISTS(
        SELECT 1 FROM analytics_match_scores m WHERE m.session_id=ss.id) ORDER BY ss.date DESC,ss.created_at DESC,ss.id LIMIT ?)''';
      args.add(n);
    }
    final rows = await db.rows(
      'SELECT * FROM analytics_player_matches $clause ORDER BY session_date DESC,ended_at DESC,match_id',
      args,
    );
    return StatisticsBundle(
      await db.players(includeArchived: true),
      rows.map(PlayerMatchStatistics.new).toList(),
    );
  });
  Future<List<Map<String, dynamic>>> playerHistory(String id) => db.rows(
    '''SELECT s.id AS session_id,s.date,s.location_name,s.status,t.name AS team_name,t.color_value
    FROM session_attendance a JOIN sessions s ON s.id=a.session_id
    LEFT JOIN team_memberships tm ON tm.session_id=a.session_id AND tm.player_id=a.player_id
    LEFT JOIN session_teams t ON t.id=tm.team_id WHERE a.player_id=? AND a.attendance_status='available' ORDER BY s.date DESC,s.created_at DESC,s.id''',
    [id],
  );
  Future<List<Map<String, dynamic>>> ratingHistory(String id) => db.rows(
    'SELECT * FROM player_rating_history WHERE player_id=? ORDER BY id DESC',
    [id],
  );
  Future<SessionMvp> mvp(String sessionId) async => db.transaction(() async {
    final rows = await db.rows(
      'SELECT * FROM session_mvp_settings WHERE session_id=?',
      [sessionId],
    );
    final w = rows.isEmpty
        ? const MvpWeights()
        : MvpWeights(
            goal: rows.single['goal_weight'] as int,
            assist: rows.single['assist_weight'] as int,
            win: rows.single['win_weight'] as int,
            foul: rows.single['foul_weight'] as int,
          );
    final stats = await load(StatisticsScope(sessionId: sessionId));
    final candidates =
        stats.players
            .map((p) => MvpCandidate(p, stats.career(p.id), w))
            .where((c) => c.stats.appearances > 0)
            .toList()
          ..sort((a, b) {
            final cmp = b.score.compareTo(a.score);
            return cmp != 0 ? cmp : a.player.id.compareTo(b.player.id);
          });
    final decisions = await db.rows(
      'SELECT * FROM session_mvp_decisions WHERE session_id=? ORDER BY revision DESC',
      [sessionId],
    );
    return SessionMvp(w, candidates, decisions);
  });
  Future<void> setMvpWeights(
    String sessionId,
    MvpWeights w,
  ) async => db.transaction(() async {
    if (w.toJson().values.any((v) => v < -100 || v > 100)) {
      throw ArgumentError('Use MVP weights from -100 to 100.');
    }
    if (await db.session(sessionId) == null) {
      throw StateError('Session not found.');
    }
    if ((await db.rows(
      'SELECT id FROM session_mvp_decisions WHERE session_id=? LIMIT 1',
      [sessionId],
    )).isNotEmpty) {
      throw StateError(
        'Award calculation weights are locked after the first confirmation.',
      );
    }
    await db.customStatement(
      '''INSERT INTO session_mvp_settings VALUES (?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET
      goal_weight=excluded.goal_weight,assist_weight=excluded.assist_weight,win_weight=excluded.win_weight,foul_weight=excluded.foul_weight''',
      [sessionId, w.goal, w.assist, w.win, w.foul],
    );
  });
  Future<void> confirmMvp(
    String sessionId, {
    String? playerId,
    bool shared = false,
    String? reason,
    required String requestId,
  }) async => db.transaction(() async {
    if (shared && playerId != null) {
      throw ArgumentError('Choose either a shared award or one recipient.');
    }
    final existing = await db.rows(
      'SELECT * FROM session_mvp_decisions WHERE id=?',
      [requestId],
    );
    if (existing.isNotEmpty) {
      final r = existing.single;
      if (r['session_id'] != sessionId ||
          r['player_id'] != playerId ||
          (r['method'] == 'shared') != shared ||
          (r['reason'] ?? '') != (reason ?? '').trim()) {
        throw ArgumentError('Request already used for a different award.');
      }
      return;
    }
    final session = await db.session(sessionId);
    if (session == null || session.status != 'completed') {
      throw StateError(
        'Complete the session and its competitions before confirming a final MVP. The calculation shown remains provisional until then.',
      );
    }
    if ((reason?.length ?? 0) > 300) {
      throw ArgumentError('Keep award reasons within 300 characters.');
    }
    final value = await mvp(sessionId);
    if (value.candidates.isEmpty) {
      throw StateError(
        'No eligible finalized participation exists for an MVP award.',
      );
    }
    if (shared && value.leaders.length < 2) {
      throw ArgumentError('A shared calculated award requires tied leaders.');
    }
    if (!shared && !value.candidates.any((c) => c.player.id == playerId)) {
      throw ArgumentError('Select a player with eligible participation.');
    }
    final method = shared
        ? 'shared'
        : value.leaders.length == 1 && value.leaders.single == playerId
        ? 'calculated'
        : 'override';
    final selected = shared ? value.leaders : [playerId!];
    await db.customStatement(
      'INSERT INTO session_mvp_settings VALUES (?,?,?,?,?) ON CONFLICT(session_id) DO NOTHING',
      [
        sessionId,
        value.weights.goal,
        value.weights.assist,
        value.weights.win,
        value.weights.foul,
      ],
    );
    final revision = value.decisions.isEmpty
        ? 1
        : (value.decisions.first['revision'] as int) + 1;
    final snapshot = jsonEncode({
      'weights': value.weights.toJson(),
      'candidates': value.candidates.map((c) => c.toJson()).toList(),
      'calculated_leaders': value.leaders,
    });
    await db.customStatement(
      'INSERT INTO session_mvp_decisions VALUES (?,?,?,?,?,?,?,?,?)',
      [
        requestId,
        sessionId,
        revision,
        shared ? null : playerId,
        method,
        jsonEncode(selected),
        snapshot,
        reason?.trim(),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  });
  String newAwardRequestId() => const Uuid().v4();
}
