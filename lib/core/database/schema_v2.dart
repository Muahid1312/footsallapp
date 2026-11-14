// Additive migration: keep every v1 match/event ID and foreign key intact.
// `phase` is the v2 state; `status` retains its v1-compatible representation.
const migrationV2 = <String>[
  "ALTER TABLE matches ADD COLUMN phase TEXT NOT NULL DEFAULT 'scheduled' CHECK(phase IN ('scheduled','live','paused','finished','cancelled'))",
  "UPDATE matches SET phase=CASE status WHEN 'completed' THEN 'finished' WHEN 'live' THEN 'paused' ELSE status END",
  'ALTER TABLE match_events ADD COLUMN elapsed_millis INTEGER CHECK(elapsed_millis IS NULL OR elapsed_millis >= 0)',
  '''CREATE TABLE match_timer_state (
    match_id TEXT PRIMARY KEY REFERENCES matches(id) ON DELETE RESTRICT,
    accumulated_millis INTEGER NOT NULL DEFAULT 0 CHECK(accumulated_millis >= 0),
    running_since_utc_millis INTEGER, running_since_tick_millis INTEGER,
    runtime_id TEXT, recovery_required INTEGER NOT NULL DEFAULT 0 CHECK(recovery_required IN (0,1)),
    CHECK((running_since_utc_millis IS NULL)=(running_since_tick_millis IS NULL)))''',
  '''CREATE TABLE match_actions (
    id TEXT PRIMARY KEY, match_id TEXT NOT NULL REFERENCES matches(id) ON DELETE RESTRICT,
    action_type TEXT NOT NULL CHECK(action_type IN ('start','pause','resume','finish','record','undo','correction','substitution','recovery','timer_review','import')),
    event_id TEXT UNIQUE REFERENCES match_events(id) ON DELETE RESTRICT,
    target_event_id TEXT UNIQUE REFERENCES match_events(id) ON DELETE RESTRICT,
    elapsed_millis INTEGER NOT NULL CHECK(elapsed_millis >= 0),
    created_at INTEGER NOT NULL, notes TEXT, payload TEXT NOT NULL,
    CHECK((action_type IN ('record','correction'))=(event_id IS NOT NULL)),
    CHECK((action_type IN ('undo','correction'))=(target_event_id IS NOT NULL)),
    CHECK(event_id IS NULL OR target_event_id IS NULL OR event_id != target_event_id))''',
  '''CREATE TABLE match_lineup_stints (
    id TEXT PRIMARY KEY, match_id TEXT NOT NULL REFERENCES matches(id) ON DELETE RESTRICT,
    team_id TEXT NOT NULL, player_id TEXT NOT NULL,
    entered_millis INTEGER NOT NULL CHECK(entered_millis >= 0),
    left_millis INTEGER CHECK(left_millis IS NULL OR left_millis >= entered_millis),
    FOREIGN KEY(team_id,player_id) REFERENCES team_memberships(team_id,player_id) ON DELETE RESTRICT)''',
  '''CREATE TABLE substitutions (
    id TEXT PRIMARY KEY REFERENCES match_actions(id) ON DELETE RESTRICT,
    match_id TEXT NOT NULL REFERENCES matches(id) ON DELETE RESTRICT,
    team_id TEXT NOT NULL, outgoing_player_id TEXT NOT NULL, incoming_player_id TEXT NOT NULL,
    elapsed_millis INTEGER NOT NULL CHECK(elapsed_millis >= 0),
    CHECK(outgoing_player_id != incoming_player_id),
    FOREIGN KEY(team_id,outgoing_player_id) REFERENCES team_memberships(team_id,player_id) ON DELETE RESTRICT,
    FOREIGN KEY(team_id,incoming_player_id) REFERENCES team_memberships(team_id,player_id) ON DELETE RESTRICT)''',
  'CREATE UNIQUE INDEX one_live_match ON matches((1)) WHERE phase=\'live\'',
  'CREATE UNIQUE INDEX one_finish_action ON match_actions(match_id) WHERE action_type=\'finish\'',
  'CREATE UNIQUE INDEX one_start_action ON match_actions(match_id) WHERE action_type=\'start\'',
  'CREATE UNIQUE INDEX one_active_stint ON match_lineup_stints(match_id,player_id) WHERE left_millis IS NULL',
  'CREATE INDEX actions_timeline ON match_actions(match_id,created_at)',
  'CREATE INDEX stints_participation ON match_lineup_stints(match_id,team_id,player_id,entered_millis,left_millis)',
  'CREATE INDEX stints_player ON match_lineup_stints(player_id,match_id)',
  'CREATE INDEX substitutions_match ON substitutions(match_id)',
  '''INSERT INTO match_timer_state(match_id,accumulated_millis,recovery_required)
    SELECT m.id,COALESCE((SELECT MAX(e.elapsed_seconds)*1000 FROM match_events e WHERE e.match_id=m.id),0),
      CASE WHEN m.status='live' THEN 1 ELSE 0 END FROM matches m''',
  // A v1 event is evidence of participation at that instant, not an invented
  // full-match appearance. Unrecorded bench players receive no statistics.
  '''INSERT INTO match_lineup_stints(id,match_id,team_id,player_id,entered_millis,left_millis)
    SELECT 'legacy-scorer-'||id,match_id,team_id,player_id,elapsed_seconds*1000,elapsed_seconds*1000
    FROM match_events WHERE player_id IS NOT NULL''',
  '''INSERT INTO match_lineup_stints(id,match_id,team_id,player_id,entered_millis,left_millis)
    SELECT 'legacy-assist-'||id,match_id,team_id,related_player_id,elapsed_seconds*1000,elapsed_seconds*1000
    FROM match_events WHERE related_player_id IS NOT NULL''',
  '''INSERT INTO match_actions(id,match_id,action_type,event_id,elapsed_millis,created_at,payload,notes)
    SELECT 'legacy-'||id,match_id,'record',id,elapsed_seconds*1000,created_at,'[]','Imported Phase 1 event'
    FROM match_events ORDER BY rowid''',
  '''INSERT INTO match_actions(id,match_id,action_type,elapsed_millis,created_at,notes,payload)
    SELECT 'legacy-import-'||m.id,m.id,'import',t.accumulated_millis,
      CAST(strftime('%s','now') AS INTEGER)*1000,
      'Imported Phase 1 record. Full playing time and on-field intervals were not stored; legacy live matches require timer review.', '[]'
    FROM matches m JOIN match_timer_state t ON t.match_id=m.id''',
];

const integrityTriggersV2 = <String>[
  '''CREATE TRIGGER phase_transition BEFORE UPDATE OF phase ON matches
    WHEN NOT ((OLD.phase='scheduled' AND NEW.phase='live') OR
      (OLD.phase='live' AND NEW.phase IN ('paused','finished')) OR
      (OLD.phase='paused' AND NEW.phase IN ('live','finished')) OR OLD.phase=NEW.phase)
    BEGIN SELECT RAISE(ABORT,'Invalid match state transition'); END''',
  '''CREATE TRIGGER match_status_insert BEFORE INSERT ON matches
    WHEN NEW.status != CASE NEW.phase WHEN 'finished' THEN 'completed' WHEN 'paused' THEN 'live' ELSE NEW.phase END
    BEGIN SELECT RAISE(ABORT,'Inconsistent match status'); END''',
  '''CREATE TRIGGER match_status_update BEFORE UPDATE OF status,phase ON matches
    WHEN NEW.status != CASE NEW.phase WHEN 'finished' THEN 'completed' WHEN 'paused' THEN 'live' ELSE NEW.phase END
    BEGIN SELECT RAISE(ABORT,'Inconsistent match status'); END''',
  '''CREATE TRIGGER finished_match_immutable BEFORE UPDATE ON matches
    WHEN OLD.phase IN ('finished','cancelled')
    BEGIN SELECT RAISE(ABORT,'Finished matches are read-only'); END''',
  '''CREATE TRIGGER event_v2_guard BEFORE INSERT ON match_events
    WHEN NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase IN ('live','paused'))
    OR (NEW.event_type IN ('goal','foul') AND NEW.player_id IS NULL)
    OR COALESCE(NEW.elapsed_millis,NEW.elapsed_seconds*1000)>(SELECT duration_seconds*1000 FROM matches WHERE id=NEW.match_id)
    OR COALESCE(NEW.elapsed_millis,NEW.elapsed_seconds*1000)/1000 != NEW.elapsed_seconds
    OR (NEW.player_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM match_lineup_stints s
      WHERE s.match_id=NEW.match_id AND s.team_id=NEW.team_id AND s.player_id=NEW.player_id
      AND s.entered_millis<=COALESCE(NEW.elapsed_millis,NEW.elapsed_seconds*1000)
      AND (s.left_millis IS NULL OR s.left_millis>=COALESCE(NEW.elapsed_millis,NEW.elapsed_seconds*1000))))
    OR (NEW.related_player_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM match_lineup_stints s
      WHERE s.match_id=NEW.match_id AND s.team_id=NEW.team_id AND s.player_id=NEW.related_player_id
      AND s.entered_millis<=COALESCE(NEW.elapsed_millis,NEW.elapsed_seconds*1000)
      AND (s.left_millis IS NULL OR s.left_millis>=COALESCE(NEW.elapsed_millis,NEW.elapsed_seconds*1000))))
    BEGIN SELECT RAISE(ABORT,'Event requires an open match and participating players'); END''',
  '''CREATE TRIGGER event_no_delete BEFORE DELETE ON match_events
    BEGIN SELECT RAISE(ABORT,'Void events through the correction ledger'); END''',
  '''CREATE TRIGGER action_guard BEFORE INSERT ON match_actions
    WHEN NEW.action_type='import'
    OR NEW.elapsed_millis>(SELECT duration_seconds*1000 FROM matches WHERE id=NEW.match_id)
    OR (NEW.action_type IN ('record','undo','correction','substitution','pause','resume','timer_review','recovery')
      AND NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase IN ('live','paused')))
    OR (NEW.action_type='start' AND NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase='live'))
    OR (NEW.action_type='finish' AND NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase='finished'))
    OR (NEW.event_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM match_events WHERE id=NEW.event_id AND match_id=NEW.match_id))
    OR (NEW.action_type='record' AND NEW.elapsed_millis!=(SELECT COALESCE(elapsed_millis,elapsed_seconds*1000) FROM match_events WHERE id=NEW.event_id))
    OR (NEW.target_event_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM match_events WHERE id=NEW.target_event_id
      AND match_id=NEW.match_id AND event_type IN ('goal','foul')))
    OR (NEW.action_type='correction' AND NOT EXISTS(SELECT 1 FROM match_events old JOIN match_events fresh
      ON fresh.id=NEW.event_id WHERE old.id=NEW.target_event_id AND old.team_id=fresh.team_id
      AND old.event_type=fresh.event_type AND old.elapsed_seconds=fresh.elapsed_seconds
      AND COALESCE(old.elapsed_millis,old.elapsed_seconds*1000)=COALESCE(fresh.elapsed_millis,fresh.elapsed_seconds*1000)))
    BEGIN SELECT RAISE(ABORT,'Invalid match audit action'); END''',
  '''CREATE TRIGGER stint_insert_guard BEFORE INSERT ON match_lineup_stints
    WHEN NOT EXISTS(SELECT 1 FROM matches WHERE id=NEW.match_id AND phase='live'
      AND NEW.team_id IN (team_a_id,team_b_id) AND NEW.entered_millis<=duration_seconds*1000)
    BEGIN SELECT RAISE(ABORT,'Lineup must belong to a live match team'); END''',
  '''CREATE TRIGGER stint_close_guard BEFORE UPDATE ON match_lineup_stints
    WHEN OLD.left_millis IS NOT NULL OR NEW.left_millis IS NULL OR OLD.id!=NEW.id OR OLD.match_id!=NEW.match_id
      OR OLD.team_id!=NEW.team_id OR OLD.player_id!=NEW.player_id OR OLD.entered_millis!=NEW.entered_millis
      OR NOT EXISTS(SELECT 1 FROM matches WHERE id=OLD.match_id AND phase IN ('live','paused'))
      OR NEW.left_millis>(SELECT duration_seconds*1000 FROM matches WHERE id=OLD.match_id)
    BEGIN SELECT RAISE(ABORT,'Only an open participation interval can be closed'); END''',
  '''CREATE TRIGGER substitution_guard BEFORE INSERT ON substitutions
    WHEN NOT EXISTS(SELECT 1 FROM match_actions WHERE id=NEW.id AND match_id=NEW.match_id AND action_type='substitution' AND elapsed_millis=NEW.elapsed_millis)
    OR NOT EXISTS(SELECT 1 FROM match_lineup_stints WHERE match_id=NEW.match_id AND team_id=NEW.team_id
      AND player_id=NEW.outgoing_player_id AND left_millis=NEW.elapsed_millis)
    OR NOT EXISTS(SELECT 1 FROM match_lineup_stints WHERE match_id=NEW.match_id AND team_id=NEW.team_id
      AND player_id=NEW.incoming_player_id AND entered_millis=NEW.elapsed_millis AND left_millis IS NULL)
    BEGIN SELECT RAISE(ABORT,'Substitution must close and open same-team participation'); END''',
  '''CREATE TRIGGER played_team_identity BEFORE UPDATE OF name,color_value,captain_player_id ON session_teams
    WHEN EXISTS(SELECT 1 FROM matches WHERE team_a_id=OLD.id OR team_b_id=OLD.id)
    BEGIN SELECT RAISE(ABORT,'Match team identity is locked'); END''',
];

List<String> get auditImmutabilityV2 => [
  for (final table in ['match_actions', 'substitutions'])
    for (final operation in ['UPDATE', 'DELETE'])
      'CREATE TRIGGER immutable_${table}_$operation BEFORE $operation ON $table BEGIN SELECT RAISE(ABORT,\'Match audit history is immutable\'); END',
  'CREATE TRIGGER stint_no_delete BEFORE DELETE ON match_lineup_stints BEGIN SELECT RAISE(ABORT,\'Participation history is immutable\'); END',
  'CREATE TRIGGER timer_no_delete BEFORE DELETE ON match_timer_state BEGIN SELECT RAISE(ABORT,\'Match timer state cannot be deleted\'); END',
  '''CREATE TRIGGER timer_finished_guard BEFORE UPDATE ON match_timer_state
    WHEN EXISTS(SELECT 1 FROM matches WHERE id=OLD.match_id AND phase IN ('finished','cancelled'))
    BEGIN SELECT RAISE(ABORT,'Finished timer is read-only'); END''',
];
