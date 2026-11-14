import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../core/database/app_database.dart';
import '../domain/team_balancer.dart';

class BalancePreview {
  BalancePreview(this.request, this.result, this.fingerprint);
  final BalanceRequest request;
  final BalanceResult result;
  final String fingerprint;
}

class BalanceRepository {
  BalanceRepository(this.db);
  final AppDatabase db;
  Future<void> _editable(String id) async {
    final session = await db.session(id);
    if (session == null ||
        session.status != 'planned' ||
        (await db.rows('SELECT id FROM matches WHERE session_id=? LIMIT 1', [
          id,
        ])).isNotEmpty) {
      throw StateError(
        'Saved or scheduled match rosters cannot be regenerated. Use a new session to preserve that history.',
      );
    }
  }

  Future<Map<String, String>> locks(String id) async => {
    for (final r in await db.rows(
      'SELECT player_id,team_id FROM team_assignment_locks WHERE session_id=? ORDER BY player_id',
      [id],
    ))
      r['player_id'] as String: r['team_id'] as String,
  };
  Future<void> setLock(
    String sessionId,
    String playerId,
    String? teamId,
  ) async => db.transaction(() async {
    await _editable(sessionId);
    if (teamId == null) {
      await db.customStatement(
        'DELETE FROM team_assignment_locks WHERE session_id=? AND player_id=?',
        [sessionId, playerId],
      );
    } else {
      await db.customStatement(
        'INSERT INTO team_assignment_locks VALUES (?,?,?) ON CONFLICT(session_id,player_id) DO UPDATE SET team_id=excluded.team_id',
        [sessionId, playerId, teamId],
      );
    }
  });
  Future<String> _fingerprint(String id) async {
    final players = await db.attendees(id), teams = await db.teams(id);
    return jsonEncode([
      for (final p in players)
        [
          p.id,
          p.skillRating,
          p.preferredPosition,
          p.secondaryPosition,
          p.goalkeeperEligible,
          p.updatedAt.millisecondsSinceEpoch,
        ],
      teams.map((t) => t.id).toList(),
      await locks(id),
    ]);
  }

  Future<BalancePreview> preview(
    String id, {
    String mode = 'balanced',
    int seed = 1,
    int iterations = 2000,
    bool allowUneven = false,
  }) async {
    final input = await db.transaction(() async {
      await _editable(id);
      final players = await db.attendees(id), teams = await db.teams(id);
      return (
        request: BalanceRequest(
          players: players.map(BalancePlayer.fromPlayer).toList(),
          teams: teams.map((t) => t.id).toList(),
          locks: await locks(id),
          mode: mode,
          seed: seed,
          iterations: iterations,
          allowUneven: allowUneven,
        ),
        fingerprint: await _fingerprint(id),
      );
    });
    final result = await compute(generateBalance, input.request);
    return BalancePreview(input.request, result, input.fingerprint);
  }

  Future<void> confirm(
    String id,
    BalancePreview preview,
  ) async => db.transaction(() async {
    await _editable(id);
    if (await _fingerprint(id) != preview.fingerprint) {
      throw StateError(
        'Players, ratings, teams, or locks changed. Regenerate the preview before confirming.',
      );
    }
    validateBalance(preview.request, preview.result.assignments);
    await db.replaceRosters(
      id,
      preview.result.assignments,
      allowUneven: preview.request.allowUneven,
    );
  });
}
