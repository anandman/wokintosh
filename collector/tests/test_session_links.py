import importlib.util
import json
import os
import platform
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
            self.assertEqual(s['openURLs']['iOS']['fallbackLabel'], 'Open ChatGPT (new chat)')
            self.assertNotIn('_codexThreadID', s)

    def test_legacy_session_id_and_non_uuid_do_not_become_guessed_thread_links(self):
        for key, identity in [('session_id', THREAD), ('id', 'not-a-thread')]:
            p = self.log('case.jsonl', [{'type': 'session_meta', 'payload': {key: identity}}])
            self.assertIsNone(agent.session_open_urls(agent.read_codex(p, NOW)))

    def observe(self, event, bridge=BRIDGE, at=NOW):
        with patch.dict(os.environ, {'CLAUDE_CODE_BRIDGE_SESSION_ID': bridge}):
            agent.ingest_hook('claude', {'session_id': THREAD, 'hook_event_name': event, 'cwd': '/src/example'}, self.home, self.state, at)

    def live_record(self, process_pid=None, **changes):
        pid = process_pid or os.getpid()
        if platform.system() == 'Linux':
            start = (Path('/proc')/str(pid)/'stat').read_text().rsplit(')', 1)[1].split()[19]
            domain = 'linux:'+Path('/etc/machine-id').read_text().strip()+':'+os.readlink('/proc/self/ns/pid')
        else:
            start = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                                            text=True, env=dict(os.environ, LC_ALL='C', TZ='UTC')).strip()
            domain = 'darwin'
        record = dict(pid=pid, sessionId=THREAD, procStart=start, pidDomain=domain,
                      bridgeSessionId=BRIDGE, kind='interactive', prompt='PRIVATE BODY', token='PRIVATE TOKEN')
        record.update(changes)
        path = self.home/'.claude/sessions'/f'{pid}.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(record))
        return path

    def root_claude(self):
        self.log('.claude/projects/project/thread.jsonl', [
            {'sessionId': THREAD, 'timestamp': agent.stamp(NOW), 'type': 'assistant',
             'cwd': '/src/example', 'message': {'stop_reason': 'end_turn'}}])

    def test_live_registry_supplies_missing_bridge_without_changing_state_or_cache(self):
        self.root_claude(); self.observe('Stop', bridge=''); self.live_record()
        for _ in range(2):
            snapshot = agent.make_snapshot(self.home, self.state, NOW)
            s = snapshot['sessions'][0]
            self.assertEqual(snapshot['schemaVersion'], 1)
            self.assertEqual(s.get('openURLs'), {
                'macOS': {'primary': 'claude://code/'+BRIDGE, 'fallback': 'https://claude.ai/code/'+BRIDGE},
                'iOS': {'primary': 'claude://code/'+BRIDGE, 'fallback': 'https://claude.ai/code/'+BRIDGE}})
            self.assertEqual((s['state'], s['updatedAt']), ('finished', agent.stamp(NOW)))
            self.assertNotIn('_bridgeSessionID', s)
            persisted = ''.join(p.read_text() for p in self.state.rglob('*.json'))
            self.assertNotIn(BRIDGE, persisted)
            self.assertNotIn('PRIVATE', persisted)

    def test_live_registry_is_rechecked_after_warm_cache_and_disconnect(self):
        self.root_claude(); path = self.live_record()
        self.assertIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])
        path.write_text(json.dumps(dict(json.loads(path.read_text()), bridgeSessionId=None)))
        self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])
        self.live_record(); path.unlink()
        self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])

    def test_documented_hook_bridge_takes_precedence_over_live_registry(self):
        self.root_claude(); self.observe('Stop'); self.live_record(bridgeSessionId='session_0123456789abcdefDifferent')
        s = agent.make_snapshot(self.home, self.state, NOW)['sessions'][0]
        self.assertEqual(s['openURLs']['iOS']['primary'], 'claude://code/'+BRIDGE)

    def test_explicit_session_end_is_not_revived_by_live_registry(self):
        self.root_claude(); self.live_record(); self.observe('SessionEnd', bridge='')
        self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])
        self.observe('SessionStart', bridge='', at=NOW+timedelta(seconds=1))
        self.assertIn('openURLs', agent.make_snapshot(self.home, self.state, NOW+timedelta(seconds=1))['sessions'][0])

    def test_unrelated_hook_metadata_cannot_reactivate_an_ended_bridge(self):
        self.root_claude(); self.live_record(); self.observe('SessionEnd', bridge='')
        self.observe('UnknownMetadataEvent', bridge='', at=NOW+timedelta(seconds=1))
        self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW+timedelta(seconds=1))['sessions'][0])

    def test_dead_reused_foreign_and_mismatched_pid_records_are_rejected(self):
        self.root_claude()
        for changes in [dict(procStart='not-the-process-start'), dict(pidDomain='linux:another-host:pid:[1]'),
                        dict(pid=True), dict(pid=os.getpid()+1), dict(sessionId='another-session'),
                        dict(kind='background'), dict(bridgeSessionId='session_../invalid')]:
            with self.subTest(changes=changes):
                self.live_record(**changes)
                self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])
        path = self.live_record(); record = json.loads(path.read_text()); path.unlink()
        record['pid'] = 2147483647
        (path.parent/'2147483647.json').write_text(json.dumps(record))
        self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])

    def test_registry_never_creates_sessions_or_links_helpers(self):
        self.live_record()
        self.assertEqual(agent.make_snapshot(self.home, self.state, NOW)['sessions'], [])
        self.log('.claude/projects/project/'+THREAD+'/subagents/agent-child.jsonl', [
            {'sessionId': THREAD, 'timestamp': agent.stamp(NOW), 'type': 'assistant', 'message': {'stop_reason':'end_turn'}}])
        s = agent.make_snapshot(self.home, self.state, NOW)['sessions'][0]
        self.assertTrue(s['isHelper']); self.assertNotIn('openURLs', s)

    def test_unsafe_oversized_and_nonregular_registry_files_are_ignored(self):
        self.root_claude(); path = self.live_record(); content = path.read_text()
        outside = self.home/'external.json'; outside.write_text(content)
        for kind in ['symlink', 'fifo', 'oversized', 'malformed']:
            with self.subTest(kind=kind):
                path.unlink(missing_ok=True)
                if kind == 'symlink': path.symlink_to(outside)
                elif kind == 'fifo': os.mkfifo(path)
                elif kind == 'oversized': path.write_text(' '*65536+content)
                else: path.write_text('{invalid')
                self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])
        path.unlink(); path.parent.rmdir(); path.parent.symlink_to(self.home)
        (self.home/path.name).write_text(content)
        self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])

    def test_conflicting_live_bridge_associations_do_not_choose_a_session(self):
        self.root_claude(); self.live_record()
        child = subprocess.Popen([sys.executable, '-c', 'import time; print("ready", flush=True); time.sleep(15)'], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            self.live_record(process_pid=child.pid, bridgeSessionId='session_0123456789abcdefDifferent')
            self.assertNotIn('openURLs', agent.make_snapshot(self.home, self.state, NOW)['sessions'][0])
        finally:
            child.terminate(); child.wait(timeout=2); child.stdout.close()

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
