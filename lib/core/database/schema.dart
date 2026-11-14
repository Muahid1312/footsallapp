// Versioned SQLite DDL executed by Drift. Composite foreign keys bind every
// roster and event to its parent session without relying on UI validation.
const schemaV1 = <String>[
  '''CREATE TABLE players (
    id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 80),
    photo_path TEXT, preferred_position TEXT NOT NULL,
    jersey_number INTEGER CHECK(jersey_number BETWEEN 0 AND 99),
    skill_rating INTEGER NOT NULL CHECK(skill_rating BETWEEN 1 AND 10),
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK(is_archived IN (0,1)))''',
  '''CREATE TABLE sessions (
    id TEXT PRIMARY KEY, date INTEGER NOT NULL, location_name TEXT NOT NULL,
    match_duration_seconds INTEGER NOT NULL CHECK(match_duration_seconds BETWEEN 60 AND 10800),
    rotation_mode TEXT NOT NULL CHECK(rotation_mode IN ('round_robin','winner_stays')),
    status TEXT NOT NULL DEFAULT 'planned' CHECK(status IN ('planned','completed')),
    created_at INTEGER NOT NULL)''',
  '''CREATE TABLE session_attendance (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
    player_id TEXT NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
    attendance_status TEXT NOT NULL CHECK(attendance_status IN ('available','absent')),
    UNIQUE(session_id, player_id))''',
  '''CREATE TABLE session_teams (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
    color_value INTEGER NOT NULL CHECK(color_value BETWEEN 0 AND 4294967295),
    captain_player_id TEXT REFERENCES players(id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL, UNIQUE(id, session_id))''',
  '''CREATE TABLE team_memberships (
    id TEXT PRIMARY KEY, team_id TEXT NOT NULL, session_id TEXT NOT NULL,
    player_id TEXT NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL, UNIQUE(session_id, player_id), UNIQUE(team_id, player_id),
    FOREIGN KEY(team_id, session_id) REFERENCES session_teams(id, session_id) ON DELETE RESTRICT,
    FOREIGN KEY(session_id, player_id) REFERENCES session_attendance(session_id, player_id) ON DELETE RESTRICT)''',
  '''CREATE TABLE matches (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
    team_a_id TEXT NOT NULL, team_b_id TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL CHECK(duration_seconds > 0),
    status TEXT NOT NULL CHECK(status IN ('scheduled','live','completed','cancelled')),
    started_at INTEGER, ended_at INTEGER, CHECK(team_a_id != team_b_id),
    CHECK(ended_at IS NULL OR (started_at IS NOT NULL AND ended_at >= started_at)),
    FOREIGN KEY(team_a_id,session_id) REFERENCES session_teams(id,session_id) ON DELETE RESTRICT,
    FOREIGN KEY(team_b_id,session_id) REFERENCES session_teams(id,session_id) ON DELETE RESTRICT)''',
  '''CREATE TABLE match_events (
    id TEXT PRIMARY KEY, match_id TEXT NOT NULL REFERENCES matches(id) ON DELETE RESTRICT,
    team_id TEXT NOT NULL REFERENCES session_teams(id) ON DELETE RESTRICT,
    player_id TEXT REFERENCES players(id) ON DELETE RESTRICT,
    related_player_id TEXT REFERENCES players(id) ON DELETE RESTRICT,
    event_type TEXT NOT NULL CHECK(event_type IN ('goal','own_goal','foul','yellow_card','red_card')),
    elapsed_seconds INTEGER NOT NULL CHECK(elapsed_seconds >= 0), created_at INTEGER NOT NULL,
    CHECK(related_player_id IS NULL OR (event_type = 'goal' AND player_id IS NOT NULL AND related_player_id != player_id)),
    CHECK(player_id IS NOT NULL OR related_player_id IS NULL))''',
  '''CREATE TABLE injuries (
    id TEXT PRIMARY KEY, player_id TEXT NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
    session_id TEXT REFERENCES sessions(id) ON DELETE RESTRICT,
    description TEXT NOT NULL CHECK(length(trim(description)) > 0),
    occurred_at INTEGER NOT NULL, recovered_at INTEGER,
    CHECK(recovered_at IS NULL OR recovered_at >= occurred_at))''',
  'CREATE INDEX players_name ON players(name COLLATE NOCASE)',
  'CREATE INDEX sessions_date ON sessions(date DESC)',
  'CREATE INDEX teams_session ON session_teams(session_id)',
  'CREATE INDEX teams_captain ON session_teams(captain_player_id)',
  'CREATE INDEX membership_player ON team_memberships(player_id)',
  'CREATE INDEX attendance_player ON session_attendance(player_id)',
  'CREATE INDEX matches_session ON matches(session_id)',
  'CREATE INDEX matches_team_a ON matches(team_a_id)',
  'CREATE INDEX matches_team_b ON matches(team_b_id)',
  'CREATE INDEX events_match ON match_events(match_id, elapsed_seconds)',
  'CREATE INDEX events_player ON match_events(player_id, event_type)',
  'CREATE INDEX events_assist ON match_events(related_player_id)',
  'CREATE INDEX events_team ON match_events(team_id)',
  'CREATE INDEX injuries_player ON injuries(player_id, occurred_at)',
  'CREATE INDEX injuries_session ON injuries(session_id)',
];

// Triggers validate relationships SQLite CHECKs cannot express. Immutable event
// records support a future append/correct scoring ledger instead of fake totals.
const integrityTriggersV1 = <String>[
  '''CREATE TRIGGER completed_session_update BEFORE UPDATE ON sessions
    WHEN OLD.status='completed'
    BEGIN SELECT RAISE(ABORT, 'Completed sessions are immutable'); END''',
  '''CREATE TRIGGER match_participants_immutable BEFORE UPDATE OF session_id,team_a_id,team_b_id ON matches
    BEGIN SELECT RAISE(ABORT, 'Match participants are immutable'); END''',
  '''CREATE TRIGGER membership_available BEFORE INSERT ON team_memberships
    WHEN NOT EXISTS(SELECT 1 FROM session_attendance WHERE session_id=NEW.session_id
      AND player_id=NEW.player_id AND attendance_status='available')
    BEGIN SELECT RAISE(ABORT, 'Player is not available for this session'); END''',
  '''CREATE TRIGGER membership_update BEFORE UPDATE ON team_memberships
    BEGIN SELECT RAISE(ABORT, 'Replace memberships in a transaction'); END''',
  '''CREATE TRIGGER captain_roster BEFORE UPDATE OF captain_player_id ON session_teams
    WHEN NEW.captain_player_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM team_memberships
      WHERE team_id=NEW.id AND player_id=NEW.captain_player_id)
    BEGIN SELECT RAISE(ABORT, 'Captain must be on the team'); END''',
  '''CREATE TRIGGER captain_insert BEFORE INSERT ON session_teams
    WHEN NEW.captain_player_id IS NOT NULL
    BEGIN SELECT RAISE(ABORT, 'Add the roster before selecting a captain'); END''',
  '''CREATE TRIGGER captain_remove BEFORE DELETE ON team_memberships
    WHEN EXISTS(SELECT 1 FROM session_teams WHERE id=OLD.team_id AND captain_player_id=OLD.player_id)
    BEGIN SELECT RAISE(ABORT, 'Clear captain before removing membership'); END''',
  '''CREATE TRIGGER attendance_roster BEFORE UPDATE ON session_attendance
    WHEN EXISTS(SELECT 1 FROM team_memberships WHERE session_id=OLD.session_id AND player_id=OLD.player_id)
    BEGIN SELECT RAISE(ABORT, 'Attendance already has a saved roster'); END''',
  '''CREATE TRIGGER team_session_immutable BEFORE UPDATE OF session_id ON session_teams
    BEGIN SELECT RAISE(ABORT, 'A team cannot move between sessions'); END''',
  '''CREATE TRIGGER event_relationship BEFORE INSERT ON match_events
    WHEN NOT EXISTS(SELECT 1 FROM matches m WHERE m.id=NEW.match_id
      AND NEW.team_id IN (m.team_a_id,m.team_b_id)
      AND NEW.elapsed_seconds <= m.duration_seconds)
    OR (NEW.player_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM team_memberships
      WHERE team_id=NEW.team_id AND player_id=NEW.player_id))
    OR (NEW.related_player_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM team_memberships
      WHERE team_id=NEW.team_id AND player_id=NEW.related_player_id))
    BEGIN SELECT RAISE(ABORT, 'Event must reference a match team and its roster'); END''',
  '''CREATE TRIGGER event_immutable BEFORE UPDATE ON match_events
    BEGIN SELECT RAISE(ABORT, 'Match events are immutable'); END''',
  '''CREATE TRIGGER played_roster_delete BEFORE DELETE ON team_memberships
    WHEN EXISTS(SELECT 1 FROM matches WHERE team_a_id=OLD.team_id OR team_b_id=OLD.team_id)
    BEGIN SELECT RAISE(ABORT, 'A match already references this roster'); END''',
  '''CREATE TRIGGER played_roster_insert BEFORE INSERT ON team_memberships
    WHEN EXISTS(SELECT 1 FROM matches WHERE team_a_id=NEW.team_id OR team_b_id=NEW.team_id)
    BEGIN SELECT RAISE(ABORT, 'A match already references this roster'); END''',
];

List<String> get completedHistoryTriggersV1 => [
  for (final table in [
    'session_teams',
    'team_memberships',
    'session_attendance',
  ])
    for (final operation in ['INSERT', 'UPDATE', 'DELETE'])
      '''CREATE TRIGGER completed_${table}_${operation.toLowerCase()} BEFORE $operation ON $table
        WHEN EXISTS(SELECT 1 FROM sessions WHERE ${operation == 'UPDATE' ? 'id IN (OLD.session_id, NEW.session_id)' : "id=${operation == 'INSERT' ? 'NEW' : 'OLD'}.session_id"} AND status='completed')
        BEGIN SELECT RAISE(ABORT, 'Completed session history is immutable'); END''',
];
