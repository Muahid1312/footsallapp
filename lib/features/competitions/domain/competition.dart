import 'dart:convert';
import '../../teams/domain/team.dart';

class FixturePlan {
  const FixturePlan(this.a, this.b, this.cycle, this.round);
  final String a, b;
  final int cycle, round;
}

List<FixturePlan> roundRobin(List<String> ids, int cycles) {
  if (ids.length < 2 ||
      ids.toSet().length != ids.length ||
      cycles < 1 ||
      cycles > 10) {
    throw ArgumentError('Choose unique teams and 1–10 cycles.');
  }
  final result = <FixturePlan>[];
  for (var cycle = 1; cycle <= cycles; cycle++) {
    if (ids.length == 3) {
      result.addAll([
        FixturePlan(ids[0], ids[1], cycle, 1),
        FixturePlan(ids[1], ids[2], cycle, 2),
        FixturePlan(ids[2], ids[0], cycle, 3),
      ]);
      continue;
    }
    final ring = <String?>[...ids, if (ids.length.isOdd) null];
    Set<String> previous = {};
    for (var round = 1; round < ring.length; round++) {
      final pairs = <FixturePlan>[];
      for (var i = 0; i < ring.length ~/ 2; i++) {
        final a = ring[i], b = ring[ring.length - 1 - i];
        if (a != null && b != null) {
          pairs.add(FixturePlan(a, b, cycle, round));
        }
      }
      // One pitch: prefer a pairing whose teams rested during the last fixture.
      while (pairs.isNotEmpty) {
        final index = pairs.indexWhere(
          (p) => !previous.contains(p.a) && !previous.contains(p.b),
        );
        final pair = pairs.removeAt(index < 0 ? 0 : index);
        result.add(pair);
        previous = {pair.a, pair.b};
      }
      ring.insert(1, ring.removeLast());
    }
  }
  return result;
}

class RotationState {
  RotationState(this.playing, this.queue, this.entered, {this.awaitingMatch});
  final List<String> playing, queue;
  final Map<String, int> entered;
  final String? awaitingMatch;
  factory RotationState.initial(List<String> ids) => RotationState(
    ids.take(2).toList(),
    ids.skip(2).toList(),
    {ids[0]: 0, ids[1]: 0},
  );
  factory RotationState.decode(String value) {
    final r = jsonDecode(value) as Map<String, dynamic>;
    return RotationState(
      List<String>.from(r['playing'] as List),
      List<String>.from(r['queue'] as List),
      Map<String, int>.from(r['entered'] as Map),
      awaitingMatch: r['awaiting'] as String?,
    );
  }
  String encode() => jsonEncode({
    'playing': playing,
    'queue': queue,
    'entered': entered,
    'awaiting': awaitingMatch,
  });
}

RotationState rotate(
  RotationState state, {
  required int goalsA,
  required int goalsB,
  required String policy,
  required int sequence,
  required String matchId,
  String? manualStayer,
  bool both = false,
}) {
  final current = state.playing;
  if (current.length != 2) {
    throw StateError('Invalid persisted pairing.');
  }
  if (goalsA == goalsB && policy == 'manual' && manualStayer == null && !both) {
    return RotationState([...current], [...state.queue], {
      ...state.entered,
    }, awaitingMatch: matchId);
  }
  if (manualStayer != null && !current.contains(manualStayer)) {
    throw ArgumentError('Choose a playing team.');
  }
  final queue = [...state.queue];
  final entered = {...state.entered};
  if (queue.isEmpty) {
    return RotationState([...current], queue, entered);
  }
  if (goalsA == goalsB &&
      (both || policy == 'both_rotate') &&
      queue.length >= 2) {
    final next = [queue.removeAt(0), queue.removeAt(0)];
    queue.addAll(current);
    for (final t in next) {
      entered[t] = sequence;
    }
    return RotationState(next, queue, entered);
  }
  final longest = (entered[current[0]] ?? 0) <= (entered[current[1]] ?? 0)
      ? current[0]
      : current[1];
  final staying = goalsA != goalsB
      ? (goalsA > goalsB ? current[0] : current[1])
      : manualStayer ?? current.firstWhere((t) => t != longest);
  final outgoing = current.firstWhere((t) => t != staying),
      incoming = queue.removeAt(0);
  queue.add(outgoing);
  entered[incoming] = sequence;
  return RotationState([staying, incoming], queue, entered);
}

class Competition {
  Competition(this.row);
  final Map<String, dynamic> row;
  String get id => row['id'] as String;
  String get sessionId => row['session_id'] as String;
  String get mode => row['mode'] as String;
  String get status => row['status'] as String;
  String get drawPolicy => row['draw_policy'] as String;
  String get criterion => row['champion_criterion'] as String;
  int get duration => row['duration_seconds'] as int;
  int get cycles => row['cycles'] as int;
  int get limit => row['match_limit'] as int;
  int get win => row['win_points'] as int;
  int get draw => row['draw_points'] as int;
  int get loss => row['loss_points'] as int;
  RotationState get rotation =>
      RotationState.decode(row['rotation_json'] as String);
}

class CompetitionFixture {
  CompetitionFixture(this.row);
  final Map<String, dynamic> row;
  String get id => row['id'] as String;
  String get matchId => row['match_id'] as String;
  String get a => row['team_a_id'] as String;
  String get b => row['team_b_id'] as String;
  String get status => row['status'] as String;
  String get phase => row['phase'] as String;
  String get kind => row['kind'] as String;
  int get sequence => row['sequence'] as int;
  int get round => row['round_number'] as int;
  int get cycle => row['cycle'] as int;
  int get scoreA => row['score_a'] as int;
  int get scoreB => row['score_b'] as int;
}

class Standing {
  Standing(this.teamId);
  final String teamId;
  int played = 0,
      won = 0,
      drawn = 0,
      lost = 0,
      goalsFor = 0,
      goalsAgainst = 0,
      points = 0,
      position = 0;
  int get difference => goalsFor - goalsAgainst;
  List<int> get rankKey => [points, difference, goalsFor];
  Map<String, Object> toJson() => {
    'team': teamId,
    'position': position,
    'played': played,
    'won': won,
    'drawn': drawn,
    'lost': lost,
    'gf': goalsFor,
    'ga': goalsAgainst,
    'gd': difference,
    'points': points,
  };
}

int compareKeys(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    final cmp = b[i].compareTo(a[i]);
    if (cmp != 0) {
      return cmp;
    }
  }
  return 0;
}

List<Standing> standings(
  List<String> teams,
  List<CompetitionFixture> fixtures, {
  required int win,
  required int draw,
  required int loss,
}) {
  final rows = {for (final id in teams) id: Standing(id)};
  final results = fixtures
      .where(
        (f) =>
            f.kind == 'league' &&
            f.status == 'finished' &&
            f.phase == 'finished',
      )
      .toList();
  void apply(Standing a, int ga, int gb) {
    a.played++;
    a.goalsFor += ga;
    a.goalsAgainst += gb;
    if (ga > gb) {
      a.won++;
      a.points += win;
    } else if (ga == gb) {
      a.drawn++;
      a.points += draw;
    } else {
      a.lost++;
      a.points += loss;
    }
  }

  for (final f in results) {
    apply(rows[f.a]!, f.scoreA, f.scoreB);
    apply(rows[f.b]!, f.scoreB, f.scoreA);
  }
  final sorted = rows.values.toList()
    ..sort((a, b) {
      final c = compareKeys(a.rankKey, b.rankKey);
      return c != 0
          ? c
          : teams.indexOf(a.teamId).compareTo(teams.indexOf(b.teamId));
    });
  final output = <Standing>[];
  for (var start = 0; start < sorted.length;) {
    var end = start + 1;
    while (end < sorted.length &&
        compareKeys(sorted[start].rankKey, sorted[end].rankKey) == 0) {
      end++;
    }
    final group = sorted.sublist(start, end),
        ids = group.map((r) => r.teamId).toSet();
    final mini = {for (final id in ids) id: Standing(id)};
    var balanced = group.length > 1;
    int? pairCount;
    for (var a = 0; a < group.length; a++) {
      for (var b = a + 1; b < group.length; b++) {
        final count = results
            .where(
              (f) => {f.a, f.b}.containsAll([group[a].teamId, group[b].teamId]),
            )
            .length;
        pairCount ??= count;
        if (count == 0 || count != pairCount) {
          balanced = false;
        }
      }
    }
    if (balanced) {
      for (final f in results.where(
        (f) => ids.contains(f.a) && ids.contains(f.b),
      )) {
        apply(mini[f.a]!, f.scoreA, f.scoreB);
        apply(mini[f.b]!, f.scoreB, f.scoreA);
      }
      group.sort((a, b) {
        final c = compareKeys(mini[a.teamId]!.rankKey, mini[b.teamId]!.rankKey);
        return c != 0
            ? c
            : teams.indexOf(a.teamId).compareTo(teams.indexOf(b.teamId));
      });
    }
    for (var i = 0; i < group.length; i++) {
      final same =
          i > 0 &&
          (!balanced ||
              compareKeys(
                    mini[group[i].teamId]!.rankKey,
                    mini[group[i - 1].teamId]!.rankKey,
                  ) ==
                  0);
      group[i].position = same ? group[i - 1].position : output.length + 1;
      output.add(group[i]);
    }
    start = end;
  }
  return output;
}

class CompetitionBundle {
  CompetitionBundle(
    this.competition,
    this.teams,
    this.fixtures,
    this.table,
    this.decision,
    this.history,
  );
  final Competition competition;
  final List<SessionTeam> teams;
  final List<CompetitionFixture> fixtures;
  final List<Standing> table;
  final Map<String, dynamic>? decision;
  final List<Map<String, dynamic>> history;
  String teamName(String id) =>
      teams.where((t) => t.id == id).firstOrNull?.name ?? 'Unknown team';
  List<String> get candidates {
    if (competition.mode == 'winner_stays' && competition.criterion == 'wins') {
      final max = table.fold<int>(0, (v, r) => r.won > v ? r.won : v);
      return table.where((r) => r.won == max).map((r) => r.teamId).toList();
    }
    if (competition.mode == 'winner_stays') {
      final max = table.fold<int>(0, (v, r) => r.points > v ? r.points : v);
      return table.where((r) => r.points == max).map((r) => r.teamId).toList();
    }
    return table.where((r) => r.position == 1).map((r) => r.teamId).toList();
  }

  List<String> get championCandidates {
    final playoffs = fixtures
        .where((f) => f.kind == 'playoff' && f.status != 'cancelled')
        .toList();
    if (playoffs.isNotEmpty) {
      final f = playoffs.last;
      if (f.phase == 'finished' && f.scoreA != f.scoreB) {
        return [f.scoreA > f.scoreB ? f.a : f.b];
      }
    }
    return candidates;
  }
}
