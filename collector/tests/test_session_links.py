import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('agent_links', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 11, 20, 20, tzinfo=timezone.utc)
THREAD = '019abe76-78ea-7be1-afc5-f5e8f38c5d90'
BRIDGE = 'session_01PzkYfPbojnGcEzD4wizzvN'


class SessionLinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.state = self.home / 'state'

    def tearDown(self):
        self.tmp.cleanup()

    def log(self, name, rows):
        p = self.home / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return p

    def test_codex_uses_verified_thread_uuid_and_preserves_it_through_warm_cache(self):
        self.log('.codex/sessions/thread.jsonl', [
            {'type': 'session_meta', 'timestamp': agent.stamp(NOW), 'payload': {'id': THREAD, 'cwd': '/src/example'}},
            {'type': 'event_msg', 'timestamp': agent.stamp(NOW), 'payload': {'type': 'task_started'}}])
        for _ in range(2):
            s = agent.make_snapshot(self.home, self.state, NOW)['sessions'][0]
            self.assertEqual(s['openURLs']['iOS']['primary'], 'codex://threads/'+THREAD)
            self.assertEqual(s['openURLs']['macOS']['primary'], 'codex://threads/'+THREAD)
            self.assertEqual(s['openURLs']['iOS']['fallback'], 'https://chatgpt.com/app')
            self.assertNotIn('_codexThreadID', s)

    def test_legacy_session_id_and_non_uuid_do_not_become_guessed_thread_links(self):
        for key, identity in [('session_id', THREAD), ('id', 'not-a-thread')]:
            p = self.log('case.jsonl', [{'type': 'session_meta', 'payload': {key: identity}}])
            self.assertIsNone(agent.session_open_urls(agent.read_codex(p, NOW)))

    def observe(self, event, bridge=BRIDGE, at=NOW):
        with patch.dict(os.environ, {'CLAUDE_CODE_BRIDGE_SESSION_ID': bridge}):
            agent.ingest_hook('claude', {'session_id': THREAD, 'hook_event_name': event, 'cwd': '/src/example'}, self.home, self.state, at)

    def test_bridge_association_survives_newer_transcript_without_rewriting_lifecycle(self):
        self.observe('UserPromptSubmit')
        later = NOW+timedelta(seconds=10)
        self.log('.claude/projects/project/thread.jsonl', [
            {'sessionId': THREAD, 'timestamp': agent.stamp(later), 'type': 'assistant', 'cwd': '/src/example', 'message': {'stop_reason': 'end_turn'}}])
        for _ in range(2):
            s = agent.make_snapshot(self.home, self.state, later)['sessions'][0]
            self.assertEqual(s['openURLs']['iOS']['primary'], 'claude://code/'+BRIDGE)
            self.assertEqual(s['openURLs']['iOS']['fallback'], 'https://claude.ai/code/'+BRIDGE)
            self.assertEqual(s['state'], 'finished')
            self.assertEqual(s['updatedAt'], agent.stamp(later))
            self.assertNotIn('_bridgeSessionID', s)
        self.observe('SessionEnd', bridge='', at=later+timedelta(seconds=1))
        s = agent.make_snapshot(self.home, self.state, later+timedelta(seconds=2))['sessions'][0]
        self.assertIsNone(s.get('openURLs'))

    def test_missing_malformed_and_synthetic_bridge_targets_are_not_emitted(self):
        for value in ['', THREAD, 'session_../../bad', 'session_bad?token=oops', 'session_'+('a'*300)]:
            self.observe('UserPromptSubmit', bridge=value)
            s = agent.make_snapshot(self.home, self.state, NOW)['sessions'][0]
            self.assertIsNone(s.get('openURLs'))
        self.observe('UserPromptSubmit')
        s = agent.make_snapshot(self.home, self.state, NOW)['sessions'][0]
        s.update(isHelper=True)
        self.assertIsNone(agent.session_open_urls(s))

    def test_hook_cli_stays_neutral_and_never_emits_the_bridge_id(self):
        env = dict(os.environ, CLAUDE_CODE_BRIDGE_SESSION_ID=BRIDGE)
        p = subprocess.run([sys.executable, str(Path(agent.__file__)), '--home', str(self.home), '--state-dir', str(self.state), 'hook', '--provider', 'claude'],
                           input=json.dumps({'session_id': THREAD, 'hook_event_name': 'UserPromptSubmit'}), text=True, capture_output=True, env=env)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), '{}')
        self.assertNotIn(BRIDGE, p.stdout+p.stderr)
        self.assertEqual(agent.make_snapshot(self.home, self.state, NOW)['sessions'][0]['openURLs']['iOS']['primary'], 'claude://code/'+BRIDGE)
