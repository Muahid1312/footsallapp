import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:uuid/uuid.dart';

import '../../features/players/domain/player.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/teams/domain/team.dart';
import 'schema.dart';
import 'schema_v2.dart';
import 'schema_v3.dart';
import 'schema_v4.dart';
import 'schema_v5.dart';
import '../../features/teams/domain/team_balancer.dart';

/// Drift owns connection lifecycle, transactions, and versioned SQL migrations.
/// Explicit SQL keeps composite keys and triggers visible in one auditable schema;
/// domain objects isolate the UI from database rows. No code generation required.
class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);
  factory AppDatabase.file(File file) =>
      AppDatabase(NativeDatabase.createInBackground(file));
  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());
  static const _uuid = Uuid();
  @override
  int get schemaVersion => 5;
  Future<void>? _closing;
  @override
  Future<void> close() => _closing ??= super.close();
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await transaction(() async {
        for (final sql in [
          ...schemaV1,
          ...integrityTriggersV1,
          ...completedHistoryTriggersV1,
          ...migrationV2,
          ...integrityTriggersV2,
          ...auditImmutabilityV2,
          ...migrationV3,
          ...integrityTriggersV3,
          ...migrationV4,
          ...integrityTriggersV4,
          ...migrationV5,
        ]) {
          await customStatement(sql);
        }
      });
    },
    onUpgrade: (_, from, to) async {
      if (from < 1 || from > 4 || to != 5) {
        throw StateError('No migration from database version $from to $to');
      }
      await transaction(() async {
        for (final sql in [
          if (from == 1) ...[
            ...migrationV2,
            ...integrityTriggersV2,
            ...auditImmutabilityV2,
          ],
          if (from <= 2) ...[...migrationV3, ...integrityTriggersV3],
          if (from <= 3) ...[...migrationV4, ...integrityTriggersV4],
          ...migrationV5,
        ]) {
          await customStatement(sql);
        }
        if ((await customSelect('PRAGMA foreign_key_check').get()).isNotEmpty) {
          throw StateError(
            'Database migration found invalid historical references. No data was reset.',
          );
        }
      });
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final variables = args
        .map<Variable>(
          (v) => switch (v) {
            final int value => Variable<int>(value),
            final String value => Variable<String>(value),
            null => const Variable<String>(null),
            _ => throw ArgumentError('Unsupported SQL argument'),
          },
        )
        .toList();
    return (await customSelect(
      sql,
      variables: variables,
    ).get()).map((r) => r.data).toList();
  }

  Future<List<Player>> players({
    bool includeArchived = false,
  }) async => (await rows(
    'SELECT * FROM players ${includeArchived ? '' : 'WHERE is_archived=0'} ORDER BY name COLLATE NOCASE',
  )).map(Player.fromRow).toList();

  Future<Player?> player(String id) async {
    final result = await rows('SELECT * FROM players WHERE id=?', [id]);
    return result.isEmpty ? null : Player.fromRow(result.single);
  }

  Future<String> savePlayer({
    String? id,
    required String name,
    String? photoPath,
    required String position,
    int? jerseyNumber,
    required int skillRating,
    String? secondaryPosition,
    bool updateSecondaryPosition = false,
    bool? goalkeeperEligible,
    String? preferredFoot,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty ||
        cleanName.length > 80 ||
        skillRating < 1 ||
        skillRating > 10 ||
        (jerseyNumber != null && (jerseyNumber < 0 || jerseyNumber > 99))) {
      throw ArgumentError(
        'Check name, jersey number (0–99), and skill rating (1–10).',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = id ?? _uuid.v4();
    final previous = id == null ? null : await player(id);
    final foot = preferredFoot ?? previous?.preferredFoot ?? 'unknown';
    if (!['unknown', 'left', 'right', 'both'].contains(foot)) {
      throw ArgumentError('Choose a valid preferred foot.');
    }
    final secondary = updateSecondaryPosition
        ? secondaryPosition
        : previous?.secondaryPosition;
    if (secondary != null &&
        (secondary.trim().isEmpty ||
            secondary.length > 40 ||
            secondary == position)) {
      throw ArgumentError('Choose a different secondary position or none.');
    }
    final keeper =
        goalkeeperEligible ??
        previous?.goalkeeperEligible ??
        (position.trim().toLowerCase() == 'goalkeeper');
    if (id == null) {
      await customStatement(
        'INSERT INTO players (id,name,photo_path,preferred_position,jersey_number,skill_rating,created_at,updated_at,secondary_position,goalkeeper_eligible,preferred_foot) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        [
          key,
          cleanName,
          photoPath,
          position,
          jerseyNumber,
          skillRating,
          now,
          now,
          secondary,
          keeper ? 1 : 0,
          foot,
        ],
      );
    } else {
      if (previous == null) {
        throw StateError('Player no longer exists.');
      }
      await customStatement(
        'UPDATE players SET name=?,photo_path=?,preferred_position=?,jersey_number=?,skill_rating=?,updated_at=?,secondary_position=?,goalkeeper_eligible=?,preferred_foot=? WHERE id=?',
        [
          cleanName,
          photoPath,
          position,
          jerseyNumber,
          skillRating,
          now,
          secondary,
          keeper ? 1 : 0,
          foot,
          id,
        ],
      );
    }
    return key;
  }

  Future<void> archivePlayer(String id, {bool archived = true}) async {
    await customStatement(
      'UPDATE players SET is_archived=?,updated_at=? WHERE id=?',
      [archived ? 1 : 0, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  Future<List<FutsalSession>> sessions() async => (await rows(
    'SELECT * FROM sessions ORDER BY date DESC, created_at DESC',
  )).map(FutsalSession.fromRow).toList();
  Future<FutsalSession?> session(String id) async {
    final result = await rows('SELECT * FROM sessions WHERE id=?', [id]);
    return result.isEmpty ? null : FutsalSession.fromRow(result.single);
  }

  Future<List<Player>> attendees(String sessionId) async => (await rows(
    'SELECT p.* FROM players p JOIN session_attendance a ON a.player_id=p.id WHERE a.session_id=? AND a.attendance_status=\'available\' ORDER BY p.name COLLATE NOCASE',
    [sessionId],
  )).map(Player.fromRow).toList();

  Future<String> createSession({
    required DateTime date,
    required String location,
    required int durationSeconds,
    required String rotationMode,
    required List<String> playerIds,
    required int teamCount,
  }) async {
    if (playerIds.toSet().length != playerIds.length ||
        teamCount < 2 ||
        playerIds.length < teamCount ||
        teamCount > 32) {
      throw ArgumentError(
        'Select at least one unique player per team (2–32 teams).',
      );
    }
    if (date.weekday != DateTime.saturday) {
      throw ArgumentError('Choose a Saturday.');
    }
    if (durationSeconds < 60 ||
        durationSeconds > 10800 ||
        !['round_robin', 'winner_stays'].contains(rotationMode)) {
      throw ArgumentError('Invalid session settings.');
    }
    final id = _uuid.v4();
    await transaction(() async {
      for (final pid in playerIds) {
        final p = await player(pid);
        if (p == null || p.isArchived) {
          throw StateError('Only active players can join a new session.');
        }
      }
      await customStatement('INSERT INTO sessions VALUES (?,?,?,?,?,?,?)', [
        id,
        DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch,
        location.trim(),
        durationSeconds,
        rotationMode,
        'planned',
        DateTime.now().millisecondsSinceEpoch,
      ]);
      for (final pid in playerIds) {
        await customStatement(
          'INSERT INTO session_attendance VALUES (?,?,?,?)',
          [_uuid.v4(), id, pid, 'available'],
        );
      }
      for (var i = 0; i < teamCount; i++) {
        await customStatement(
          'INSERT INTO session_teams VALUES (?,?,?,?,?,?)',
          [
            _uuid.v4(),
            id,
            'Team ${i + 1}',
            teamColors[i % teamColors.length],
            null,
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
      await randomizeTeams(id);
    });
    return id;
  }

  Future<List<SessionTeam>> teams(String sessionId) async {
    final result = await rows(
      'SELECT * FROM session_teams WHERE session_id=? ORDER BY created_at, rowid',
      [sessionId],
    );
    final members = await rows(
      'SELECT * FROM team_memberships WHERE session_id=? ORDER BY created_at, rowid',
      [sessionId],
    );
    return result
        .map(
          (r) => SessionTeam(
            id: r['id'] as String,
            sessionId: sessionId,
            name: r['name'] as String,
            colorValue: r['color_value'] as int,
            captainPlayerId: r['captain_player_id'] as String?,
            playerIds: members
                .where((m) => m['team_id'] == r['id'])
                .map((m) => m['player_id'] as String)
                .toList(),
          ),
        )
        .toList();
  }

  Future<void> _ensureEditable(String id) async {
    final s = await session(id);
    if (s == null || s.status != 'planned') {
      throw StateError('Completed sessions are read-only.');
    }
    if ((await rows('SELECT id FROM matches WHERE session_id=? LIMIT 1', [
      id,
    ])).isNotEmpty) {
      throw StateError(
        'Teams are locked because matches reference their rosters.',
      );
    }
  }

  Future<void> randomizeTeams(
    String id, {
    Random? random,
  }) async => transaction(() async {
    await _ensureEditable(id);
    final roster = await attendees(id);
    final current = await teams(id);
    if (current.length < 2 || roster.length < current.length) {
      throw StateError('Not enough players for these teams.');
    }
    final locks = await rows(
      'SELECT player_id,team_id FROM team_assignment_locks WHERE session_id=? ORDER BY player_id',
      [id],
    );
    final candidate = generateBalance(
      BalanceRequest(
        players: roster.map(BalancePlayer.fromPlayer).toList(),
        teams: current.map((t) => t.id).toList(),
        locks: {
          for (final row in locks)
            row['player_id'] as String: row['team_id'] as String,
        },
        mode: 'random',
        seed: (random ?? Random.secure()).nextInt(2147483647),
      ),
    );
    await replaceRosters(id, candidate.assignments);
  });

  Future<void> replaceRosters(
    String id,
    Map<String, List<String>> assignments, {
    bool allowUneven = false,
  }) async => transaction(() async {
    await _ensureEditable(id);
    final current = await teams(id);
    final expected = (await attendees(id)).map((p) => p.id).toSet();
    final flattened = assignments.values.expand((v) => v).toList();
    final locks = await rows(
      'SELECT player_id,team_id FROM team_assignment_locks WHERE session_id=?',
      [id],
    );
    if (locks.any(
      (lock) =>
          !(assignments[lock['team_id']] ?? []).contains(lock['player_id']),
    )) {
      throw StateError(
        'Unlock a player before moving their locked assignment.',
      );
    }
    if (assignments.length != current.length ||
        !assignments.keys.toSet().containsAll(current.map((t) => t.id)) ||
        flattened.length != flattened.toSet().length ||
        flattened.length != expected.length ||
        !expected.containsAll(flattened) ||
        assignments.values.any((v) => v.isEmpty)) {
      throw ArgumentError(
        'Assign every attending player exactly once, with at least one per team.',
      );
    }
    final sizes = assignments.values.map((players) => players.length).toList();
    if (!allowUneven && sizes.reduce(max) - sizes.reduce(min) > 1) {
      throw ArgumentError(
        'This roster requires an explicit uneven-size override.',
      );
    }
    // Clear captains before replacing memberships; restore only valid captains.
    await customStatement(
      'UPDATE session_teams SET captain_player_id=NULL WHERE session_id=?',
      [id],
    );
    await customStatement('DELETE FROM team_memberships WHERE session_id=?', [
      id,
    ]);
    for (final entry in assignments.entries) {
      for (final pid in entry.value) {
        await customStatement(
          'INSERT INTO team_memberships VALUES (?,?,?,?,?)',
          [
            _uuid.v4(),
            entry.key,
            id,
            pid,
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
    }
    for (final t in current) {
      if (t.captainPlayerId != null &&
          assignments[t.id]!.contains(t.captainPlayerId)) {
        await customStatement(
          'UPDATE session_teams SET captain_player_id=? WHERE id=?',
          [t.captainPlayerId, t.id],
        );
      }
    }
  });

  Future<void> swapPlayers(
    String sessionId,
    String first,
    String second,
  ) async => transaction(() async {
    if (first == second) {
      throw ArgumentError('Choose two different players.');
    }
    final current = await teams(sessionId);
    final a = current.where((t) => t.playerIds.contains(first)).firstOrNull;
    final b = current.where((t) => t.playerIds.contains(second)).firstOrNull;
    if (a == null || b == null || a.id == b.id) {
      throw ArgumentError('Choose players on different teams.');
    }
    // Swapping preserves team sizes, including an already accepted uneven roster.
    final sizes = current.map((t) => t.playerIds.length).toList();
    await replaceRosters(sessionId, {
      for (final t in current)
        t.id: t.playerIds
            .map(
              (p) => p == first
                  ? second
                  : p == second
                  ? first
                  : p,
            )
            .toList(),
    }, allowUneven: sizes.reduce(max) - sizes.reduce(min) > 1);
  });

  Future<void> movePlayer(
    String sessionId,
    String playerId,
    String targetTeamId, {
    bool allowUneven = false,
  }) async => transaction(() async {
    final current = await teams(sessionId);
    if (!current.any((t) => t.id == targetTeamId) ||
        !current.any((t) => t.playerIds.contains(playerId))) {
      throw ArgumentError('Player or team not in this session.');
    }
    final assignment = {
      for (final t in current)
        t.id: t.playerIds.where((p) => p != playerId).toList(),
    };
    assignment[targetTeamId]!.add(playerId);
    final sizes = assignment.values.map((v) => v.length).toList();
    if (!allowUneven && sizes.reduce(max) - sizes.reduce(min) > 1) {
      throw ArgumentError(
        'This move requires an explicit uneven-size override.',
      );
    }
    await replaceRosters(sessionId, assignment, allowUneven: allowUneven);
  });

  Future<void> updateTeam(
    String sessionId,
    String teamId, {
    required String name,
    required int colorValue,
    String? captainPlayerId,
  }) async => transaction(() async {
    await _ensureEditable(sessionId);
    if (name.trim().isEmpty || name.trim().length > 40) {
      throw ArgumentError('Team name must be 1–40 characters.');
    }
    final t = (await teams(sessionId)).where((t) => t.id == teamId).firstOrNull;
    if (t == null ||
        (captainPlayerId != null && !t.playerIds.contains(captainPlayerId))) {
      throw ArgumentError('Captain must belong to this team.');
    }
    await customStatement(
      'UPDATE session_teams SET name=?,color_value=?,captain_player_id=? WHERE id=?',
      [name.trim(), colorValue, captainPlayerId, teamId],
    );
  });

  Future<void> completeSession(String id) async => transaction(() async {
    final current = await session(id);
    if (current == null || current.status != 'planned') {
      throw StateError('Session is already complete or unavailable.');
    }
    if ((await rows(
      "SELECT id FROM matches WHERE session_id=? AND phase NOT IN ('finished','cancelled') LIMIT 1",
      [id],
    )).isNotEmpty) {
      throw StateError(
        'Finish every scheduled or open match before completing the session.',
      );
    }
    if ((await rows(
      "SELECT id FROM competitions WHERE session_id=? AND status!='completed' LIMIT 1",
      [id],
    )).isNotEmpty) {
      throw StateError(
        'Complete the session competition before locking session history.',
      );
    }
    await customStatement(
      'UPDATE sessions SET status=\'completed\' WHERE id=?',
      [id],
    );
  });
}

const teamColors = [
  0xFF34D399,
  0xFF60A5FA,
  0xFFFBBF24,
  0xFFF472B6,
  0xFFA78BFA,
  0xFFFB923C,
  0xFF22D3EE,
  0xFFF87171,
];
