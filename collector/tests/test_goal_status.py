"""Persistent, body-free unfinished-goal markers across both providers."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location('goal_agent', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 30, 20, tzinfo=timezone.utc)


class GoalStatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'

    def tearDown(self):
        self.temp.cleanup()

    def command(self, provider='codex', status='blocked', identity='fixture', *extra):
        return subprocess.run([sys.executable, agent.__file__, '--home', str(self.root),
                               '--state-dir', str(self.state), 'goal-status', '--provider', provider,
                               '--session-id', identity, '--status', status, *extra],
                              capture_output=True, text=True, timeout=10)

    def sessions(self, now=NOW):
        return agent.make_snapshot(self.root, self.state, now)['sessions']

    def test_explicit_markers_survive_missing_transcripts_and_seven_day_cutoff(self):
        for provider in ('codex', 'claude'):
            result = self.command(provider, 'blocked', 'same', '--title', 'Manual acceptance', '--project', 'docktape')
            self.assertEqual(result.returncode, 0, result.stderr)
        sessions = self.sessions(NOW + timedelta(days=30))
        self.assertEqual({(s['provider'], s['id'], s['state']) for s in sessions},
                         {('codex', 'same', 'blocked'), ('claude', 'same', 'blocked')})
        self.assertTrue(all(s['title'] == 'Manual acceptance' and s['project'] == 'docktape' for s in sessions))

    def test_clear_is_provider_scoped_and_idempotent(self):
        for provider in ('codex', 'claude'):
            self.assertEqual(self.command(provider).returncode, 0)
        for status in ('active', 'complete'):
            self.assertEqual(self.command('codex', status).returncode, 0)
        self.assertEqual([(s['provider'], s['state']) for s in self.sessions()], [('claude', 'blocked')])

    def test_marker_overrides_done_but_preserves_real_input_attention(self):
        self.assertEqual(self.command().returncode, 0)
        for name, expected in (('Stop', 'blocked'), ('PermissionRequest', 'needsAttention'), ('Stop', 'blocked')):
            agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': name},
                              self.root, self.state, NOW)
            self.assertEqual(self.sessions()[0]['state'], expected)

    def test_verified_goal_hook_status_persists_after_stop_and_explicit_complete_clears(self):
        event = {'session_id': 'fixture', 'hook_event_name': 'PostToolUse',
                 'tool_name': 'functions.update_goal', 'tool_input': {'status': 'blocked', 'objective': 'PRIVATE BODY'},
                 'tool_response': {'goal': {'status': 'blocked', 'objective': 'PRIVATE BODY'}}}
        agent.ingest_hook('codex', event, self.root, self.state, NOW)
        agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'Stop'}, self.root, self.state, NOW)
        self.assertEqual(self.sessions()[0]['state'], 'blocked')
        for path in self.state.rglob('*.json'):
            self.assertNotIn('PRIVATE BODY', path.read_text())
        event.update(tool_name='functions.get_goal', tool_input={}, tool_response={'goal': {'status': 'complete'}})
        agent.ingest_hook('codex', event, self.root, self.state, NOW + timedelta(seconds=1))
        self.assertNotEqual(self.sessions(NOW + timedelta(seconds=1))[0]['state'], 'blocked')

    def test_unrecognized_or_failed_goal_shapes_cannot_clear_marker(self):
        self.assertEqual(self.command().returncode, 0)
        for event in (
            {'hook_event_name': 'UserPromptSubmit'},
            {'hook_event_name': 'PostToolUse', 'tool_name': 'functions.exec', 'tool_response': {'status': 'active'}},
            {'hook_event_name': 'PostToolUse', 'tool_name': 'unrelated.get_goal', 'tool_response': {'status': 'complete'}},
            {'hook_event_name': 'PostToolUse', 'tool_name': 'update_goal', 'tool_input': {'status': 'complete'}},
            {'hook_event_name': 'PostToolUse', 'tool_name': 'update_goal', 'tool_input': {'status': 'complete'}, 'tool_response': {}},
            {'hook_event_name': 'PostToolUseFailure', 'tool_name': 'update_goal', 'tool_input': {'status': 'complete'}},
            {'hook_event_name': 'PostToolUse', 'tool_name': 'get_goal', 'tool_response': 'The goal is complete'},
            {'hook_event_name': 'PostToolUse', 'tool_name': 'get_goal', 'tool_response': {'isError': True, 'status': 'complete'}},
        ):
            agent.ingest_hook('codex', {'session_id': 'fixture', **event}, self.root, self.state, NOW)
            self.assertEqual(self.sessions()[0]['state'], 'blocked')

    def test_old_real_input_wait_on_blocked_goal_remains_visible_after_retention_cutoff(self):
        self.assertEqual(self.command().returncode, 0)
        agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'PermissionRequest'},
                          self.root, self.state, NOW)
        sessions = self.sessions(NOW + timedelta(days=30))
        self.assertEqual([(s['id'], s['state']) for s in sessions], [('fixture', 'needsAttention')])

    def test_existing_marker_can_update_display_metadata_without_duplicate_identity(self):
        self.assertEqual(self.command('codex', 'blocked', 'fixture', '--title', 'First title').returncode, 0)
        self.assertEqual(self.command('codex', 'blocked', 'fixture', '--title', 'Updated title').returncode, 0)
        self.assertEqual([(s['id'], s['title']) for s in self.sessions()], [('fixture', 'Updated title')])

    def test_goal_store_bounds_retained_markers(self):
        for index in range(513):
            agent.set_goal_status(self.state, 'claude', str(index), 'blocked', NOW + timedelta(seconds=index))
        sessions = self.sessions()
        self.assertEqual(len(sessions), 512)
        self.assertNotIn('0', {s['id'] for s in sessions})
        self.assertIn('512', {s['id'] for s in sessions})
        self.assertEqual(len(list((self.state / 'goals').glob('*.json'))), 512)

    def test_known_helper_classification_survives_transcript_retention(self):
        self.assertEqual(self.command().returncode, 0)
        agent.ingest_hook('codex', {'session_id': 'parent', 'agent_id': 'fixture',
                                  'hook_event_name': 'SubagentStart'}, self.root, self.state, NOW)
        current = self.sessions()[0]
        self.assertTrue(current['isHelper'])
        self.assertEqual(current['parentId'], 'parent')
        for path in (self.state / 'hooks').glob('*.json'):
            path.unlink()
        aged = self.sessions(NOW + timedelta(days=30))[0]
        self.assertTrue(aged['isHelper'])
        self.assertEqual(aged['parentId'], 'parent')

    def test_goal_knowledge_stays_explicit_during_input_wait_and_after_clear(self):
        self.assertEqual(self.command().returncode, 0)
        agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'PermissionRequest'},
                          self.root, self.state, NOW)
        session = self.sessions()[0]
        self.assertEqual((session['state'], session.get('goalBlocked')), ('needsAttention', True))
        self.assertEqual(self.command('codex', 'active').returncode, 0)
        session = self.sessions()[0]
        self.assertEqual((session['state'], session.get('goalBlocked')), ('needsAttention', False))

    def test_incomplete_goal_store_does_not_report_definite_goal_clear(self):
        agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'Stop'},
                          self.root, self.state, NOW)
        directory = self.state / 'goals'
        directory.mkdir()
        (directory / 'broken.json').write_text('{')
        snapshot = agent.make_snapshot(self.root, self.state, NOW)
        self.assertNotIn('goalBlocked', snapshot['sessions'][0])
        self.assertTrue(snapshot['errors'])

    def test_positive_old_blocked_goal_retains_real_wait_despite_unrelated_corrupt_marker(self):
        self.assertEqual(self.command().returncode, 0)
        agent.ingest_hook('codex', {'session_id': 'fixture', 'hook_event_name': 'PermissionRequest'},
                          self.root, self.state, NOW)
        (self.state / 'goals/broken.json').write_text('{')
        snapshot = agent.make_snapshot(self.root, self.state, NOW + timedelta(days=30))
        self.assertEqual([(s['id'], s['state'], s.get('goalBlocked')) for s in snapshot['sessions']],
                         [('fixture', 'needsAttention', True)])
        self.assertTrue(snapshot['errors'])

    def test_marker_update_is_idempotent_and_malformed_marker_is_ignored(self):
        self.assertEqual(self.command().returncode, 0)
        before = {p.name: p.read_bytes() for p in (self.state / 'goals').glob('*.json')}
        self.assertEqual(self.command().returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in (self.state / 'goals').glob('*.json')}, before)
        (self.state / 'goals/bad.json').write_text('{"provider":"codex","id":"bad","state":"blocked"}')
        self.assertEqual(len(self.sessions()), 1)


if __name__ == '__main__':
    unittest.main()
