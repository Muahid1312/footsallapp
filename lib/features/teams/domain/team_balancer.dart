import 'dart:math';
import '../../players/domain/player.dart';

class BalancePlayer {
  const BalancePlayer(
    this.id, {
    this.rating,
    this.position = 'All-rounder',
    this.secondary,
    this.keeper = false,
  });
  factory BalancePlayer.fromPlayer(Player p) => BalancePlayer(
    p.id,
    rating: p.skillRating,
    position: p.preferredPosition,
    secondary: p.secondaryPosition,
    keeper: p.goalkeeperEligible,
  );
  final String id, position;
  final String? secondary;
  final int? rating;
  final bool keeper;
  double get skill =>
      rating != null && rating! >= 1 && rating! <= 10 ? rating!.toDouble() : 5;
  bool get unknown => rating == null || rating! < 1 || rating! > 10;
  bool covers(String role) =>
      position.trim().toLowerCase() == role.toLowerCase() ||
      secondary?.trim().toLowerCase() == role.toLowerCase();
}

class BalanceRequest {
  const BalanceRequest({
    required this.players,
    required this.teams,
    this.locks = const {},
    this.seed = 1,
    this.mode = 'balanced',
    this.iterations = 2000,
    this.searchNodes = 20000,
    this.allowUneven = false,
  });
  final List<BalancePlayer> players;
  final List<String> teams;
  final Map<String, String> locks;
  final int seed, iterations, searchNodes;
  final String mode;
  final bool allowUneven;
}

class TeamStrength {
  const TeamStrength(
    this.teamId,
    this.size,
    this.average,
    this.strength,
    this.keepers,
    this.positions,
  );
  final String teamId;
  final int size, keepers;
  final double average, strength;
  final Set<String> positions;
}

class BalanceResult {
  BalanceResult(
    this.assignments,
    this.metrics,
    this.objective,
    this.warnings,
    this.seed,
    this.method,
    this.evaluations,
  );
  final Map<String, List<String>> assignments;
  final List<TeamStrength> metrics;
  final double objective;
  final List<String> warnings;
  final int seed, evaluations;
  final String method;
  double get spread =>
      metrics.map((m) => m.strength).reduce(max) -
      metrics.map((m) => m.strength).reduce(min);
  String get quality => spread <= .75
      ? 'Close estimated strengths'
      : spread <= 1.5
      ? 'Moderate strength spread'
      : 'Wide strength spread';
}

List<TeamStrength> balanceMetrics(
  BalanceRequest r,
  Map<String, List<String>> map,
) {
  final byId = {for (final p in r.players) p.id: p};
  final meanSize = r.players.length / r.teams.length;
  return r.teams.map((id) {
    final ps = map[id]!.map((id) => byId[id]!).toList();
    final avg = ps.isEmpty
        ? 0.0
        : ps.fold<double>(0, (v, p) => v + p.skill) / ps.length;
    return TeamStrength(
      id,
      ps.length,
      avg,
      avg + .5 * (ps.length - meanSize),
      ps.where((p) => p.keeper).length,
      {
        'Defender',
        'Winger',
        'Pivot',
      }.where((role) => ps.any((p) => p.covers(role))).toSet(),
    );
  }).toList();
}

double balanceObjective(BalanceRequest r, Map<String, List<String>> map) {
  final metrics = balanceMetrics(r, map),
      mean = metrics.fold<double>(0, (v, m) => v + m.strength) / metrics.length;
  final size = r.players.length / r.teams.length;
  final available = {
    'Defender',
    'Winger',
    'Pivot',
  }.where((role) => r.players.any((p) => p.covers(role))).toSet();
  var total = 0.0;
  for (final m in metrics) {
    total +=
        pow(m.strength - mean, 2).toDouble() +
        .25 * pow(m.size - size, 2).toDouble();
    if (r.players.any((p) => p.keeper)) {
      total += 1000 * (m.keepers == 0 ? 1 : 0) + 100 * max(0, m.keepers - 1);
    }
    total += .8 * available.difference(m.positions).length;
  }
  return total;
}

void validateBalance(BalanceRequest r, Map<String, List<String>> map) {
  final expected = r.players.map((p) => p.id).toSet(),
      flat = map.values.expand((v) => v).toList();
  if (r.teams.length < 2 ||
      r.teams.toSet().length != r.teams.length ||
      expected.length != r.players.length ||
      r.players.length < r.teams.length ||
      map.length != r.teams.length ||
      !map.keys.toSet().containsAll(r.teams) ||
      flat.toSet().length != flat.length ||
      flat.length != expected.length ||
      !expected.containsAll(flat) ||
      map.values.any((v) => v.isEmpty)) {
    throw ArgumentError(
      'Every selected attendee must appear exactly once in a nonempty team.',
    );
  }
  for (final e in r.locks.entries) {
    if (!map.containsKey(e.value) || !map[e.value]!.contains(e.key)) {
      throw ArgumentError('A locked assignment cannot be moved.');
    }
  }
  final sizes = map.values.map((v) => v.length).toList();
  if (!r.allowUneven && sizes.reduce(max) - sizes.reduce(min) > 1) {
    throw ArgumentError(
      'Team sizes may differ by at most one. Explicitly allow uneven sizes to override.',
    );
  }
}

BalanceResult describeBalance(
  BalanceRequest r,
  Map<String, List<String>> map, {
  String method = 'Manual preview',
  int evaluations = 0,
}) {
  validateBalance(r, map);
  final metrics = balanceMetrics(r, map), warnings = <String>[];
  if (r.players.any((p) => p.unknown)) {
    warnings.add(
      'Missing/invalid ratings use a neutral estimate of 5. Review these ratings before confirming.',
    );
  }
  final keepers = r.players.where((p) => p.keeper).length;
  if (keepers < r.teams.length) {
    warnings.add(
      'Only $keepers eligible goalkeepers for ${r.teams.length} teams; full goalkeeper coverage is impossible.',
    );
  } else if (metrics.any((m) => m.keepers == 0)) {
    warnings.add(
      'Some teams lack a goalkeeper. Locks, capacity, or the search budget may prevent full coverage.',
    );
  }
  final missing = {
    'Defender',
    'Winger',
    'Pivot',
  }.where((role) => !r.players.any((p) => p.covers(role)));
  if (missing.isNotEmpty) {
    warnings.add(
      'No selected players list: ${missing.join(', ')}. Positional coverage cannot be guaranteed.',
    );
  }
  if (metrics.map((m) => m.size).reduce(max) -
          metrics.map((m) => m.size).reduce(min) >
      1) {
    warnings.add('Uneven sizes were explicitly allowed.');
  }
  return BalanceResult(
    {
      for (final e in map.entries) e.key: [...e.value],
    },
    metrics,
    balanceObjective(r, map),
    warnings,
    r.seed,
    method,
    evaluations,
  );
}

/// Pure, bounded, deterministic solver. Safe to run in Flutter compute().
BalanceResult generateBalance(BalanceRequest r) {
  if (r.teams.length < 2 ||
      r.teams.toSet().length != r.teams.length ||
      r.players.length < r.teams.length ||
      r.players.map((p) => p.id).toSet().length != r.players.length ||
      r.iterations < 0 ||
      r.iterations > 20000 ||
      r.searchNodes < 1 ||
      r.searchNodes > 100000 ||
      !['balanced', 'random'].contains(r.mode)) {
    throw ArgumentError(
      'Check unique attendees, teams, mode, and optimization limits.',
    );
  }
  final byId = {for (final p in r.players) p.id: p}, random = Random(r.seed);
  final locked = {for (final t in r.teams) t: <String>[]};
  for (final e in r.locks.entries) {
    if (!byId.containsKey(e.key) || !locked.containsKey(e.value)) {
      throw ArgumentError(
        'Locks must reference selected attendees and session teams.',
      );
    }
    locked[e.value]!.add(e.key);
  }
  final base = r.players.length ~/ r.teams.length,
      remainder = r.players.length % r.teams.length;
  final order = [...r.teams]..shuffle(random);
  final capacities = {for (final t in r.teams) t: base};
  final forced = order.where((t) => locked[t]!.length > base).toList();
  if (!r.allowUneven &&
      (forced.length > remainder ||
          forced.any((t) => locked[t]!.length > base + 1))) {
    throw ArgumentError(
      'Locked assignments make balanced team sizes impossible. Unlock players or explicitly allow uneven sizes.',
    );
  }
  final extras = [...forced, ...order.where((t) => !forced.contains(t))];
  for (var i = 0; i < remainder; i++) {
    capacities[extras[i]] = base + 1;
  }
  if (r.allowUneven) {
    for (final t in order) {
      while (capacities[t]! < locked[t]!.length) {
        final donor = order
            .where(
              (other) =>
                  other != t &&
                  capacities[other]! > max(1, locked[other]!.length),
            )
            .firstOrNull;
        if (donor == null) {
          throw ArgumentError(
            'Locks leave too few players to keep every team nonempty.',
          );
        }
        capacities[donor] = capacities[donor]! - 1;
        capacities[t] = capacities[t]! + 1;
      }
    }
  }
  final free = r.players.where((p) => !r.locks.containsKey(p.id)).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  free.shuffle(random);
  final tieOrder = {for (var i = 0; i < free.length; i++) free[i].id: i};
  if (r.mode == 'balanced') {
    free.sort((a, b) {
      final keeper = (b.keeper ? 1 : 0).compareTo(a.keeper ? 1 : 0);
      if (keeper != 0) {
        return keeper;
      }
      final skill = b.skill.compareTo(a.skill);
      return skill != 0 ? skill : tieOrder[a.id]!.compareTo(tieOrder[b.id]!);
    });
  }
  var best = {
    for (final e in locked.entries) e.key: [...e.value],
  };
  for (final p in free) {
    final possible = order
        .where((t) => best[t]!.length < capacities[t]!)
        .toList();
    if (r.mode == 'random') {
      best[possible.first]!.add(p.id);
      continue;
    }
    possible.sort((a, b) {
      if (p.keeper) {
        final ga = best[a]!.any((id) => byId[id]!.keeper),
            gb = best[b]!.any((id) => byId[id]!.keeper);
        if (ga != gb) {
          return ga ? 1 : -1;
        }
      }
      final sa = best[a]!.fold<double>(0, (v, id) => v + byId[id]!.skill),
          sb = best[b]!.fold<double>(0, (v, id) => v + byId[id]!.skill);
      final diff = (sa / capacities[a]!).compareTo(sb / capacities[b]!);
      return diff != 0 ? diff : order.indexOf(a).compareTo(order.indexOf(b));
    });
    best[possible.first]!.add(p.id);
  }
  validateBalance(r, best);
  var objective = balanceObjective(r, best), evaluations = 0;
  if (r.mode == 'balanced' && r.players.length <= 10 && r.teams.length <= 4) {
    final candidate = {
      for (final e in locked.entries) e.key: [...e.value],
    };
    void search(int index) {
      if (evaluations >= r.searchNodes) {
        return;
      }
      evaluations++;
      if (index == free.length) {
        final score = balanceObjective(r, candidate);
        if (score < objective - 1e-9) {
          objective = score;
          best = {
            for (final e in candidate.entries) e.key: [...e.value],
          };
        }
        return;
      }
      final emptyCapacities = <int>{};
      for (final t in order) {
        if (candidate[t]!.length >= capacities[t]!) {
          continue;
        }
        if (candidate[t]!.isEmpty && !emptyCapacities.add(capacities[t]!)) {
          continue;
        }
        candidate[t]!.add(free[index].id);
        search(index + 1);
        candidate[t]!.removeLast();
        if (evaluations >= r.searchNodes) {
          break;
        }
      }
    }

    search(0);
  }
  if (r.mode == 'balanced' && free.length >= 2) {
    final teamOf = {
      for (final e in best.entries)
        for (final id in e.value) id: e.key,
    };
    for (var i = 0; i < r.iterations; i++) {
      final a = free[random.nextInt(free.length)].id,
          b = free[random.nextInt(free.length)].id;
      final ta = teamOf[a]!, tb = teamOf[b]!;
      if (ta == tb) {
        continue;
      }
      final ia = best[ta]!.indexOf(a), ib = best[tb]!.indexOf(b);
      best[ta]![ia] = b;
      best[tb]![ib] = a;
      evaluations++;
      final score = balanceObjective(r, best);
      if (score < objective - 1e-9) {
        objective = score;
        teamOf[a] = tb;
        teamOf[b] = ta;
      } else {
        best[ta]![ia] = a;
        best[tb]![ib] = b;
      }
    }
  }
  return describeBalance(
    r,
    best,
    method: r.mode == 'random'
        ? 'Seeded random'
        : r.players.length <= 10 && r.teams.length <= 4
        ? 'Bounded search + local swaps'
        : 'Greedy + bounded local swaps',
    evaluations: evaluations,
  );
}
