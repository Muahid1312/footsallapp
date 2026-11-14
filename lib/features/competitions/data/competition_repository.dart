import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';
import '../../matches/domain/match.dart';
import '../domain/competition.dart';

class CompetitionRepository {
  CompetitionRepository(this.db, this.clock);
  final AppDatabase db;
  final MatchClock clock;
  static const _uuid = Uuid();
  Future<List<Competition>> forSession(String id) async => (await db.rows(
    'SELECT * FROM competitions WHERE session_id=? ORDER BY created_at DESC,rowid DESC',
    [id],
  )).map(Competition.new).toList();
  Future<CompetitionBundle?> load(String id) async {
    final rows = await db.rows('SELECT * FROM competitions WHERE id=?', [id]);
    if (rows.isEmpty) {
      return null;
    }
    final c = Competition(rows.single);
    final selection = await db.rows(
      'SELECT team_id FROM competition_teams WHERE competition_id=? ORDER BY ordinal',
      [id],
    );
    final all = await db.teams(c.sessionId);
    final teams = selection
        .map((r) => all.singleWhere((t) => t.id == r['team_id']))
        .toList();
    final fixtures = (await db.rows(
      '''SELECT f.*,m.phase,m.result_revision,
      (SELECT COUNT(*) FROM match_events e WHERE e.match_id=m.id AND ((e.event_type='goal' AND e.team_id=m.team_a_id) OR (e.event_type='own_goal' AND e.team_id=m.team_b_id))
       AND NOT EXISTS(SELECT 1 FROM match_actions a WHERE a.target_event_id=e.id)) AS score_a,
      (SELECT COUNT(*) FROM match_events e WHERE e.match_id=m.id AND ((e.event_type='goal' AND e.team_id=m.team_b_id) OR (e.event_type='own_goal' AND e.team_id=m.team_a_id))
       AND NOT EXISTS(SELECT 1 FROM match_actions a WHERE a.target_event_id=e.id)) AS score_b
      FROM competition_fixtures f JOIN matches m ON m.id=f.match_id WHERE f.competition_id=? ORDER BY f.sequence''',
      [id],
    )).map(CompetitionFixture.new).toList();
    final decisions = await db.rows(
      'SELECT * FROM champion_decisions WHERE competition_id=?',
      [id],
    );
    final history = await db.rows(
      'SELECT * FROM competition_admin_actions WHERE competition_id=? ORDER BY rowid',
      [id],
    );
    return CompetitionBundle(
      c,
      teams,
      fixtures,
      standings(
        teams.map((t) => t.id).toList(),
        fixtures,
        win: c.win,
        draw: c.draw,
        loss: c.loss,
      ),
      decisions.firstOrNull,
      history,
    );
  }

  Future<CompetitionBundle> required(String id) async {
    final b = await load(id);
    if (b == null) {
      throw StateError('Competition not found.');
    }
    return b;
  }

  Future<String> create({
    required String sessionId,
    required List<String> teamIds,
    required String mode,
    required int durationSeconds,
    int win = 3,
    int draw = 1,
    int loss = 0,
    int cycles = 1,
    String drawPolicy = 'both_rotate',
    String criterion = 'points',
    int matchLimit = 6,
    required String requestId,
  }) async => db.transaction(() async {
    final existing = await load(requestId);
    final payload = jsonEncode([
      sessionId,
      teamIds,
      mode,
      durationSeconds,
      win,
      draw,
      loss,
      cycles,
      drawPolicy,
      criterion,
      matchLimit,
    ]);
    if (existing != null) {
      final logged = await db.rows(
        "SELECT payload FROM competition_admin_actions WHERE id=?",
        ['create-$requestId'],
      );
      if (logged.single['payload'] != payload) {
        throw ArgumentError(
          'Request already used for different competition settings.',
        );
      }
      return requestId;
    }
    if (!['round_robin', 'winner_stays'].contains(mode) ||
        !['both_rotate', 'longest', 'manual'].contains(drawPolicy) ||
        !['points', 'wins'].contains(criterion) ||
        durationSeconds < 60 ||
        durationSeconds > 10800 ||
        cycles < 1 ||
        cycles > 10 ||
        matchLimit < 1 ||
        matchLimit > 100 ||
        [win, draw, loss].any((p) => p < 0 || p > 100) ||
        teamIds.length < 2 ||
        teamIds.toSet().length != teamIds.length) {
      throw ArgumentError(
        'Check teams, duration, points, cycles, and rotation settings.',
      );
    }
    final session = await db.session(sessionId);
    if (session == null || session.status != 'planned') {
      throw StateError('Choose an open session.');
    }
    if ((await forSession(sessionId)).any((c) => c.status != 'completed')) {
      throw StateError('Complete the existing competition first.');
    }
    final teams = await db.teams(sessionId);
    if (teamIds.any(
      (id) => !teams.any((t) => t.id == id && t.playerIds.isNotEmpty),
    )) {
      throw ArgumentError('Select saved nonempty teams from this session.');
    }
    await db.customStatement(
      '''INSERT INTO competitions(id,session_id,mode,duration_seconds,win_points,draw_points,loss_points,cycles,
      draw_policy,champion_criterion,match_limit,rotation_json,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        requestId,
        sessionId,
        mode,
        durationSeconds,
        win,
        draw,
        loss,
        cycles,
        drawPolicy,
        criterion,
        matchLimit,
        RotationState.initial(teamIds).encode(),
        clock.wallMillis,
      ],
    );
    for (var i = 0; i < teamIds.length; i++) {
      await db.customStatement(
        'INSERT INTO competition_teams VALUES (?,?,?,?)',
        [requestId, sessionId, teamIds[i], i],
      );
    }
    await _audit(
      'create-$requestId',
      requestId,
      'create',
      'Competition settings confirmed',
      payload,
    );
    return requestId;
  });
  Future<void> updateDraft(
    String id, {
    required String mode,
    required int durationSeconds,
    required int win,
    required int draw,
    required int loss,
    required int cycles,
    required String drawPolicy,
    required String criterion,
    required int matchLimit,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([
      'settings',
      mode,
      durationSeconds,
      win,
      draw,
      loss,
      cycles,
      drawPolicy,
      criterion,
      matchLimit,
    ]);
    if (await _done(requestId, id, payload)) {
      return;
    }
    final b = await required(id);
    if (b.competition.status != 'draft' || b.fixtures.isNotEmpty) {
      throw StateError(
        'Competition settings lock when fixtures are generated.',
      );
    }
    if (!['round_robin', 'winner_stays'].contains(mode) ||
        !['both_rotate', 'longest', 'manual'].contains(drawPolicy) ||
        !['points', 'wins'].contains(criterion) ||
        durationSeconds < 60 ||
        durationSeconds > 10800 ||
        cycles < 1 ||
        cycles > 10 ||
        matchLimit < 1 ||
        matchLimit > 100 ||
        [win, draw, loss].any((p) => p < 0 || p > 100)) {
      throw ArgumentError('Check competition settings.');
    }
    await db.customStatement(
      '''UPDATE competitions SET mode=?,duration_seconds=?,win_points=?,draw_points=?,loss_points=?,cycles=?,draw_policy=?,champion_criterion=?,match_limit=? WHERE id=?''',
      [
        mode,
        durationSeconds,
        win,
        draw,
        loss,
        cycles,
        drawPolicy,
        criterion,
        matchLimit,
        id,
      ],
    );
    await _audit(
      requestId,
      id,
      'settings',
      'Draft rules explicitly revised before activation',
      payload,
    );
  });

  Future<bool> _done(String key, String comp, String payload) async {
    final r = await db.rows(
      'SELECT competition_id,payload FROM competition_admin_actions WHERE id=?',
      [key],
    );
    if (r.isEmpty) {
      return false;
    }
    if (r.single['competition_id'] != comp || r.single['payload'] != payload) {
      throw ArgumentError('Request key already used for another change.');
    }
    return true;
  }

  Future<void> _audit(
    String key,
    String comp,
    String kind,
    String reason,
    String payload, {
    String? match,
    int? revision,
  }) => db.customStatement(
    'INSERT INTO competition_admin_actions VALUES (?,?,?,?,?,?,?,?)',
    [key, comp, kind, match, revision, reason, payload, clock.wallMillis],
  );
  void _active(CompetitionBundle b) {
    if (b.competition.status != 'active') {
      throw StateError('Competition is not active.');
    }
  }

  Future<void> activate(
    String id, {
    required String requestId,
  }) async => db.transaction(() async {
    const payload = '["activate"]';
    if (await _done(requestId, id, payload)) {
      return;
    }
    final b = await required(id);
    if (b.competition.status != 'draft') {
      throw StateError(
        'Fixtures have already been generated. Completed matches are never regenerated.',
      );
    }
    final plans = b.competition.mode == 'round_robin'
        ? roundRobin(b.teams.map((t) => t.id).toList(), b.competition.cycles)
        : [FixturePlan(b.teams[0].id, b.teams[1].id, 1, 1)];
    for (final p in plans) {
      await _fixture(b.competition, p.a, p.b, cycle: p.cycle, round: p.round);
    }
    await db.customStatement(
      "UPDATE competitions SET status='active' WHERE id=?",
      [id],
    );
    await _audit(
      requestId,
      id,
      'activate',
      'Generated deterministic fixtures and locked competition settings',
      payload,
    );
  });
  Future<String> _fixture(
    Competition c,
    String a,
    String b, {
    int cycle = 1,
    int round = 1,
    String kind = 'league',
  }) async {
    // Reuse an already-pending rotation pairing rather than duplicating it.
    if (c.mode == 'winner_stays' && kind == 'league') {
      final existing = await db.rows(
        "SELECT match_id FROM competition_fixtures WHERE competition_id=? AND kind='league' AND status IN ('pending','postponed')",
        [c.id],
      );
      if (existing.isNotEmpty) {
        return existing.single['match_id'] as String;
      }
    }
    final n =
        (await db.rows(
              'SELECT COALESCE(MAX(sequence),0)+1 AS n FROM competition_fixtures WHERE competition_id=?',
              [c.id],
            )).single['n']
            as int;
    final reusable = await db.rows(
      '''SELECT m.id,m.team_a_id,m.team_b_id FROM matches m JOIN match_timer_state t ON t.match_id=m.id
      WHERE m.session_id=? AND m.duration_seconds=? AND m.phase='scheduled' AND m.result_revision=0
      AND m.started_at IS NULL AND m.ended_at IS NULL AND t.accumulated_millis=0 AND t.recovery_required=0
      AND ((m.team_a_id=? AND m.team_b_id=?) OR (m.team_a_id=? AND m.team_b_id=?))
      AND NOT EXISTS(SELECT 1 FROM competition_fixtures WHERE match_id=m.id)
      AND NOT EXISTS(SELECT 1 FROM match_events WHERE match_id=m.id)
      AND NOT EXISTS(SELECT 1 FROM match_lineup_stints WHERE match_id=m.id)
      AND NOT EXISTS(SELECT 1 FROM match_actions WHERE match_id=m.id AND action_type!='import') ORDER BY m.rowid LIMIT 1''',
      [c.sessionId, c.duration, a, b, b, a],
    );
    final match = reusable.isEmpty
            ? _uuid.v4()
            : reusable.single['id'] as String,
        fixture = _uuid.v4();
    if (reusable.isEmpty) {
      await db.customStatement(
        "INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase) VALUES (?,?,?,?,?,'scheduled','scheduled')",
        [match, c.sessionId, a, b, c.duration],
      );
      await db.customStatement(
        'INSERT INTO match_timer_state(match_id) VALUES (?)',
        [match],
      );
    } else {
      a = reusable.single['team_a_id'] as String;
      b = reusable.single['team_b_id'] as String;
    }
    await db.customStatement(
      'INSERT INTO competition_fixtures VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        fixture,
        c.id,
        match,
        a,
        b,
        cycle,
        round,
        n,
        kind,
        'pending',
        1,
        c.mode == 'round_robin' && kind == 'league'
            ? '$cycle:${([a, b]..sort()).join('|')}'
            : null,
      ],
    );
    return match;
  }

  Future<void> validateStart(String match) async {
    final r = await db.rows(
      'SELECT competition_id,status FROM competition_fixtures WHERE match_id=?',
      [match],
    );
    if (r.isEmpty) {
      return;
    }
    final b = await required(r.single['competition_id'] as String);
    _active(b);
    if (r.single['status'] != 'pending') {
      throw StateError('Restore the postponed fixture before starting it.');
    }
    if (b.fixtures.any(
      (f) => f.matchId != match && ['live', 'paused'].contains(f.phase),
    )) {
      throw StateError('Finish the current competition match first.');
    }
    if (b.competition.mode == 'winner_stays' &&
        b.competition.rotation.awaitingMatch != null) {
      throw StateError('Resolve the pending draw rotation first.');
    }
  }

  Future<void> onMatchFinished(String match) async {
    final link = await db.rows(
      'SELECT competition_id FROM competition_fixtures WHERE match_id=?',
      [match],
    );
    if (link.isEmpty) {
      return;
    }
    final id = link.single['competition_id'] as String, b = await required(id);
    _active(b);
    final f = b.fixtures.singleWhere((f) => f.matchId == match);
    final revision = f.row['result_revision'] as int;
    if ((await db.rows(
      'SELECT match_id FROM competition_applications WHERE match_id=? AND revision=?',
      [match, revision],
    )).isNotEmpty) {
      return;
    }
    if (f.phase != 'finished' || f.status != 'pending') {
      throw StateError(
        'Only the current finalized fixture can update competition results.',
      );
    }
    final before = b.competition.rotation;
    var after = before;
    if (b.competition.mode == 'winner_stays' && f.kind == 'league') {
      if (!before.playing.toSet().containsAll([f.a, f.b])) {
        throw StateError('Saved rotation pairing does not match this fixture.');
      }
      after = rotate(
        before,
        goalsA: before.playing[0] == f.a ? f.scoreA : f.scoreB,
        goalsB: before.playing[1] == f.b ? f.scoreB : f.scoreA,
        policy: b.competition.drawPolicy,
        sequence: f.sequence,
        matchId: match,
      );
    }
    await db.customStatement(
      "UPDATE competition_fixtures SET status='finished' WHERE id=?",
      [f.id],
    );
    await db.customStatement(
      'UPDATE competitions SET rotation_json=? WHERE id=?',
      [after.encode(), id],
    );
    await db.customStatement(
      'INSERT INTO competition_applications VALUES (?,?,?,?,?,?,?,?)',
      [
        match,
        revision,
        id,
        f.id,
        before.encode(),
        after.encode(),
        0,
        clock.wallMillis,
      ],
    );
    if (b.competition.mode == 'winner_stays' &&
        f.kind == 'league' &&
        after.awaitingMatch == null) {
      await _nextRotation(id, after);
    }
  }

  Future<void> _nextRotation(String id, RotationState state) async {
    final b = await required(id);
    final completed = b.fixtures
        .where(
          (f) =>
              f.kind == 'league' &&
              f.status == 'finished' &&
              f.phase == 'finished',
        )
        .length;
    if (completed < b.competition.limit) {
      await _fixture(
        b.competition,
        state.playing[0],
        state.playing[1],
        round: completed + 1,
      );
    }
  }

  Future<void> resolveDraw(
    String id, {
    String? stayer,
    bool both = false,
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode(['draw_rotation', stayer, both, reason.trim()]);
    if (await _done(requestId, id, payload)) {
      return;
    }
    final b = await required(id);
    _active(b);
    _reason(reason);
    final state = b.competition.rotation, match = state.awaitingMatch;
    if (match == null) {
      throw StateError('No draw is awaiting a rotation decision.');
    }
    final f = b.fixtures.singleWhere((f) => f.matchId == match);
    if (!both && stayer == null) {
      throw ArgumentError('Choose who stays or rotate both teams.');
    }
    final next = rotate(
      state,
      goalsA: f.scoreA,
      goalsB: f.scoreB,
      policy: 'manual',
      sequence: f.sequence,
      matchId: match,
      manualStayer: stayer,
      both: both,
    );
    await db.customStatement(
      'UPDATE competitions SET rotation_json=? WHERE id=?',
      [next.encode(), id],
    );
    await _audit(
      requestId,
      id,
      'draw_rotation',
      reason.trim(),
      payload,
      match: match,
      revision: f.row['result_revision'] as int,
    );
    await _nextRotation(id, next);
  });
  void _reason(String reason) {
    if (reason.trim().isEmpty || reason.length > 300) {
      throw ArgumentError('Enter a reason (up to 300 characters).');
    }
  }

  Future<void> manageFixture(
    String id,
    String fixtureId,
    String action, {
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([action, fixtureId, reason.trim()]);
    if (await _done(requestId, id, payload)) {
      return;
    }
    final b = await required(id);
    _active(b);
    _reason(reason);
    final f = b.fixtures.singleWhere((f) => f.id == fixtureId);
    if (f.phase != 'scheduled' ||
        !['pending', 'postponed'].contains(f.status)) {
      throw StateError('Only an unplayed fixture can be changed.');
    }
    if (!['postpone', 'restore', 'cancel'].contains(action)) {
      throw ArgumentError('Invalid fixture action.');
    }
    if (action == 'cancel') {
      await _cancel(f);
    } else {
      await db.customStatement(
        'UPDATE competition_fixtures SET status=? WHERE id=?',
        [action == 'postpone' ? 'postponed' : 'pending', f.id],
      );
    }
    await _audit(
      requestId,
      id,
      action,
      reason.trim(),
      payload,
      match: f.matchId,
    );
  });
  Future<void> _cancel(CompetitionFixture f, {bool superseded = false}) async {
    if (f.phase != 'scheduled') {
      throw StateError('A played match cannot be cancelled.');
    }
    await db.customStatement(
      "UPDATE matches SET phase='cancelled',status='cancelled' WHERE id=?",
      [f.matchId],
    );
    await db.customStatement(
      "UPDATE competition_fixtures SET status='cancelled',required=? WHERE id=?",
      [superseded ? 0 : 1, f.id],
    );
  }

  Future<void> continueRotation(String id, {required String requestId}) async =>
      db.transaction(() async {
        const payload = '["continue_rotation"]';
        if (await _done(requestId, id, payload)) {
          return;
        }
        final b = await required(id);
        _active(b);
        if (b.competition.mode != 'winner_stays' ||
            b.competition.rotation.awaitingMatch != null) {
          throw StateError('Resolve rotation before continuing.');
        }
        await _nextRotation(id, b.competition.rotation);
        await _audit(
          requestId,
          id,
          'continue',
          'Restored the pending rotation pairing',
          payload,
        );
      });
  Future<void> reopen(
    String id,
    String match, {
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode(['reopen', match, reason.trim()]);
    if (await _done(requestId, id, payload)) {
      return;
    }
    final b = await required(id);
    _active(b);
    _reason(reason);
    final f = b.fixtures.singleWhere((f) => f.matchId == match);
    if (f.phase != 'finished' || f.status != 'finished') {
      throw StateError('Choose a finished competition match.');
    }
    if (b.fixtures.any(
      (other) =>
          other.matchId != match && ['live', 'paused'].contains(other.phase),
    )) {
      throw StateError('Another match is open. Finish it first.');
    }
    if (b.competition.mode == 'winner_stays' &&
        b.fixtures.any(
          (other) => other.sequence > f.sequence && other.phase == 'finished',
        )) {
      throw StateError(
        'A later rotation match has already been played. Its history cannot be rewritten.',
      );
    }
    if (b.fixtures.any(
      (other) =>
          other.kind == 'playoff' &&
          other.matchId != match &&
          other.phase == 'finished' &&
          (f.kind == 'league' || other.sequence > f.sequence),
    )) {
      throw StateError('A playoff result depends on these standings.');
    }
    for (final next in b.fixtures.where(
      (other) =>
          other.phase == 'scheduled' &&
          (b.competition.mode == 'winner_stays' || other.kind == 'playoff'),
    )) {
      await _cancel(next, superseded: true);
    }
    final previous = f.row['result_revision'] as int, revision = previous + 1;
    final applied = await db.rows(
      'SELECT * FROM competition_applications WHERE match_id=? AND revision=? AND reverted=0',
      [match, previous],
    );
    if (applied.isEmpty) {
      throw StateError('Competition result application is missing.');
    }
    await db.customStatement('INSERT INTO match_reopens VALUES (?,?,?,?)', [
      match,
      revision,
      reason.trim(),
      clock.wallMillis,
    ]);
    await db.customStatement(
      "UPDATE matches SET phase='paused',status='live',result_revision=? WHERE id=?",
      [revision, match],
    );
    await db.customStatement(
      "UPDATE competition_fixtures SET status='pending' WHERE id=?",
      [f.id],
    );
    await db.customStatement(
      'UPDATE competition_applications SET reverted=1 WHERE match_id=? AND revision=?',
      [match, previous],
    );
    if (b.competition.mode == 'winner_stays') {
      await db.customStatement(
        'UPDATE competitions SET rotation_json=? WHERE id=?',
        [applied.single['before_state'], id],
      );
    }
    await _audit(
      requestId,
      id,
      'reopen',
      reason.trim(),
      payload,
      match: match,
      revision: revision,
    );
  });
  Future<String> playoff(
    String id, {
    required String requestId,
  }) async => db.transaction(() async {
    final payload = '["playoff"]';
    if (await _done(requestId, id, payload)) {
      return (await db.rows(
            'SELECT match_id FROM competition_admin_actions WHERE id=?',
            [requestId],
          )).single['match_id']
          as String;
    }
    final b = await required(id);
    _active(b);
    if (b.fixtures.any(
      (f) => f.status == 'pending' || f.status == 'postponed',
    )) {
      throw StateError('Resolve scheduled fixtures before adding a playoff.');
    }
    if (b.candidates.length != 2) {
      throw StateError(
        'A playoff fixture supports exactly two tied leaders. For larger ties use an explicit shared/manual decision.',
      );
    }
    if (b.championCandidates.length == 1) {
      throw StateError('The playoff already separated the leaders.');
    }
    final match = await _fixture(
      b.competition,
      b.candidates[0],
      b.candidates[1],
      kind: 'playoff',
    );
    await _audit(
      requestId,
      id,
      'playoff',
      'Added an explicit championship playoff',
      payload,
      match: match,
    );
    return match;
  });
  Future<void> complete(
    String id, {
    String? champion,
    bool shared = false,
    bool endEarly = false,
    required String reason,
    required String requestId,
  }) async => db.transaction(() async {
    final payload = jsonEncode([
      'complete',
      champion,
      shared,
      endEarly,
      reason.trim(),
    ]);
    if (await _done(requestId, id, payload)) {
      return;
    }
    final b = await required(id);
    _active(b);
    if (b.fixtures.any((f) => ['live', 'paused'].contains(f.phase))) {
      throw StateError(
        'Finish the open match before finalizing the competition.',
      );
    }
    final unfinished =
        b.fixtures.any(
          (f) =>
              f.kind == 'league' &&
              f.row['required'] == 1 &&
              (f.status != 'finished' || f.phase != 'finished'),
        ) ||
        b.fixtures.any(
          (f) =>
              f.kind == 'playoff' &&
              f.status != 'cancelled' &&
              f.phase != 'finished',
        ) ||
        b.competition.mode == 'winner_stays' &&
            b.fixtures
                    .where((f) => f.kind == 'league' && f.status == 'finished')
                    .length <
                b.competition.limit;
    if (unfinished && !endEarly) {
      throw StateError(
        'Required fixtures are unfinished. Explicitly end early with a reason to proceed.',
      );
    }
    if (endEarly) {
      _reason(reason);
    }
    if (!b.fixtures.any(
      (f) =>
          f.kind == 'league' && f.phase == 'finished' && f.status == 'finished',
    )) {
      throw StateError('Play at least one match before declaring a champion.');
    }
    final candidates = b.championCandidates;
    if (candidates.length > 1 &&
        !shared &&
        (champion == null || !candidates.contains(champion))) {
      throw StateError(
        'The leaders remain tied. Choose a shared title, playoff, or explicit administrator decision.',
      );
    }
    if (champion != null && !candidates.contains(champion)) {
      throw ArgumentError('Champion must be one of the eligible leaders.');
    }
    if (candidates.length > 1 && !shared) {
      _reason(reason);
    }
    final chosen = shared && candidates.length > 1
        ? null
        : champion ?? candidates.single;
    final method = chosen == null
        ? 'shared'
        : candidates.length > 1
        ? 'manual'
        : b.fixtures.any(
            (f) =>
                f.kind == 'playoff' &&
                f.phase == 'finished' &&
                f.scoreA != f.scoreB,
          )
        ? 'playoff'
        : b.competition.mode == 'winner_stays' &&
              b.competition.criterion == 'wins'
        ? 'wins'
        : 'standings';
    for (final f in b.fixtures.where(
      (f) => f.phase == 'scheduled' && f.status != 'cancelled',
    )) {
      await _cancel(f);
    }
    await db.customStatement(
      'INSERT INTO champion_decisions VALUES (?,?,?,?,?,?,?,?)',
      [
        id,
        chosen,
        method,
        jsonEncode(candidates),
        reason.trim(),
        endEarly ? 1 : 0,
        jsonEncode(b.table.map((r) => r.toJson()).toList()),
        clock.wallMillis,
      ],
    );
    await _audit(
      requestId,
      id,
      'complete',
      reason.trim().isEmpty
          ? 'Finalized according to configured rules'
          : reason.trim(),
      payload,
    );
    await db.customStatement(
      "UPDATE competitions SET status='completed' WHERE id=?",
      [id],
    );
  });
}
