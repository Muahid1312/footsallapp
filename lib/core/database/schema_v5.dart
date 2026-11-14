const migrationV5 = <String>[
  "ALTER TABLE players ADD COLUMN preferred_foot TEXT NOT NULL DEFAULT 'unknown' CHECK(preferred_foot IN ('unknown','left','right','both'))",
  '''CREATE TABLE app_settings (
    id INTEGER PRIMARY KEY CHECK(id=1),match_minutes INTEGER NOT NULL DEFAULT 10 CHECK(match_minutes BETWEEN 1 AND 180),
    generation_mode TEXT NOT NULL DEFAULT 'balanced' CHECK(generation_mode IN ('balanced','random')),
    competition_mode TEXT NOT NULL DEFAULT 'round_robin' CHECK(competition_mode IN ('round_robin','winner_stays')),
    win_points INTEGER NOT NULL DEFAULT 3 CHECK(win_points BETWEEN 0 AND 100),
    draw_points INTEGER NOT NULL DEFAULT 1 CHECK(draw_points BETWEEN 0 AND 100),
    loss_points INTEGER NOT NULL DEFAULT 0 CHECK(loss_points BETWEEN 0 AND 100),
    cycles INTEGER NOT NULL DEFAULT 1 CHECK(cycles BETWEEN 1 AND 10),
    draw_policy TEXT NOT NULL DEFAULT 'both_rotate' CHECK(draw_policy IN ('both_rotate','longest','manual')),
    match_limit INTEGER NOT NULL DEFAULT 6 CHECK(match_limit BETWEEN 1 AND 100))''',
  'INSERT INTO app_settings(id) VALUES (1)',
];
