const migrationV3 = <String>[
  '''CREATE TABLE competitions (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
    mode TEXT NOT NULL CHECK(mode IN ('round_robin','winner_stays')),
    status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','active','completed')),
    duration_seconds INTEGER NOT NULL CHECK(duration_seconds BETWEEN 60 AND 10800),
    win_points INTEGER NOT NULL CHECK(win_points BETWEEN 0 AND 100),
    draw_points INTEGER NOT NULL CHECK(draw_points BETWEEN 0 AND 100),
    loss_points INTEGER NOT NULL CHECK(loss_points BETWEEN 0 AND 100),
    cycles INTEGER NOT NULL CHECK(cycles BETWEEN 1 AND 10),
    draw_policy TEXT NOT NULL CHECK(draw_policy IN ('both_rotate','longest','manual')),
    champion_criterion TEXT NOT NULL CHECK(champion_criterion IN ('points','wins')),
    match_limit INTEGER NOT NULL CHECK(match_limit BETWEEN 1 AND 100),
    rotation_json TEXT NOT NULL DEFAULT '{}',created_at INTEGER NOT NULL,
    UNIQUE(id,session_id))''',
  "CREATE UNIQUE INDEX one_open_competition ON competitions(session_id) WHERE status IN ('draft','active')",
  '''CREATE TABLE competition_teams (
    competition_id TEXT NOT NULL, session_id TEXT NOT NULL,team_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK(ordinal>=0),PRIMARY KEY(competition_id,team_id),UNIQUE(competition_id,ordinal),
    FOREIGN KEY(competition_id,session_id) REFERENCES competitions(id,session_id) ON DELETE RESTRICT,
    FOREIGN KEY(team_id,session_id) REFERENCES session_teams(id,session_id) ON DELETE RESTRICT)''',
  '''CREATE TABLE competition_fixtures (
    id TEXT PRIMARY KEY,competition_id TEXT NOT NULL REFERENCES competitions(id) ON DELETE RESTRICT,
    match_id TEXT NOT NULL UNIQUE REFERENCES matches(id) ON DELETE RESTRICT,
    team_a_id TEXT NOT NULL,team_b_id TEXT NOT NULL,cycle INTEGER NOT NULL,round_number INTEGER NOT NULL,
    sequence INTEGER NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('league','playoff')),
    status TEXT NOT NULL CHECK(status IN ('pending','postponed','finished','cancelled')),
    required INTEGER NOT NULL DEFAULT 1 CHECK(required IN (0,1)),
    pair_key TEXT,UNIQUE(competition_id,pair_key),
    CHECK(team_a_id!=team_b_id),UNIQUE(competition_id,sequence),
    FOREIGN KEY(competition_id,team_a_id) REFERENCES competition_teams(competition_id,team_id) ON DELETE RESTRICT,
    FOREIGN KEY(competition_id,team_b_id) REFERENCES competition_teams(competition_id,team_id) ON DELETE RESTRICT)''',
  '''CREATE TABLE competition_applications (
    match_id TEXT NOT NULL REFERENCES matches(id),revision INTEGER NOT NULL,
    competition_id TEXT NOT NULL REFERENCES competitions(id),fixture_id TEXT NOT NULL REFERENCES competition_fixtures(id),
    before_state TEXT NOT NULL,after_state TEXT NOT NULL,reverted INTEGER NOT NULL DEFAULT 0 CHECK(reverted IN (0,1)),
    created_at INTEGER NOT NULL,PRIMARY KEY(match_id,revision))''',
  '''CREATE TABLE competition_admin_actions (
    id TEXT PRIMARY KEY,competition_id TEXT NOT NULL REFERENCES competitions(id),kind TEXT NOT NULL,
    match_id TEXT REFERENCES matches(id),revision INTEGER,reason TEXT NOT NULL CHECK(length(trim(reason))>0),
    payload TEXT NOT NULL,created_at INTEGER NOT NULL)''',
  "CREATE UNIQUE INDEX one_draw_resolution ON competition_admin_actions(match_id,revision) WHERE kind='draw_rotation'",
  '''CREATE TABLE champion_decisions (
    competition_id TEXT PRIMARY KEY REFERENCES competitions(id),champion_team_id TEXT,
    method TEXT NOT NULL CHECK(method IN ('standings','wins','shared','manual','playoff')),
    tied_teams_json TEXT NOT NULL,reason TEXT NOT NULL,ended_early INTEGER NOT NULL CHECK(ended_early IN (0,1)),
    standings_json TEXT NOT NULL,created_at INTEGER NOT NULL,
    FOREIGN KEY(competition_id,champion_team_id) REFERENCES competition_teams(competition_id,team_id))''',
  'ALTER TABLE matches ADD COLUMN result_revision INTEGER NOT NULL DEFAULT 0 CHECK(result_revision>=0)',
  'ALTER TABLE match_actions ADD COLUMN result_revision INTEGER NOT NULL DEFAULT 0',
  '''CREATE TABLE match_reopens (
    match_id TEXT NOT NULL REFERENCES matches(id),revision INTEGER NOT NULL,reason TEXT NOT NULL CHECK(length(trim(reason))>0),
    created_at INTEGER NOT NULL,PRIMARY KEY(match_id,revision))''',
  'DROP INDEX one_finish_action',
  "CREATE UNIQUE INDEX one_finish_per_revision ON match_actions(match_id,result_revision) WHERE action_type='finish'",
  'DROP TRIGGER phase_transition',
  'DROP TRIGGER finished_match_immutable',
  '''CREATE TRIGGER phase_transition BEFORE UPDATE OF phase ON matches
    WHEN NOT ((OLD.phase='scheduled' AND NEW.phase IN ('live','cancelled')) OR
    (OLD.phase='live' AND NEW.phase IN ('paused','finished')) OR
    (OLD.phase='paused' AND NEW.phase IN ('live','finished')) OR OLD.phase=NEW.phase OR
    (OLD.phase='finished' AND NEW.phase='paused' AND NEW.result_revision=OLD.result_revision+1 AND
      EXISTS(SELECT 1 FROM match_reopens WHERE match_id=OLD.id AND revision=NEW.result_revision)))
    BEGIN SELECT RAISE(ABORT,'Invalid match state transition'); END''',
  '''CREATE TRIGGER finished_match_immutable BEFORE UPDATE ON matches
    WHEN OLD.phase IN ('finished','cancelled') AND NOT
      (OLD.phase='finished' AND NEW.phase='paused' AND NEW.status='live'
       AND OLD.id=NEW.id AND OLD.session_id=NEW.session_id AND OLD.team_a_id=NEW.team_a_id AND OLD.team_b_id=NEW.team_b_id
       AND OLD.duration_seconds=NEW.duration_seconds AND OLD.started_at IS NEW.started_at AND OLD.ended_at IS NEW.ended_at
       AND NEW.result_revision=OLD.result_revision+1
       AND EXISTS(SELECT 1 FROM match_reopens WHERE match_id=OLD.id AND revision=NEW.result_revision))
    BEGIN SELECT RAISE(ABORT,'Final results require an audited administrative reopen'); END''',
  '''CREATE TRIGGER fixture_guard BEFORE INSERT ON competition_fixtures
    WHEN NOT EXISTS(SELECT 1 FROM matches m JOIN competitions c ON c.id=NEW.competition_id
      WHERE m.id=NEW.match_id AND m.session_id=c.session_id AND m.team_a_id=NEW.team_a_id
      AND m.team_b_id=NEW.team_b_id AND m.duration_seconds=c.duration_seconds AND c.status!='completed')
    OR (NEW.kind='league' AND (SELECT mode FROM competitions WHERE id=NEW.competition_id)='round_robin'
      AND (NEW.pair_key IS NULL OR NEW.pair_key != CAST(NEW.cycle AS TEXT)||':'||min(NEW.team_a_id,NEW.team_b_id)||'|'||max(NEW.team_a_id,NEW.team_b_id)))
    BEGIN SELECT RAISE(ABORT,'Fixture must match its competition teams, session, and duration'); END''',
  '''CREATE TRIGGER competition_start_guard BEFORE UPDATE OF phase ON matches
    WHEN NEW.phase='live' AND EXISTS(SELECT 1 FROM competition_fixtures f JOIN competitions c ON c.id=f.competition_id
      WHERE f.match_id=NEW.id AND (c.status!='active' OR f.status!='pending' OR EXISTS(
        SELECT 1 FROM competition_fixtures other JOIN matches m ON m.id=other.match_id
        WHERE other.competition_id=f.competition_id AND m.id!=NEW.id AND m.phase IN ('live','paused'))))
    BEGIN SELECT RAISE(ABORT,'Competition has another open match or this fixture is not ready'); END''',
  '''CREATE TRIGGER competition_settings_locked BEFORE UPDATE OF mode,duration_seconds,win_points,draw_points,loss_points,cycles,draw_policy,champion_criterion,match_limit ON competitions
    WHEN OLD.status!='draft'
    BEGIN SELECT RAISE(ABORT,'Active competition rules are locked'); END''',
  '''CREATE TRIGGER competition_completed_locked BEFORE UPDATE ON competitions WHEN OLD.status='completed'
    BEGIN SELECT RAISE(ABORT,'Completed competition is immutable'); END''',
  '''CREATE TRIGGER fixture_identity_locked BEFORE UPDATE OF competition_id,match_id,team_a_id,team_b_id,cycle,round_number,sequence,kind,pair_key ON competition_fixtures
    BEGIN SELECT RAISE(ABORT,'Fixture identity is immutable'); END''',
  '''CREATE TRIGGER fixture_final_locked BEFORE UPDATE ON competition_fixtures
    WHEN EXISTS(SELECT 1 FROM competitions WHERE id=OLD.competition_id AND status='completed')
    BEGIN SELECT RAISE(ABORT,'Completed competition fixtures are immutable'); END''',
  'CREATE INDEX fixtures_competition ON competition_fixtures(competition_id,status,sequence)',
  '''CREATE TRIGGER fixture_status_guard BEFORE UPDATE OF status ON competition_fixtures
    WHEN (NEW.status='finished' AND NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase='finished'))
      OR (NEW.status='cancelled' AND NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase='cancelled'))
      OR (OLD.status='finished' AND NEW.status!='finished' AND NOT EXISTS(SELECT 1 FROM matches m JOIN match_reopens r
        ON r.match_id=m.id AND r.revision=m.result_revision WHERE m.id=NEW.match_id AND m.phase='paused'))
    BEGIN SELECT RAISE(ABORT,'Fixture state must agree with its audited match state'); END''',
  '''CREATE TRIGGER reopen_guard BEFORE INSERT ON match_reopens
    WHEN NOT EXISTS(SELECT 1 FROM matches m JOIN competition_fixtures f ON f.match_id=m.id
      JOIN competitions c ON c.id=f.competition_id WHERE m.id=NEW.match_id AND m.phase='finished'
      AND c.status='active' AND NEW.revision=m.result_revision+1)
    BEGIN SELECT RAISE(ABORT,'Only active competition results can be reopened'); END''',
  '''CREATE TRIGGER competition_status_guard BEFORE UPDATE OF status ON competitions
    WHEN NOT (NEW.status=OLD.status OR (OLD.status='draft' AND NEW.status='active') OR (OLD.status='active' AND NEW.status='completed'))
    BEGIN SELECT RAISE(ABORT,'Invalid competition transition'); END''',
  '''CREATE TRIGGER applications_immutable BEFORE UPDATE ON competition_applications
    WHEN NOT (OLD.reverted=0 AND NEW.reverted=1 AND OLD.match_id=NEW.match_id AND OLD.revision=NEW.revision
      AND OLD.competition_id=NEW.competition_id AND OLD.fixture_id=NEW.fixture_id AND OLD.before_state=NEW.before_state
      AND OLD.after_state=NEW.after_state AND OLD.created_at=NEW.created_at AND EXISTS(
        SELECT 1 FROM match_reopens r JOIN matches m ON m.id=r.match_id WHERE m.id=OLD.match_id
        AND m.phase='paused' AND r.revision=m.result_revision AND r.revision=OLD.revision+1))
    BEGIN SELECT RAISE(ABORT,'Result application history is immutable'); END''',
  '''CREATE TRIGGER application_insert_guard BEFORE INSERT ON competition_applications
    WHEN NOT EXISTS(SELECT 1 FROM competition_fixtures f JOIN matches m ON m.id=f.match_id
      JOIN competitions c ON c.id=f.competition_id WHERE f.id=NEW.fixture_id AND f.match_id=NEW.match_id
      AND f.competition_id=NEW.competition_id AND f.status='finished' AND m.phase='finished'
      AND m.result_revision=NEW.revision AND c.status='active')
    BEGIN SELECT RAISE(ABORT,'Only a finalized competition fixture can be applied'); END''',
];

List<String> get integrityTriggersV3 => [
  for (final table in [
    'champion_decisions',
    'competition_admin_actions',
    'match_reopens',
  ])
    for (final operation in ['UPDATE', 'DELETE'])
      'CREATE TRIGGER audit_${table}_$operation BEFORE $operation ON $table BEGIN SELECT RAISE(ABORT,\'Competition audit is immutable\'); END',
  for (final table in [
    'competitions',
    'competition_teams',
    'competition_fixtures',
    'competition_applications',
  ])
    'CREATE TRIGGER no_delete_$table BEFORE DELETE ON $table BEGIN SELECT RAISE(ABORT,\'Competition history cannot be deleted\'); END',
  '''CREATE TRIGGER competition_roster_locked BEFORE UPDATE ON competition_teams
    BEGIN SELECT RAISE(ABORT,'Competition team selection is immutable'); END''',
  '''CREATE TRIGGER competition_team_insert_guard BEFORE INSERT ON competition_teams
    WHEN NOT EXISTS(SELECT 1 FROM competitions WHERE id=NEW.competition_id AND status='draft')
    BEGIN SELECT RAISE(ABORT,'Competition team selection is locked'); END''',
];
