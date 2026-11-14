import '../../../core/database/app_database.dart';

class AppSettings {
  const AppSettings({
    this.minutes = 10,
    this.generation = 'balanced',
    this.competition = 'round_robin',
    this.win = 3,
    this.draw = 1,
    this.loss = 0,
    this.cycles = 1,
    this.policy = 'both_rotate',
    this.limit = 6,
  });
  final int minutes, win, draw, loss, cycles, limit;
  final String generation, competition, policy;
  factory AppSettings.fromRow(Map<String, dynamic> r) => AppSettings(
    minutes: r['match_minutes'] as int,
    generation: r['generation_mode'] as String,
    competition: r['competition_mode'] as String,
    win: r['win_points'] as int,
    draw: r['draw_points'] as int,
    loss: r['loss_points'] as int,
    cycles: r['cycles'] as int,
    policy: r['draw_policy'] as String,
    limit: r['match_limit'] as int,
  );
}

class SettingsRepository {
  SettingsRepository(this.db);
  final AppDatabase db;
  Future<AppSettings> load() async => AppSettings.fromRow(
    (await db.rows('SELECT * FROM app_settings WHERE id=1')).single,
  );
  Future<void> save(AppSettings s) async {
    if (s.minutes < 1 ||
        s.minutes > 180 ||
        s.cycles < 1 ||
        s.cycles > 10 ||
        s.limit < 1 ||
        s.limit > 100 ||
        [s.win, s.draw, s.loss].any((v) => v < 0 || v > 100) ||
        !['balanced', 'random'].contains(s.generation) ||
        !['round_robin', 'winner_stays'].contains(s.competition) ||
        !['both_rotate', 'longest', 'manual'].contains(s.policy)) {
      throw ArgumentError('Check default duration and competition settings.');
    }
    await db.transaction(
      () => db.customStatement(
        '''UPDATE app_settings SET match_minutes=?,generation_mode=?,competition_mode=?,
      win_points=?,draw_points=?,loss_points=?,cycles=?,draw_policy=?,match_limit=? WHERE id=1''',
        [
          s.minutes,
          s.generation,
          s.competition,
          s.win,
          s.draw,
          s.loss,
          s.cycles,
          s.policy,
          s.limit,
        ],
      ),
    );
  }
}
