const migrationV4 = <String>[
  'ALTER TABLE players ADD COLUMN secondary_position TEXT',
  'ALTER TABLE players ADD COLUMN goalkeeper_eligible INTEGER NOT NULL DEFAULT 0 CHECK(goalkeeper_eligible IN (0,1))',
  "UPDATE players SET goalkeeper_eligible=1 WHERE lower(trim(preferred_position))='goalkeeper'",
  '''CREATE TABLE player_rating_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,player_id TEXT NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
    old_rating INTEGER CHECK(old_rating BETWEEN 1 AND 10),new_rating INTEGER NOT NULL CHECK(new_rating BETWEEN 1 AND 10),
    changed_at INTEGER NOT NULL,description TEXT NOT NULL)''',
  '''INSERT INTO player_rating_history(player_id,new_rating,changed_at,description)
    SELECT id,skill_rating,CAST(strftime('%s','now') AS INTEGER)*1000,
    'Imported current rating; earlier rating history is unavailable' FROM players''',
  '''CREATE TRIGGER rating_initial AFTER INSERT ON players BEGIN
    INSERT INTO player_rating_history(player_id,new_rating,changed_at,description)
    VALUES(NEW.id,NEW.skill_rating,NEW.created_at,'Initial administrator rating'); END''',
  '''CREATE TRIGGER rating_update AFTER UPDATE OF skill_rating ON players WHEN NEW.skill_rating!=OLD.skill_rating BEGIN
    INSERT INTO player_rating_history(player_id,old_rating,new_rating,changed_at,description)
    VALUES(NEW.id,OLD.skill_rating,NEW.skill_rating,NEW.updated_at,'Skill rating updated'); END''',
  'CREATE INDEX rating_history_player ON player_rating_history(player_id,id)',
  '''CREATE TABLE team_assignment_locks (
    session_id TEXT NOT NULL,player_id TEXT NOT NULL,team_id TEXT NOT NULL,
    PRIMARY KEY(session_id,player_id),
    FOREIGN KEY(session_id,player_id) REFERENCES session_attendance(session_id,player_id) ON DELETE RESTRICT,
    FOREIGN KEY(team_id,session_id) REFERENCES session_teams(id,session_id) ON DELETE RESTRICT)''',
  '''CREATE TABLE session_mvp_settings (
    session_id TEXT PRIMARY KEY REFERENCES sessions(id),goal_weight INTEGER NOT NULL DEFAULT 4 CHECK(goal_weight BETWEEN -100 AND 100),
    assist_weight INTEGER NOT NULL DEFAULT 3 CHECK(assist_weight BETWEEN -100 AND 100),
    win_weight INTEGER NOT NULL DEFAULT 2 CHECK(win_weight BETWEEN -100 AND 100),
    foul_weight INTEGER NOT NULL DEFAULT -1 CHECK(foul_weight BETWEEN -100 AND 100))''',
  '''CREATE TABLE session_mvp_decisions (
    id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),revision INTEGER NOT NULL CHECK(revision>=1),
    player_id TEXT REFERENCES players(id),method TEXT NOT NULL CHECK(method IN ('calculated','shared','override')),
    selected_ids_json TEXT NOT NULL,calculation_json TEXT NOT NULL,reason TEXT,created_at INTEGER NOT NULL,
    UNIQUE(session_id,revision),CHECK((method='shared')=(player_id IS NULL)))''',
  'CREATE INDEX events_match_scorer ON match_events(match_id,player_id,event_type)',
  'CREATE INDEX events_match_assist ON match_events(match_id,related_player_id)',
  '''CREATE VIEW analytics_valid_events AS SELECT e.* FROM match_events e JOIN matches m ON m.id=e.match_id
    WHERE m.phase='finished' AND e.team_id IN (m.team_a_id,m.team_b_id)
    AND NOT EXISTS(SELECT 1 FROM competition_fixtures f WHERE f.match_id=m.id AND f.status!='finished')
    AND NOT EXISTS(SELECT 1 FROM match_actions a WHERE a.target_event_id=e.id)
    AND (e.player_id IS NULL OR EXISTS(SELECT 1 FROM match_lineup_stints s WHERE s.match_id=e.match_id AND s.team_id=e.team_id
      AND s.player_id=e.player_id AND s.entered_millis<=COALESCE(e.elapsed_millis,e.elapsed_seconds*1000)
      AND s.left_millis>=COALESCE(e.elapsed_millis,e.elapsed_seconds*1000)))
    AND (e.related_player_id IS NULL OR EXISTS(SELECT 1 FROM match_lineup_stints s WHERE s.match_id=e.match_id AND s.team_id=e.team_id
      AND s.player_id=e.related_player_id AND s.entered_millis<=COALESCE(e.elapsed_millis,e.elapsed_seconds*1000)
      AND s.left_millis>=COALESCE(e.elapsed_millis,e.elapsed_seconds*1000)))''',
  '''CREATE VIEW analytics_match_scores AS SELECT m.*,
    (SELECT COUNT(*) FROM analytics_valid_events e WHERE e.match_id=m.id AND
      ((e.event_type='goal' AND e.team_id=m.team_a_id) OR (e.event_type='own_goal' AND e.team_id=m.team_b_id))) AS score_a,
    (SELECT COUNT(*) FROM analytics_valid_events e WHERE e.match_id=m.id AND
      ((e.event_type='goal' AND e.team_id=m.team_b_id) OR (e.event_type='own_goal' AND e.team_id=m.team_a_id))) AS score_b
    FROM matches m WHERE m.phase='finished'
    AND NOT EXISTS(SELECT 1 FROM competition_fixtures f WHERE f.match_id=m.id AND f.status!='finished')''',
  '''CREATE VIEW analytics_player_matches AS SELECT DISTINCT s.player_id,s.team_id,m.id AS match_id,m.session_id,
    m.ended_at,m.duration_seconds,ss.date AS session_date,ss.location_name,t.name AS team_name,
    CASE WHEN s.team_id=m.team_a_id THEN m.score_a ELSE m.score_b END AS goals_for,
    CASE WHEN s.team_id=m.team_a_id THEN m.score_b ELSE m.score_a END AS goals_against,
    (SELECT COUNT(*) FROM analytics_valid_events e WHERE e.match_id=m.id AND e.event_type='goal' AND e.player_id=s.player_id) AS goals,
    (SELECT COUNT(*) FROM analytics_valid_events e WHERE e.match_id=m.id AND e.event_type='goal' AND e.related_player_id=s.player_id) AS assists,
    (SELECT COUNT(*) FROM analytics_valid_events e WHERE e.match_id=m.id AND e.event_type='foul' AND e.player_id=s.player_id) AS fouls,
    (SELECT COALESCE(SUM(x.left_millis-x.entered_millis),0) FROM match_lineup_stints x WHERE x.match_id=m.id
      AND x.player_id=s.player_id AND x.left_millis>x.entered_millis) AS playing_millis
    FROM match_lineup_stints s JOIN analytics_match_scores m ON m.id=s.match_id
    JOIN sessions ss ON ss.id=m.session_id JOIN session_teams t ON t.id=s.team_id
    WHERE s.team_id IN (m.team_a_id,m.team_b_id) AND (s.left_millis>s.entered_millis OR EXISTS(
      SELECT 1 FROM analytics_valid_events e WHERE e.match_id=m.id AND e.team_id=s.team_id
      AND (e.player_id=s.player_id OR e.related_player_id=s.player_id)
      AND COALESCE(e.elapsed_millis,e.elapsed_seconds*1000) BETWEEN s.entered_millis AND s.left_millis))''',
  '''CREATE TRIGGER mvp_settings_locked BEFORE UPDATE ON session_mvp_settings
    WHEN EXISTS(SELECT 1 FROM session_mvp_decisions WHERE session_id=OLD.session_id)
    BEGIN SELECT RAISE(ABORT,'MVP calculation weights are locked after confirmation'); END''',
  '''CREATE TRIGGER mvp_decision_guard BEFORE INSERT ON session_mvp_decisions
    WHEN NOT EXISTS(SELECT 1 FROM sessions WHERE id=NEW.session_id AND status='completed')
    OR NOT EXISTS(SELECT 1 FROM analytics_player_matches WHERE session_id=NEW.session_id)
    OR (NEW.player_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM analytics_player_matches WHERE session_id=NEW.session_id AND player_id=NEW.player_id))
    OR NEW.revision!=COALESCE((SELECT MAX(revision)+1 FROM session_mvp_decisions WHERE session_id=NEW.session_id),1)
    BEGIN SELECT RAISE(ABORT,'Final MVP awards require a completed session, eligible participation, and the next revision'); END''',
];

List<String> get integrityTriggersV4 => [
  for (final table in ['player_rating_history', 'session_mvp_decisions'])
    for (final operation in ['UPDATE', 'DELETE'])
      'CREATE TRIGGER immutable_${table}_$operation BEFORE $operation ON $table BEGIN SELECT RAISE(ABORT,\'Rating and award history is immutable\'); END',
  'CREATE TRIGGER mvp_settings_no_delete BEFORE DELETE ON session_mvp_settings BEGIN SELECT RAISE(ABORT,\'MVP settings cannot be deleted\'); END',
  for (final operation in ['INSERT', 'UPDATE', 'DELETE'])
    '''CREATE TRIGGER locks_guard_$operation BEFORE $operation ON team_assignment_locks
      WHEN NOT EXISTS(SELECT 1 FROM sessions WHERE id=${operation == 'INSERT' ? 'NEW' : 'OLD'}.session_id AND status='planned')
        OR EXISTS(SELECT 1 FROM matches WHERE session_id=${operation == 'INSERT' ? 'NEW' : 'OLD'}.session_id)
      BEGIN SELECT RAISE(ABORT,'Historical or scheduled session assignments are locked'); END''',
  '''CREATE TRIGGER lock_available_insert BEFORE INSERT ON team_assignment_locks
    WHEN NOT EXISTS(SELECT 1 FROM session_attendance WHERE session_id=NEW.session_id AND player_id=NEW.player_id AND attendance_status='available')
    BEGIN SELECT RAISE(ABORT,'Only available attendees can be locked'); END''',
  '''CREATE TRIGGER lock_available_update BEFORE UPDATE ON team_assignment_locks
    WHEN NEW.session_id!=OLD.session_id OR NEW.player_id!=OLD.player_id OR NOT EXISTS(
      SELECT 1 FROM session_attendance WHERE session_id=NEW.session_id AND player_id=NEW.player_id AND attendance_status='available')
    BEGIN SELECT RAISE(ABORT,'Lock identity and attendance must remain valid'); END''',
];
