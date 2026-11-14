"""Execute the actual Dart SQL schema/migration with Python's SQLite engine.

Supplementary contract tests, not a substitute for Flutter/Drift engine tests.
No third-party Python dependencies. Run from any directory.
"""
import ast
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r"'''(.*?)'''|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'", re.S)


def strings(source):
    for token in TOKEN.finditer(source):
        value = token.group(1) if token.group(1) is not None else ast.literal_eval(token.group())
        words = value.lstrip().split(maxsplit=1)
        if len(words) > 1 and words[0] in {'CREATE', 'ALTER', 'INSERT', 'UPDATE', 'SELECT', 'DELETE', 'DROP'}:
            yield value


def v1(connection):
    source = (ROOT / 'lib/core/database/schema.dart').read_text()
    for sql in strings(source.split('List<String> get completedHistoryTriggersV1')[0]):
        connection.execute(sql)
    for table in ['session_teams', 'team_memberships', 'session_attendance']:
        for operation in ['INSERT', 'UPDATE', 'DELETE']:
            reference = 'id IN (OLD.session_id, NEW.session_id)' if operation == 'UPDATE' else f"id={'NEW' if operation == 'INSERT' else 'OLD'}.session_id"
            connection.execute(f"""CREATE TRIGGER completed_{table}_{operation.lower()} BEFORE {operation} ON {table}
              WHEN EXISTS(SELECT 1 FROM sessions WHERE {reference} AND status='completed')
              BEGIN SELECT RAISE(ABORT,'Completed session history is immutable'); END""")


def v2(connection):
    source = (ROOT / 'lib/core/database/schema_v2.dart').read_text()
    prefix, tail = source.split('List<String> get auditImmutabilityV2')
    for sql in strings(prefix):
        connection.execute(sql)
    # Expand the two finite Dart collection loops. Remaining triggers are literal.
    for table in ['match_actions', 'substitutions']:
        for operation in ['UPDATE', 'DELETE']:
            connection.execute(f"CREATE TRIGGER immutable_{table}_{operation} BEFORE {operation} ON {table} BEGIN SELECT RAISE(ABORT,'Match audit history is immutable'); END")
    for sql in strings(tail):
        if '${' not in sql:
            connection.execute(sql)


def v3(connection):
    source = (ROOT / 'lib/core/database/schema_v3.dart').read_text()
    prefix, tail = source.split('List<String> get integrityTriggersV3')
    for sql in strings(prefix):
        connection.execute(sql)
    for table in ['champion_decisions','competition_admin_actions','match_reopens']:
        for operation in ['UPDATE','DELETE']:
            connection.execute(f"CREATE TRIGGER audit_{table}_{operation} BEFORE {operation} ON {table} BEGIN SELECT RAISE(ABORT,'Competition audit is immutable'); END")
    for table in ['competitions','competition_teams','competition_fixtures','competition_applications']:
        connection.execute(f"CREATE TRIGGER no_delete_{table} BEFORE DELETE ON {table} BEGIN SELECT RAISE(ABORT,'Competition history cannot be deleted'); END")
    for sql in strings(tail):
        if '$' not in sql:
            connection.execute(sql)


def v4(connection):
    source=(ROOT/'lib/core/database/schema_v4.dart').read_text()
    prefix,tail=source.split('List<String> get integrityTriggersV4')
    for sql in strings(prefix):connection.execute(sql)
    for table in ['player_rating_history','session_mvp_decisions']:
        for operation in ['UPDATE','DELETE']:
            connection.execute(f"CREATE TRIGGER immutable_{table}_{operation} BEFORE {operation} ON {table} BEGIN SELECT RAISE(ABORT,'Rating and award history is immutable'); END")
    for operation in ['INSERT','UPDATE','DELETE']:
        reference='NEW' if operation=='INSERT' else 'OLD'
        connection.execute(f"""CREATE TRIGGER locks_guard_{operation} BEFORE {operation} ON team_assignment_locks
          WHEN NOT EXISTS(SELECT 1 FROM sessions WHERE id={reference}.session_id AND status='planned')
          OR EXISTS(SELECT 1 FROM matches WHERE session_id={reference}.session_id)
          BEGIN SELECT RAISE(ABORT,'Historical or scheduled session assignments are locked'); END""")
    for sql in strings(tail):
        if '$' not in sql:connection.execute(sql)


def v5(connection):
    for sql in strings((ROOT / 'lib/core/database/schema_v5.dart').read_text()):
        connection.execute(sql)


def seed(connection):
    for n in range(8):
        connection.execute('INSERT INTO players(id,name,photo_path,preferred_position,jersey_number,skill_rating,created_at,updated_at,is_archived) VALUES (?,?,?,?,?,?,?,?,?)', (f'p{n}', f'Player {n}', None, 'Winger', None, 5, 0, 0, 0))
    connection.execute("INSERT INTO sessions VALUES ('s',0,'Court',600,'round_robin','planned',0)")
    for team in ['a', 'b']:
        connection.execute('INSERT INTO session_teams VALUES (?,?,?,?,?,?)', (team, 's', team, 4294967295, None, 0))
    for n in range(8):
        connection.execute('INSERT INTO session_attendance VALUES (?,?,?,?)', (f'a{n}', 's', f'p{n}', 'available'))
        connection.execute('INSERT INTO team_memberships VALUES (?,?,?,?,?)', (f'm{n}', 'a' if n < 4 else 'b', 's', f'p{n}', 0))


class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', isolation_level=None)
        self.db.execute('PRAGMA foreign_keys=ON')
        v1(self.db)
        seed(self.db)
        v2(self.db)
        v3(self.db)
        v4(self.db)
        v5(self.db)
        self.db.execute("INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase) VALUES ('match','s','a','b',600,'live','live')")
        self.db.execute("INSERT INTO match_timer_state(match_id) VALUES ('match')")
        for n in [0, 1, 2, 4, 5, 6]:
            self.db.execute('INSERT INTO match_lineup_stints VALUES (?,?,?,?,?,?)', (f's{n}', 'match', 'a' if n < 4 else 'b', f'p{n}', 0, None))

    def tearDown(self):
        self.assertEqual(self.db.execute('PRAGMA foreign_key_check').fetchall(), [])
        self.assertEqual(self.db.execute('PRAGMA integrity_check').fetchone(), ('ok',))
        self.db.close()

    def event(self, key='e', player='p0', assist='p1', team='a', millis=10000, kind='goal'):
        self.db.execute('INSERT INTO match_events VALUES (?,?,?,?,?,?,?,?,?)', (key, 'match', team, player, assist, kind, millis // 1000, 0, millis))

    def action(self, key='record', kind='record', event='e', target=None, elapsed=10000):
        self.db.execute('INSERT INTO match_actions(id,match_id,action_type,event_id,target_event_id,elapsed_millis,created_at,notes,payload) VALUES (?,?,?,?,?,?,?,?,?)', (key, 'match', kind, event, target, elapsed, 0, None, '[]'))

    def score(self):
        return self.db.execute("SELECT COUNT(*) FROM match_events e WHERE event_type='goal' AND NOT EXISTS(SELECT 1 FROM match_actions a WHERE a.target_event_id=e.id)").fetchone()[0]

    def test_score_undo_and_unique_request(self):
        self.event()
        self.action()
        self.assertEqual(self.score(), 1)
        with self.assertRaises(sqlite3.IntegrityError):
            self.action()
        self.action('undo', 'undo', None, 'e')
        self.assertEqual(self.score(), 0)
        with self.assertRaises(sqlite3.IntegrityError):
            self.action('undo-again', 'undo', None, 'e')

    def test_invalid_scorer_assist_bench_and_times(self):
        for args in [dict(player='p4'), dict(player='p3'), dict(assist='p4'), dict(assist='p0'), dict(millis=600001)]:
            with self.subTest(args=args), self.assertRaises(sqlite3.IntegrityError):
                self.event(**args)
        self.assertEqual(self.score(), 0)

    def test_correction_is_atomic_and_traceable(self):
        self.event()
        self.action()
        self.db.execute('BEGIN')
        self.event('replacement', player='p1', assist='p2')
        self.action('fix', 'correction', 'replacement', 'e')
        self.db.execute('COMMIT')
        self.assertEqual(self.score(), 1)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM match_events').fetchone(), (2,))
        for sql in ["UPDATE match_events SET player_id='p2'", 'DELETE FROM match_actions', 'DELETE FROM match_events']:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)

    def test_invalid_replacement_rolls_back_all_new_rows(self):
        self.event()
        self.action()
        self.db.execute('BEGIN')
        self.event('replacement', player='p1', assist=None, millis=20000)
        with self.assertRaises(sqlite3.IntegrityError):
            self.action('fix', 'correction', 'replacement', 'e')
        self.db.execute('ROLLBACK')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM match_events').fetchone(), (1,))
        self.assertEqual(self.score(), 1)

    def test_substitution_requires_same_team_and_open_stints(self):
        self.db.execute("UPDATE match_lineup_stints SET left_millis=20000 WHERE player_id='p0'")
        self.db.execute("INSERT INTO match_lineup_stints VALUES ('sub-in','match','a','p3',20000,NULL)")
        self.action('sub', 'substitution', None, elapsed=20000)
        self.db.execute("INSERT INTO substitutions VALUES ('sub','match','a','p0','p3',20000)")
        self.event('new-goal', player='p3', assist=None, millis=20001)
        with self.assertRaises(sqlite3.IntegrityError):
            self.event('old-player', player='p0', assist=None, millis=20001)
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO match_lineup_stints VALUES ('cross','match','a','p7',20000,NULL)")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE substitutions SET incoming_player_id='p1'")

    def test_finish_locks_score_timer_and_corrections(self):
        self.event()
        self.action()
        self.db.execute("UPDATE match_lineup_stints SET left_millis=10000 WHERE left_millis IS NULL")
        self.db.execute("UPDATE matches SET phase='finished',status='completed' WHERE id='match'")
        self.action('finish', 'finish', None)
        for sql in ["UPDATE matches SET phase='live',status='live'", 'UPDATE match_timer_state SET accumulated_millis=0', 'DELETE FROM match_timer_state']:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)
        with self.assertRaises(sqlite3.IntegrityError):
            self.event('late')
        with self.assertRaises(sqlite3.IntegrityError):
            self.action('undo', 'undo', None, 'e')
        with self.assertRaises(sqlite3.IntegrityError):
            self.action('finish-again', 'finish', None)

    def test_teams_and_rosters_remain_locked(self):
        for sql in ["UPDATE session_teams SET name='Changed' WHERE id='a'", "DELETE FROM team_memberships WHERE player_id='p0'", "UPDATE session_teams SET session_id='elsewhere' WHERE id='a'"]:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)

    def test_repository_queries_prepare_against_actual_schema(self):
        count = 0
        source = (ROOT / 'lib/features/matches/data/match_repository.dart').read_text()
        for sql in strings(source):
            self.db.execute('EXPLAIN ' + sql, [None] * sql.count('?'))
            count += 1
        self.assertGreater(count, 25)

    def test_v1_live_and_finished_history_migrate_without_data_loss(self):
        other = sqlite3.connect(':memory:', isolation_level=None)
        other.execute('PRAGMA foreign_keys=ON')
        v1(other)
        seed(other)
        for phase in ['live', 'completed', 'scheduled', 'cancelled']:
            other.execute('INSERT INTO matches VALUES (?,?,?,?,?,?,?,?)', (phase, 's', 'a', 'b', 600, phase, 0 if phase != 'scheduled' else None, 600000 if phase == 'completed' else None))
        other.execute("INSERT INTO match_events VALUES ('old','live','a','p0','p1','goal',20,20000)")
        before = other.execute('SELECT * FROM team_memberships ORDER BY id').fetchall()
        other.execute('BEGIN')
        v2(other)
        other.execute('COMMIT')
        self.assertEqual(other.execute('SELECT * FROM team_memberships ORDER BY id').fetchall(), before)
        self.assertEqual(other.execute("SELECT id FROM match_events WHERE id='old'").fetchone(), ('old',))
        self.assertEqual(other.execute("SELECT phase FROM matches WHERE id='live'").fetchone(), ('paused',))
        self.assertEqual(other.execute("SELECT recovery_required FROM match_timer_state WHERE match_id='live'").fetchone(), (1,))
        self.assertEqual(other.execute("SELECT phase FROM matches WHERE id='completed'").fetchone(), ('finished',))
        self.assertEqual(other.execute('PRAGMA foreign_key_check').fetchall(), [])
        other.close()


class CompetitionSchemaTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:', isolation_level=None)
        self.db.execute('PRAGMA foreign_keys=ON')
        v1(self.db);seed(self.db);v2(self.db);v3(self.db);v4(self.db);v5(self.db)
        self.db.execute("INSERT INTO competitions VALUES ('c','s','round_robin','draft',600,3,1,0,1,'both_rotate','points',6,'{}',0)")
        for i,t in enumerate(['a','b']):
            self.db.execute('INSERT INTO competition_teams VALUES (?,?,?,?)',('c','s',t,i))
        self.db.execute("INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase) VALUES ('game','s','a','b',600,'scheduled','scheduled')")
        self.db.execute("INSERT INTO match_timer_state(match_id) VALUES ('game')")
        self.db.execute("INSERT INTO competition_fixtures VALUES ('f','c','game','a','b',1,1,1,'league','pending',1,'1:a|b')")
        self.db.execute("UPDATE competitions SET status='active' WHERE id='c'")
    def tearDown(self):
        self.assertEqual(self.db.execute('PRAGMA foreign_key_check').fetchall(),[])
        self.db.close()
    def test_conflicting_competition_and_settings(self):
        for sql in ["INSERT INTO competitions VALUES ('c2','s','round_robin','draft',600,3,1,0,1,'both_rotate','points',6,'{}',0)",
                    "UPDATE competitions SET win_points=4 WHERE id='c'", "UPDATE competition_teams SET ordinal=5"]:
            with self.assertRaises(sqlite3.IntegrityError):self.db.execute(sql)
    def test_postponed_fixture_cannot_start(self):
        self.db.execute("UPDATE competition_fixtures SET status='postponed' WHERE id='f'")
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute("UPDATE matches SET phase='live',status='live' WHERE id='game'")
    def test_cancellation_is_unplayed_and_consistent(self):
        self.db.execute("UPDATE matches SET phase='cancelled',status='cancelled' WHERE id='game'")
        self.db.execute("UPDATE competition_fixtures SET status='cancelled' WHERE id='f'")
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute("UPDATE matches SET phase='live',status='live' WHERE id='game'")
    def test_audited_reopen_and_result_revisions(self):
        self.db.execute("UPDATE matches SET phase='live',status='live',started_at=0 WHERE id='game'")
        self.db.execute("UPDATE matches SET phase='finished',status='completed',ended_at=0 WHERE id='game'")
        self.db.execute("UPDATE competition_fixtures SET status='finished' WHERE id='f'")
        self.db.execute("INSERT INTO competition_applications VALUES ('game',0,'c','f','{}','{}',0,0)")
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute("UPDATE matches SET phase='paused',status='live',result_revision=1 WHERE id='game'")
        self.db.execute("INSERT INTO match_reopens VALUES ('game',1,'Incorrect result',1)")
        self.db.execute("UPDATE matches SET phase='paused',status='live',result_revision=1 WHERE id='game'")
        self.db.execute("UPDATE competition_applications SET reverted=1 WHERE match_id='game' AND revision=0")
        self.db.execute("UPDATE competition_fixtures SET status='pending' WHERE id='f'")
        self.db.execute("UPDATE matches SET phase='finished',status='completed' WHERE id='game'")
        self.db.execute("UPDATE competition_fixtures SET status='finished' WHERE id='f'")
        self.db.execute("INSERT INTO competition_applications VALUES ('game',1,'c','f','{}','{}',0,1)")
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute("INSERT INTO competition_applications VALUES ('game',1,'c','f','{}','{}',0,1)")
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM competition_applications').fetchone(),(2,))
    def test_champion_and_history_are_immutable(self):
        self.db.execute('INSERT INTO champion_decisions VALUES (?,?,?,?,?,?,?,?)',('c','a','manual','[\"a\",\"b\"]','Explicit decision',1,'[]',0))
        self.db.execute("UPDATE competitions SET status='completed' WHERE id='c'")
        for sql in ["UPDATE champion_decisions SET champion_team_id='b'", "DELETE FROM champion_decisions", "UPDATE competitions SET status='active'"]:
            with self.assertRaises(sqlite3.IntegrityError):self.db.execute(sql)
    def test_competition_queries_prepare(self):
        source=(ROOT/'lib/features/competitions/data/competition_repository.dart').read_text()
        count=0
        for sql in strings(source):
            self.db.execute('EXPLAIN '+sql,[None]*sql.count('?'));count+=1
        self.assertGreater(count,30)


class AnalyticsSchemaTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:',isolation_level=None)
        self.db.row_factory=sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        v1(self.db);seed(self.db);v2(self.db);v3(self.db);v4(self.db);v5(self.db)
    def tearDown(self):
        self.assertEqual(self.db.execute('PRAGMA foreign_key_check').fetchall(),[])
        self.db.close()
    def finish_match(self,void=False):
        self.db.execute("INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase,started_at) VALUES ('m','s','a','b',600,'live','live',0)")
        self.db.execute("INSERT INTO match_timer_state(match_id) VALUES ('m')")
        for p,t in [('p0','a'),('p1','a'),('p4','b'),('p5','b')]:
            self.db.execute('INSERT INTO match_lineup_stints VALUES (?,?,?,?,?,?)',('stint-'+p,'m',t,p,0,None))
        self.db.execute("INSERT INTO match_events VALUES ('goal','m','a','p0','p1','goal',10,10000,10000)")
        self.db.execute("INSERT INTO match_events VALUES ('foul','m','b','p4',NULL,'foul',11,11000,11000)")
        if void:
            self.db.execute("INSERT INTO match_actions(id,match_id,action_type,target_event_id,elapsed_millis,created_at,payload) VALUES ('undo','m','undo','goal',12000,12000,'[]')")
        self.db.execute("UPDATE match_lineup_stints SET left_millis=20000 WHERE match_id='m'")
        self.db.execute("UPDATE matches SET phase='finished',status='completed',ended_at=20000 WHERE id='m'")
    def test_exact_participation_goals_assists_fouls_and_scores(self):
        self.finish_match()
        rows={r['player_id']:dict(r) for r in self.db.execute('SELECT * FROM analytics_player_matches')}
        self.assertEqual(set(rows),{'p0','p1','p4','p5'})
        self.assertEqual(rows['p0']['goals'],1);self.assertEqual(rows['p1']['assists'],1);self.assertEqual(rows['p4']['fouls'],1)
        self.assertEqual((rows['p0']['goals_for'],rows['p0']['goals_against']),(1,0))
        self.assertEqual(rows['p0']['playing_millis'],20000)
    def test_voided_event_excluded_everywhere(self):
        self.finish_match(void=True)
        self.assertEqual(self.db.execute('SELECT SUM(goals),SUM(assists) FROM analytics_player_matches').fetchone()[:],(0,0))
        self.assertEqual(self.db.execute('SELECT score_a FROM analytics_match_scores').fetchone()[0],0)
    def test_rating_history_atomic_and_immutable(self):
        self.db.execute("UPDATE players SET skill_rating=8,updated_at=123 WHERE id='p0'")
        self.db.execute("UPDATE players SET name='Renamed' WHERE id='p0'")
        rows=self.db.execute("SELECT old_rating,new_rating FROM player_rating_history WHERE player_id='p0' ORDER BY id").fetchall()
        self.assertEqual([tuple(r) for r in rows],[(None,5),(5,8)])
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute('DELETE FROM player_rating_history')
    def test_locks_enforce_attendance_session_and_scheduled_history(self):
        self.db.execute("INSERT INTO team_assignment_locks VALUES ('s','p0','a')")
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute("INSERT INTO team_assignment_locks VALUES ('s','missing','a')")
        self.finish_match()
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute("UPDATE team_assignment_locks SET team_id='b' WHERE player_id='p0'")
    def test_mvp_requires_completed_session_and_real_participation(self):
        self.finish_match()
        sql='INSERT INTO session_mvp_decisions VALUES (?,?,?,?,?,?,?,?,?)'
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute(sql,('award','s',1,'p0','calculated','["p0"]','{}',None,0))
        self.db.execute("UPDATE sessions SET status='completed' WHERE id='s'")
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute(sql,('bench','s',1,'p2','override','["p2"]','{}',None,0))
        self.db.execute("INSERT INTO session_mvp_settings VALUES ('s',4,3,2,-1)")
        self.db.execute(sql,('award','s',1,'p0','calculated','["p0"]','{}',None,0))
        self.db.execute(sql,('override','s',2,'p1','override','["p1"]','{}','Administrator decision',1))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM session_mvp_decisions').fetchone()[0],2)
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute('UPDATE session_mvp_settings SET goal_weight=9')
        with self.assertRaises(sqlite3.IntegrityError):self.db.execute('DELETE FROM session_mvp_decisions')
    def test_v4_preserves_v3_data_and_goalkeeper_flags(self):
        old=sqlite3.connect(':memory:',isolation_level=None)
        v1(old);seed(old);v2(old);v3(old)
        old.execute("UPDATE players SET preferred_position='Goalkeeper' WHERE id='p0'")
        before=old.execute('SELECT id,name,skill_rating FROM players ORDER BY id').fetchall()
        old.execute('BEGIN');v4(old);old.execute('COMMIT')
        self.assertEqual(old.execute('SELECT id,name,skill_rating FROM players ORDER BY id').fetchall(),before)
        self.assertEqual(old.execute("SELECT goalkeeper_eligible,secondary_position FROM players WHERE id='p0'").fetchone(),(1,None))
        self.assertEqual(old.execute('SELECT COUNT(*) FROM player_rating_history').fetchone()[0],8)
        old.close()
    def test_statistics_repository_queries_prepare(self):
        source=(ROOT/'lib/features/statistics/data/statistics_repository.dart').read_text()
        for sql in strings(source):
            if '$' not in sql and not sql.startswith('WHERE'):self.db.execute('EXPLAIN '+sql,[None]*sql.count('?'))


class Phase5SchemaTests(unittest.TestCase):
    def database(self, filename=':memory:'):
        db=sqlite3.connect(filename,isolation_level=None)
        db.execute('PRAGMA foreign_keys=ON')
        v1(db);seed(db);v2(db);v3(db);v4(db)
        return db

    def test_v5_preserves_profiles_photos_and_rating_history(self):
        db=self.database()
        db.execute("UPDATE players SET photo_path='/private/photo.jpg',secondary_position='Pivot',goalkeeper_eligible=1 WHERE id='p0'")
        before=db.execute('SELECT id,name,photo_path,skill_rating,secondary_position,goalkeeper_eligible FROM players ORDER BY id').fetchall()
        history=db.execute('SELECT * FROM player_rating_history').fetchall()
        db.execute('BEGIN');v5(db);db.execute('COMMIT')
        self.assertEqual(db.execute('SELECT id,name,photo_path,skill_rating,secondary_position,goalkeeper_eligible FROM players ORDER BY id').fetchall(),before)
        self.assertEqual(db.execute('SELECT * FROM player_rating_history').fetchall(),history)
        self.assertEqual(db.execute('SELECT DISTINCT preferred_foot FROM players').fetchall(),[('unknown',)])
        self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])
        db.close()

    def test_settings_and_preferred_foot_reject_invalid_values(self):
        db=self.database();v5(db)
        for sql in ["UPDATE app_settings SET match_minutes=0", "UPDATE app_settings SET generation_mode='online'", "UPDATE app_settings SET cycles=11", "UPDATE players SET preferred_foot='invalid'"]:
            with self.assertRaises(sqlite3.IntegrityError):db.execute(sql)
        db.execute("UPDATE players SET preferred_foot='both' WHERE id='p0'")
        self.assertEqual(db.execute('SELECT COUNT(*) FROM player_rating_history').fetchone()[0],8)
        self.assertEqual(db.execute('SELECT match_minutes,generation_mode,win_points FROM app_settings').fetchone(),(10,'balanced',3))
        db.close()

    def test_vacuum_into_captures_committed_wal_and_preserves_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'app.sqlite';destination=Path(directory)/'snapshot.sqlite'
            db=self.database(str(source));v5(db);db.execute('PRAGMA user_version=5');db.execute('PRAGMA journal_mode=WAL')
            db.execute("UPDATE players SET name='Committed WAL profile' WHERE id='p0'")
            writer=sqlite3.connect(source,isolation_level=None)
            writer.execute('BEGIN IMMEDIATE');writer.execute("UPDATE players SET name='Uncommitted profile' WHERE id='p0'")
            db.execute('VACUUM INTO ?',(str(destination),))
            writer.execute('ROLLBACK');writer.close()
            copy=sqlite3.connect(destination)
            self.assertEqual(copy.execute("SELECT name FROM players WHERE id='p0'").fetchone(),('Committed WAL profile',))
            self.assertEqual(copy.execute('PRAGMA user_version').fetchone(),(5,))
            objects="SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY type,name"
            self.assertEqual(copy.execute(objects).fetchall(),db.execute(objects).fetchall())
            self.assertEqual(copy.execute('PRAGMA integrity_check').fetchone(),('ok',))
            copy.close();db.close()

    def test_settings_repository_sql_prepares(self):
        db=self.database();v5(db)
        for name in ['lib/features/settings/data/settings_repository.dart','lib/features/backup/data/backup_service.dart']:
            for sql in strings((ROOT/name).read_text()):
                if '$' not in sql:db.execute('EXPLAIN '+sql,[None]*sql.count('?'))
        db.close()

    def test_restored_live_timer_sql_pauses_without_changing_recorded_events(self):
        db=self.database();v5(db)
        db.execute("INSERT INTO matches(id,session_id,team_a_id,team_b_id,duration_seconds,status,phase,started_at) VALUES ('m','s','a','b',600,'live','live',0)")
        db.execute("INSERT INTO match_timer_state(match_id,accumulated_millis,running_since_utc_millis,running_since_tick_millis,runtime_id) VALUES ('m',1000,0,0,'same-process')")
        db.execute("INSERT INTO match_lineup_stints VALUES ('stint','m','a','p0',0,NULL)")
        db.execute("INSERT INTO match_events VALUES ('goal','m','a','p0',NULL,'goal',1,1000,1000)")
        sql=list(strings((ROOT/'lib/features/backup/data/backup_service.dart').read_text()))
        db.execute(next(s for s in sql if s.startswith('UPDATE match_timer_state SET running_since_utc_millis=NULL')),('m',))
        db.execute(next(s for s in sql if s.startswith("UPDATE matches SET phase='paused'")),('m',))
        db.execute(next(s for s in sql if s.startswith('INSERT INTO match_actions(id,match_id,action_type,elapsed_millis')),('restore','m',1000,2000,'Restored paused','[]',0))
        self.assertEqual(db.execute("SELECT phase FROM matches WHERE id='m'").fetchone(),('paused',))
        self.assertEqual(db.execute("SELECT accumulated_millis,running_since_tick_millis,recovery_required FROM match_timer_state WHERE match_id='m'").fetchone(),(1000,None,1))
        self.assertEqual(db.execute('SELECT COUNT(*) FROM match_events').fetchone(),(1,))
        self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])
        db.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
