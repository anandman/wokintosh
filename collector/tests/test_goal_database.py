"""Authoritative, read-only Codex goal metadata reconciles collector markers."""
import importlib.util
import json
import sqlite3
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('database_goal_agent', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 11, 1, 20, tzinfo=timezone.utc)
MS = int(NOW.timestamp() * 1000)
PRIVATE = 'PRIVATE GOAL OBJECTIVE MUST NEVER BE READ'


class GoalDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = self.home / 'collector'
        self.database = self.home / '.codex/goals_1.sqlite'
        self.database.parent.mkdir()
        self.connection = sqlite3.connect(self.database)
        self.addCleanup(self.connection.close)
        self.connection.execute('''CREATE TABLE thread_goals (
            thread_id TEXT PRIMARY KEY NOT NULL, goal_id TEXT NOT NULL,
            objective TEXT NOT NULL, status TEXT NOT NULL,
            token_budget INTEGER, tokens_used INTEGER NOT NULL DEFAULT 0,
            time_used_seconds REAL NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL)''')
        self.connection.commit()
        self.session('fixture')

    def session(self, identity, title='Same title'):
        path = self.home / '.codex/sessions' / (identity + '.jsonl')
        path.parent.mkdir(exist_ok=True)
        path.write_text('\n'.join(json.dumps(value) for value in (
            {'type': 'session_meta', 'timestamp': agent.stamp(NOW),
             'payload': {'id': identity, 'title': title, 'cwd': '/fixture/project'}},
            {'type': 'event_msg', 'timestamp': agent.stamp(NOW),
             'payload': {'type': 'task_complete'}})))

    def goal(self, identity='fixture', status='blocked', goal_id='goal-one', updated=MS):
        self.connection.execute('INSERT OR REPLACE INTO thread_goals '
                                '(thread_id,goal_id,objective,status,created_at_ms,updated_at_ms) '
                                'VALUES (?,?,?,?,?,?)',
                                (identity, goal_id, PRIVATE, status, MS, updated))
        self.connection.commit()

    def snapshot(self, now=NOW):
        return agent.make_snapshot(self.home, self.state, now)

    def sessions(self, now=NOW):
        return {(s['provider'], s['id']): s for s in self.snapshot(now)['sessions']}

    def marker(self, identity='fixture'):
        return agent.goal_marker_path(self.state, 'codex', identity)

    def legacy_marker(self, identity='fixture'):
        value = agent.base_session(identity, 'codex', '/fixture/project', NOW)
        value.update(state='blocked', activity='Goal blocked')
        agent.atomic_json(self.marker(identity), value)

    def test_ui_delete_after_rename_clears_without_any_new_hook_and_keeps_same_title_identity(self):
        self.session('other')
        for identity in ('fixture', 'other'):
            self.goal(identity)
            agent.ingest_hook('codex', {'session_id': identity, 'hook_event_name': 'PostToolUse',
                'tool_name': 'get_goal', 'tool_response': {'goal': {'status': 'blocked'}}},
                self.home, self.state, NOW)
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        (self.home / '.codex/session_index.jsonl').write_text(json.dumps(
            {'id': 'fixture', 'thread_name': 'Renamed chat'}) + '\n')
        self.connection.execute('DELETE FROM thread_goals WHERE thread_id=?', ('fixture',))
        self.connection.commit()
        sessions = self.sessions()
        self.assertEqual(sessions[('codex', 'fixture')]['title'], 'Renamed chat')
        self.assertFalse(sessions[('codex', 'fixture')]['goalBlocked'])
        self.assertNotEqual(sessions[('codex', 'fixture')]['state'], 'blocked')
        self.assertTrue(sessions[('codex', 'other')]['goalBlocked'])

    def test_database_alone_discovers_blocked_and_limit_states_and_clears_resolved_states(self):
        for status in ('paused', 'usage_limited', 'budget_limited', 'blocked'):
            with self.subTest(status=status):
                self.goal(status=status)
                self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        for status in ('active', 'complete'):
            with self.subTest(status=status):
                self.goal(status='blocked')
                self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
                self.goal(status=status, updated=MS + 1000)
                self.assertFalse(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_replacement_goal_uses_current_status_and_provider_timestamp_without_poll_churn(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.goal(status='active', goal_id='goal-two', updated=MS + 1000)
        self.assertFalse(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.goal(status='blocked', goal_id='goal-three', updated=MS + 2000)
        first = self.sessions()[('codex', 'fixture')]
        before = self.marker().read_bytes()
        before_mtime = self.marker().stat().st_mtime_ns
        later = self.sessions(NOW + timedelta(hours=1))[('codex', 'fixture')]
        self.assertEqual(first['updatedAt'], '2026-11-01T20:00:02Z')
        self.assertEqual(later['updatedAt'], first['updatedAt'])
        self.assertEqual(self.marker().read_bytes(), before)
        self.assertEqual(self.marker().stat().st_mtime_ns, before_mtime)

    def test_explicit_codex_and_claude_markers_survive_database_and_automatic_hook_clears(self):
        for provider in ('codex', 'claude'):
            agent.set_goal_status(self.state, provider, 'fixture', 'blocked', NOW)
        self.goal(status='active')
        for status in ('active', 'complete', 'blocked'):
            agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'PostToolUse',
                'tool_name': 'get_goal', 'tool_response': {'status': status}},
                self.home, self.state, NOW + timedelta(seconds=1))
        self.connection.execute('DELETE FROM thread_goals')
        self.connection.commit()
        sessions = self.sessions()
        self.assertTrue(all(sessions[(provider, 'fixture')]['goalBlocked']
                            for provider in ('codex', 'claude')))

    def test_legacy_absence_or_active_is_ambiguous_but_positive_blocked_observation_binds(self):
        self.legacy_marker()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.goal(status='active')
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.goal(status='blocked')
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.connection.execute('DELETE FROM thread_goals')
        self.connection.commit()
        self.assertFalse(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_old_helper_rewrite_cannot_erase_previously_observed_binding(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.legacy_marker()  # A pre-1.0.1 helper strips unknown private fields.
        self.connection.execute('DELETE FROM thread_goals')
        self.connection.commit()
        self.assertFalse(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_blocked_goal_survives_retention_and_unavailable_database(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.database.rename(self.database.with_suffix('.offline'))
        sessions = self.sessions(NOW + timedelta(days=8))
        self.assertTrue(sessions[('codex', 'fixture')]['goalBlocked'])
        self.assertFalse(self.database.exists(), 'Read-only polling must never create a missing database')

    def test_real_permission_attention_still_wins_over_database_goal(self):
        self.goal()
        agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'PermissionRequest'},
                          self.home, self.state, NOW)
        result = self.sessions()[('codex', 'fixture')]
        self.assertEqual((result['state'], result['goalBlocked']), ('needsAttention', True))

    def test_committed_wal_delete_is_visible(self):
        self.connection.execute('PRAGMA journal_mode=WAL')
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.connection.execute('DELETE FROM thread_goals')
        self.connection.commit()
        self.assertTrue(Path(str(self.database) + '-wal').exists())
        self.assertFalse(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_read_only_queries_and_persistence_never_read_or_include_objective(self):
        self.goal()
        connect = sqlite3.connect
        forbidden = {sqlite3.SQLITE_INSERT, sqlite3.SQLITE_UPDATE, sqlite3.SQLITE_DELETE,
                     sqlite3.SQLITE_CREATE_TABLE, sqlite3.SQLITE_DROP_TABLE}
        def readonly(*args, **kwargs):
            connection = connect(*args, **kwargs)
            def authorize(operation, arg1, arg2, database, trigger):
                if operation in forbidden or (operation == sqlite3.SQLITE_READ and arg2 == 'objective'):
                    return sqlite3.SQLITE_DENY
                return sqlite3.SQLITE_OK
            connection.set_authorizer(authorize)
            return connection
        with patch('sqlite3.connect', side_effect=readonly):
            result = self.snapshot()
        self.assertTrue(result['sessions'][0]['goalBlocked'])
        self.assertNotIn(PRIVATE, json.dumps(result))
        for path in self.state.rglob('*'):
            if path.is_file():
                self.assertNotIn(PRIVATE.encode(), path.read_bytes())

    def test_invalid_metadata_and_overflow_preserve_existing_automatic_marker(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        for column, value in (('status', 'future_status'), ('updated_at_ms', 'bad timestamp'),
                              ('goal_id', 'x' * 10000), ('created_at_ms', -1)):
            with self.subTest(column=column):
                self.goal()
                self.connection.execute('UPDATE thread_goals SET ' + column + '=?', (value,))
                self.connection.commit()
                self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.connection.execute('DELETE FROM thread_goals')
        self.connection.executemany('INSERT INTO thread_goals '
            '(thread_id,goal_id,objective,status,created_at_ms,updated_at_ms) VALUES (?,?,?,?,?,?)',
            [(str(i), 'goal', PRIVATE, 'active', MS, MS) for i in range(513)])
        self.connection.commit()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_successful_explicit_null_goal_clears_only_known_automatic_marker(self):
        event = {'session_id': 'fixture', 'hook_event_name': 'PostToolUse',
                 'tool_name': 'get_goal', 'tool_response': {'goal': {'status': 'blocked'}}}
        agent.ingest_hook('codex', event, self.home, self.state, NOW)
        event['tool_response'] = {'goal': None}
        agent.ingest_hook('codex', event, self.home, self.state, NOW)
        self.assertFalse(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        for explicit in (False, True):
            if explicit:
                agent.set_goal_status(self.state, 'codex', 'fixture', 'blocked', NOW)
            else:
                self.legacy_marker()
            agent.ingest_hook('codex', event, self.home, self.state, NOW)
            self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_empty_failed_or_unverified_null_tool_output_cannot_clear_automatic_marker(self):
        self.database.rename(self.database.with_suffix('.unavailable'))
        event = {'session_id': 'fixture', 'hook_event_name': 'PostToolUse',
                 'tool_name': 'get_goal', 'tool_response': {'goal': {'status': 'blocked'}}}
        agent.ingest_hook('codex', event, self.home, self.state, NOW)
        for tool, response in (('get_goal', {}), ('get_goal', {'goal': None, 'isError': True}),
                               ('get_goal', {'goal': None, 'success': False}),
                               ('get_goal', {'goal': None, 'error': 'Unavailable'}),
                               ('update_goal', {'goal': None})):
            with self.subTest(tool=tool, response=response):
                agent.ingest_hook('codex', dict(event, tool_name=tool, tool_response=response),
                                  self.home, self.state, NOW)
                self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_unavailable_sqlite_module_and_corrupt_database_preserve_markers(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        with patch.object(agent, 'sqlite3', None):
            self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.connection.close()
        self.database.write_bytes(b'not a database')
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def interleaved_snapshot(self, mutation):
        directory = self.state / 'goals'
        directory.mkdir(parents=True, exist_ok=True)
        attempted = threading.Event()
        result = {}
        flock = agent.fcntl.flock
        def collect():
            try:
                result['snapshot'] = self.snapshot()
            except BaseException as error:
                result['error'] = error
        worker = threading.Thread(target=collect, daemon=True)
        def observe_lock(stream, operation):
            if threading.current_thread() is worker and operation == agent.fcntl.LOCK_EX:
                attempted.set()
            return flock(stream, operation)
        with (directory / '.lock').open('a') as lock:
            flock(lock, agent.fcntl.LOCK_EX)
            try:
                with patch.object(agent.fcntl, 'flock', side_effect=observe_lock):
                    worker.start()
                    self.assertTrue(attempted.wait(3), 'Snapshot never attempted the held goal lock')
                    # Model another collector's committed update while it owns this lock.
                    # Direct marker I/O avoids re-entering set_goal_status's same flock.
                    mutation()
                    flock(lock, agent.fcntl.LOCK_UN)
                    worker.join(3)
                    self.assertFalse(worker.is_alive(), 'Snapshot did not finish after lock release')
            finally:
                flock(lock, agent.fcntl.LOCK_UN)
        if 'error' in result:
            raise result['error']
        return {(s['provider'], s['id']): s for s in result['snapshot']['sessions']}

    def test_snapshot_waiting_for_marker_lock_does_not_clear_a_fresh_blocked_hook(self):
        self.goal(status='active')
        def block_new_goal():
            self.goal(status='blocked', goal_id='replacement', updated=MS + 1000)
            value = agent.base_session('fixture', 'codex', '/fixture/project', NOW + timedelta(seconds=1))
            value.update(state='blocked', activity='Goal blocked', _goalSource='codex')
            agent.atomic_json(self.marker(), value)
        sessions = self.interleaved_snapshot(block_new_goal)
        self.assertTrue(sessions[('codex', 'fixture')]['goalBlocked'])
        self.assertEqual(sessions[('codex', 'fixture')]['updatedAt'], '2026-11-01T20:00:01Z')

    def test_snapshot_waiting_for_marker_lock_does_not_resurrect_a_deleted_goal(self):
        self.goal()
        self.legacy_marker()
        def delete_goal():
            self.connection.execute('DELETE FROM thread_goals')
            self.connection.commit()
            self.marker().unlink()
        sessions = self.interleaved_snapshot(delete_goal)
        self.assertFalse(sessions[('codex', 'fixture')]['goalBlocked'])
        self.assertFalse(self.marker().exists())

    def test_snapshot_waiting_for_marker_lock_observes_active_replacement_goal(self):
        self.goal()
        self.legacy_marker()
        def replace_goal():
            self.goal(status='active', goal_id='replacement', updated=MS + 1000)
            self.marker().unlink()
        sessions = self.interleaved_snapshot(replace_goal)
        self.assertFalse(sessions[('codex', 'fixture')]['goalBlocked'])
        self.assertFalse(self.marker().exists())

    def test_embedded_nul_large_text_is_bounded_by_real_sql_projection(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        connect = sqlite3.connect
        projected_bytes = []
        def observed_connection(*args, **kwargs):
            connection = connect(*args, **kwargs)
            def row_factory(cursor, row):
                if cursor.description and cursor.description[0][0].startswith('CASE'):
                    projected_bytes.extend(len(value.encode('utf-8'))
                                           for value in row if isinstance(value, str))
                return row
            connection.row_factory = row_factory
            return connection
        for column in ('thread_id', 'goal_id', 'status'):
            with self.subTest(column=column):
                self.connection.execute('DELETE FROM thread_goals')
                self.goal()
                self.connection.execute('UPDATE thread_goals SET ' + column + '=?',
                                        ('x\0' + 'y' * 1000000,))
                self.connection.commit()
                projected_bytes.clear()
                with patch('sqlite3.connect', side_effect=observed_connection):
                    result = self.sessions()[('codex', 'fixture')]
                self.assertTrue(result['goalBlocked'])
                self.assertTrue(projected_bytes, 'Real SQLite row projection was not observed')
                self.assertLessEqual(max(projected_bytes), 720,
                                     'Unbounded text crossed the SQL-to-Python boundary')

    def test_control_characters_in_goal_identifiers_make_database_observation_unknown(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        for column in ('thread_id', 'goal_id'):
            for value in ('x\0y', 'x\x01y'):
                with self.subTest(column=column, value=value):
                    self.connection.execute('DELETE FROM thread_goals')
                    self.goal()
                    self.connection.execute('UPDATE thread_goals SET ' + column + '=?', (value,))
                    self.connection.commit()
                    self.assertIsNone(agent.read_codex_goals(self.home))
                    self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])

    def test_schema_error_and_database_lock_are_bounded_and_preserve_markers(self):
        self.goal()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.connection.execute('ALTER TABLE thread_goals RENAME TO unsupported')
        self.connection.commit()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.connection.execute('ALTER TABLE unsupported RENAME TO thread_goals')
        self.connection.commit()
        self.connection.execute('BEGIN EXCLUSIVE')
        started = time.monotonic()
        self.assertTrue(self.sessions()[('codex', 'fixture')]['goalBlocked'])
        self.assertLess(time.monotonic() - started, 2)
        self.connection.rollback()


if __name__ == '__main__':
    unittest.main()
