import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/features/teams/domain/team_balancer.dart';

void main() {
  List<BalancePlayer> players(int n) => [
    for (var i = 0; i < n; i++) BalancePlayer('p$i', rating: i % 10 + 1),
  ];
  test('two teams balance skill estimates without losing membership', () {
    final r = BalanceRequest(
      players: [
        for (final n in [10, 9, 8, 1, 2, 3]) BalancePlayer('$n', rating: n),
      ],
      teams: ['a', 'b'],
    );
    final result = generateBalance(r);
    validateBalance(r, result.assignments);
    expect(result.spread, lessThan(.75));
  });
  test('three teams use equal capacity and bounded optimization', () {
    final r = BalanceRequest(players: players(9), teams: ['a', 'b', 'c']);
    final result = generateBalance(r);
    expect(result.metrics.map((m) => m.size), [3, 3, 3]);
    expect(result.spread, lessThan(1));
  });
  test('uneven selected counts distribute within one player', () {
    final r = BalanceRequest(players: players(11), teams: ['a', 'b', 'c']);
    final result = generateBalance(r);
    expect(result.metrics.map((m) => m.size).toList()..sort(), [3, 4, 4]);
    validateBalance(r, result.assignments);
  });
  test('goalkeepers spread when the roster and locks permit coverage', () {
    final ps = [
      for (var i = 0; i < 9; i++)
        BalancePlayer(
          'p$i',
          rating: 5,
          keeper: i < 3,
          position: i < 3 ? 'Goalkeeper' : 'Winger',
        ),
    ];
    final result = generateBalance(
      BalanceRequest(players: ps, teams: ['a', 'b', 'c']),
    );
    expect(result.metrics.every((m) => m.keepers == 1), isTrue);
  });
  test('locked players stay on their chosen team', () {
    final r = BalanceRequest(
      players: players(9),
      teams: ['a', 'b', 'c'],
      locks: {'p0': 'c', 'p8': 'a'},
    );
    final result = generateBalance(r);
    expect(result.assignments['c'], contains('p0'));
    expect(result.assignments['a'], contains('p8'));
  });
  test('infeasible locks require an explicit uneven override', () {
    final locks = {for (var i = 0; i < 4; i++) 'p$i': 'a'};
    expect(
      () => generateBalance(
        BalanceRequest(players: players(6), teams: ['a', 'b'], locks: locks),
      ),
      throwsArgumentError,
    );
    final r = BalanceRequest(
      players: players(6),
      teams: ['a', 'b'],
      locks: locks,
      allowUneven: true,
    );
    final result = generateBalance(r);
    expect(result.metrics.map((m) => m.size), [4, 2]);
    validateBalance(r, result.assignments);
  });
  test('even an override never creates an empty team', () {
    expect(
      () => generateBalance(
        BalanceRequest(
          players: players(4),
          teams: ['a', 'b'],
          locks: {for (var i = 0; i < 4; i++) 'p$i': 'a'},
          allowUneven: true,
        ),
      ),
      throwsArgumentError,
    );
  });
  test('missing ratings use a disclosed neutral estimate', () {
    final r = BalanceRequest(
      players: [const BalancePlayer('unknown'), ...players(3)],
      teams: ['a', 'b'],
    );
    final result = generateBalance(r);
    expect(
      result.warnings.any((w) => w.contains('Missing/invalid ratings')),
      isTrue,
    );
    expect(r.players.first.skill, 5);
    expect(r.players.first.rating, isNull);
  });
  test(
    'impossible positional coverage produces a warning, not a fake guarantee',
    () {
      final result = generateBalance(
        BalanceRequest(players: players(6), teams: ['a', 'b']),
      );
      expect(
        result.warnings.any(
          (w) => w.contains('Positional coverage cannot be guaranteed'),
        ),
        isTrue,
      );
      expect(result.quality.toLowerCase(), isNot(contains('perfect')));
    },
  );
  test('fixed seed reproduces larger greedy/swap results', () {
    final r = BalanceRequest(
      players: players(24),
      teams: ['a', 'b', 'c', 'd'],
      seed: 321,
      iterations: 300,
    );
    expect(generateBalance(r).assignments, generateBalance(r).assignments);
  });
  test('seeded random generation also honors locks and capacities', () {
    final r = BalanceRequest(
      players: players(13),
      teams: ['a', 'b', 'c'],
      mode: 'random',
      seed: 7,
      locks: {'p0': 'b'},
    );
    final result = generateBalance(r);
    validateBalance(r, result.assignments);
    expect(result.assignments, generateBalance(r).assignments);
  });
  test('duplicate attendees and absent-player locks are rejected', () {
    expect(
      () => generateBalance(
        BalanceRequest(
          players: [...players(3), players(1).first],
          teams: ['a', 'b'],
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => generateBalance(
        BalanceRequest(
          players: players(4),
          teams: ['a', 'b'],
          locks: {'absent': 'a'},
        ),
      ),
      throwsArgumentError,
    );
  });
  test(
    'every selected player appears exactly once and nobody else appears',
    () {
      final r = BalanceRequest(
        players: players(19),
        teams: ['a', 'b', 'c', 'd'],
      );
      final result = generateBalance(r),
          ids = result.assignments.values.expand((ids) => ids).toList();
      expect(ids.length, 19);
      expect(ids.toSet(), r.players.map((p) => p.id).toSet());
    },
  );
  test(
    'strength compares averages plus explicit size advantage, not raw sums',
    () {
      final r = BalanceRequest(
        players: [for (var i = 0; i < 5; i++) BalancePlayer('p$i', rating: 10)],
        teams: ['a', 'b'],
      );
      final m = balanceMetrics(r, {
        'a': ['p0', 'p1', 'p2'],
        'b': ['p3', 'p4'],
      });
      expect(m.map((m) => m.average), [10, 10]);
      expect(m[0].strength - m[1].strength, .5);
    },
  );
  test('bounded search and swap attempts respect the work budget', () {
    final r = BalanceRequest(
      players: players(10),
      teams: ['a', 'b'],
      searchNodes: 1,
      iterations: 8,
    );
    final result = generateBalance(r);
    expect(result.evaluations, lessThanOrEqualTo(9));
    validateBalance(r, result.assignments);
    expect(
      () => generateBalance(
        BalanceRequest(
          players: players(4),
          teams: ['a', 'b'],
          iterations: 20001,
        ),
      ),
      throwsArgumentError,
    );
  });
  test('manual swaps cannot break a lock or duplicate an attendee', () {
    final r = BalanceRequest(
      players: players(4),
      teams: ['a', 'b'],
      locks: {'p0': 'a'},
    );
    expect(
      () => validateBalance(r, {
        'a': ['p1', 'p2'],
        'b': ['p0', 'p3'],
      }),
      throwsArgumentError,
    );
    expect(
      () => validateBalance(r, {
        'a': ['p0', 'p1'],
        'b': ['p1', 'p2'],
      }),
      throwsArgumentError,
    );
  });
}
