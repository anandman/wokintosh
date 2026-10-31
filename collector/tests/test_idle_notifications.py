"""Claude idle notices must not invent attention, including persisted older summaries."""
import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location('idle_agent', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 30, 20, tzinfo=timezone.utc)


class IdleNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'

    def tearDown(self):
        self.temp.cleanup()

    def event(self, name, seconds, **fields):
        return {'session_id': 'fixture', 'hook_event_name': name,
                '_observedAt': agent.stamp(NOW + timedelta(seconds=seconds)), **fields}

    def summary(self, events, state='needsAttention', activity='Input needed', **fields):
        entry = agent.base_session('fixture', 'claude', '/src/fixture', NOW, 'Preserve title')
        entry.update(state=state, activity=activity, updatedAt=events[-1]['_observedAt'],
                     _hookEvents=events, **fields)
        path = self.state / 'hooks/legacy.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(entry) + '\n')
        return path

    def snapshot(self, seconds=180):
        return agent.make_snapshot(self.root, self.state, NOW + timedelta(seconds=seconds))['sessions'][0]

    def transcript(self, seconds, completed):
        path = self.root / '.claude/projects/fixture/session.jsonl'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'type': 'assistant', 'sessionId': 'fixture', 'cwd': '/src/transcript',
                                    'timestamp': agent.stamp(NOW + timedelta(seconds=seconds)),
                                    'message': {'stop_reason': 'end_turn' if completed else 'tool_use'}}) + '\n')

    def test_idle_after_stop_preserves_done_and_its_completion_timestamp(self):
        start = agent.base_session('fixture', 'claude', '', NOW)
        stopped = agent.apply_hook_state(start, self.event('Stop', 1), NOW + timedelta(seconds=1))
        result = agent.apply_hook_state(stopped, self.event('Notification', 61, notification_type='idle_prompt'), NOW + timedelta(seconds=61))
        self.assertEqual(result, stopped)
        self.assertEqual((result['state'], result['updatedAt']), ('finished', agent.stamp(NOW + timedelta(seconds=1))))

    def test_idle_only_unknown_session_becomes_idle_without_claiming_completion(self):
        start = agent.base_session('fixture', 'claude', '', NOW)
        result = agent.apply_hook_state(start, self.event('Notification', 60, notification_type='idle_prompt'), NOW + timedelta(seconds=60))
        self.assertEqual((result['state'], result['activity'], result['updatedAt']), ('idle', 'Waiting for a task', agent.stamp(NOW)))

    def test_other_notifications_do_not_invent_attention_or_completion(self):
        start = agent.base_session('fixture', 'claude', '', NOW)
        for notification in ('agent_completed', 'auth_success', 'elicitation_complete', 'future_unknown'):
            with self.subTest(notification=notification):
                self.assertEqual(agent.apply_hook_state(start, self.event('Notification', 60, notification_type=notification), NOW + timedelta(seconds=60)), start)

    def test_missing_transcript_legacy_stop_then_idle_is_repaired_from_history(self):
        events = [self.event('Stop', 1), self.event('Notification', 61, notification_type='idle_prompt')]
        path = self.summary(events, _pendingInput={'calls': {}, 'unknownSince': events[-1]['_observedAt']})
        original = path.read_bytes()
        first = self.snapshot()
        self.assertEqual((first['state'], first['activity'], first['updatedAt']),
                         ('finished', 'Turn completed', events[0]['_observedAt']))
        self.assertEqual((first['title'], first['project']), ('Preserve title', 'fixture'))
        self.assertEqual(self.snapshot(181), first)
        self.assertEqual(path.read_bytes(), original, 'snapshot repair must not rewrite original evidence')

    def test_legacy_idle_only_history_does_not_claim_completion_or_clear_an_ambiguous_wait(self):
        events = [self.event('Notification', 60, notification_type='idle_prompt'),
                  self.event('Notification', 120, notification_type='idle_prompt')]
        self.summary(events, _pendingInput={'calls': {}, 'unknownSince': events[0]['_observedAt']})
        result = self.snapshot()
        self.assertEqual((result['state'], result['activity']), ('needsAttention', 'Input needed'))
        self.assertNotEqual(result['state'], 'finished')
        self.assertEqual(self.snapshot(181), result)

    def test_truncated_legacy_history_preserves_an_unknown_wait_without_progress(self):
        events = [self.event('Notification', 60, notification_type='idle_prompt'),
                  self.event('Notification', 120, notification_type='idle_prompt')]
        self.summary(events, _pendingInput={'calls': {}, 'unknownSince': agent.stamp(NOW)})
        result = self.snapshot()
        self.assertEqual((result['state'], result['activity']), ('needsAttention', 'Input needed'))

    def test_known_approval_outside_history_is_not_cleared_by_idle_notices(self):
        events = [self.event('Notification', 60, notification_type='idle_prompt')]
        path = self.summary(events, activity='Approval needed')
        entry = json.loads(path.read_text())
        entry['updatedAt'] = agent.stamp(NOW)
        path.write_text(json.dumps(entry))
        result = self.snapshot()
        self.assertEqual((result['state'], result['activity'], result['updatedAt']),
                         ('needsAttention', 'Approval needed', agent.stamp(NOW)))

    def test_legacy_real_permission_and_elicitation_stay_pending_until_progress(self):
        for name, fields, expected_activity in (
                ('PermissionRequest', {}, 'Approval needed'),
                ('Notification', {'notification_type': 'permission_prompt'}, 'Input needed'),
                ('Notification', {'notification_type': 'elicitation_dialog'}, 'Input needed')):
            with self.subTest(name=name, fields=fields):
                pending = self.event(name, 10, **fields)
                events = [self.event('Stop', 1), pending, self.event('Notification', 70, notification_type='idle_prompt')]
                self.summary(events)
                result = self.snapshot()
                self.assertEqual((result['state'], result['activity'], result['updatedAt']),
                                 ('needsAttention', expected_activity, pending['_observedAt']))
                self.summary(events + [self.event('UserPromptSubmit', 100)])
                result = self.snapshot()
                self.assertEqual((result['state'], result['updatedAt']), ('working', agent.stamp(NOW + timedelta(seconds=100))))

    def test_legacy_false_summary_merged_onto_transcript_keeps_true_stop_time(self):
        self.transcript(0, completed=False)
        self.summary([self.event('Stop', 1), self.event('Notification', 61, notification_type='idle_prompt')])
        result = self.snapshot()
        self.assertEqual((result['state'], result['updatedAt']), ('finished', agent.stamp(NOW + timedelta(seconds=1))))
        self.assertEqual(result['project'], 'transcript')
        self.assertEqual(self.snapshot(181), result)

    def test_legacy_idle_after_newer_transcript_activity_does_not_override_it(self):
        self.transcript(30, completed=False)
        self.summary([self.event('Stop', 1), self.event('Notification', 61, notification_type='idle_prompt')])
        result = self.snapshot()
        self.assertEqual((result['state'], result['updatedAt']), ('working', agent.stamp(NOW + timedelta(seconds=30))))

    def test_explicit_pending_input_outside_bounded_history_is_preserved(self):
        at = agent.stamp(NOW - timedelta(seconds=10))
        events = [self.event('Notification', 60, notification_type='idle_prompt')]
        self.summary(events, _pendingInput={'calls': {'real-input': at}, 'unknownSince': None})
        result = self.snapshot()
        self.assertEqual(result['state'], 'needsAttention')
        self.assertEqual(result['updatedAt'], at)
        self.summary(events + [self.event('PostToolUse', 90, tool_name='request_user_input', tool_use_id='real-input')],
                     state='working', activity='Working',
                     _pendingInput={'calls': {}, 'unknownSince': None})
        # The real matching result is positive progress even though only its observation remains.
        self.assertEqual(self.snapshot()['state'], 'working')

    def test_ingest_repairs_existing_legacy_state_before_another_idle_notice(self):
        events = [self.event('Stop', 1), self.event('Notification', 61, notification_type='idle_prompt')]
        self.summary(events)
        # Write under the actual hashed identity so ingest reads the same old summary.
        old = next((self.state / 'hooks').glob('*.json'))
        import hashlib
        target = self.state / 'hooks' / (hashlib.sha256(b'claude\0fixture').hexdigest() + '.json')
        old.rename(target)
        agent.ingest_hook('claude', self.event('Notification', 121, notification_type='idle_prompt'),
                          self.root, self.state, NOW + timedelta(seconds=121))
        entry = json.loads(target.read_text())
        self.assertEqual((entry['state'], entry['updatedAt']), ('finished', events[0]['_observedAt']))
        self.assertEqual(len(entry['_hookEvents']), 3)

    def test_real_ingest_preserves_lifecycle_and_pending_waits_after_history_rollover(self):
        cases = (
            ('PermissionRequest', {}, 'needsAttention', 'Approval needed'),
            ('Notification', {'notification_type': 'permission_prompt'}, 'needsAttention', 'Input needed'),
            ('Notification', {'notification_type': 'elicitation_dialog'}, 'needsAttention', 'Input needed'),
            ('PreToolUse', {'tool_name': 'request_user_input'}, 'needsAttention', 'Input needed'),
            ('Stop', {}, 'finished', 'Turn completed'),
            ('Notification', {'notification_type': 'idle_prompt'}, 'idle', 'Waiting for a task'))
        for name, fields, expected_state, expected_activity in cases:
            with self.subTest(name=name, fields=fields), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                self.state = self.root / 'state'
                initial = self.event(name, 1, **fields)
                agent.ingest_hook('claude', initial, self.root, self.state, NOW + timedelta(seconds=1))
                for index in range(agent.MAX_HOOK_EVENTS + 1):
                    seconds = 60 + index
                    agent.ingest_hook('claude', self.event('Notification', seconds, notification_type='idle_prompt'),
                                      self.root, self.state, NOW + timedelta(seconds=seconds))
                path = next((self.state / 'hooks').glob('*.json'))
                stored = json.loads(path.read_text())
                self.assertEqual(len(stored['_hookEvents']), agent.MAX_HOOK_EVENTS)
                self.assertTrue(all(event.get('notification_type') == 'idle_prompt' for event in stored['_hookEvents']),
                                'the original lifecycle event must really have left bounded history')
                roundtrip = agent.valid_session(json.loads(json.dumps(stored)), 'claude')
                want = (expected_state, expected_activity, initial['_observedAt'])
                for result in (stored, roundtrip, self.snapshot(), self.snapshot(181)):
                    self.assertEqual((result['state'], result['activity'], result['updatedAt']), want)
                if name == 'PreToolUse':
                    self.assertEqual(roundtrip['_pendingInput'], {'calls': {}, 'unknownSince': initial['_observedAt']})
                wire = self.snapshot()
                self.assertEqual(set(wire), {'id', 'provider', 'title', 'project', 'state', 'updatedAt', 'activity', 'parentId', 'isHelper', 'goalBlocked'})
                if expected_state != 'idle':
                    self.transcript(0, completed=False)
                    merged = self.snapshot()
                    self.assertEqual((merged['state'], merged['activity'], merged['updatedAt']), want)
                    self.assertEqual(merged['project'], 'transcript')
                agent.ingest_hook('claude', self.event('UserPromptSubmit', 190), self.root, self.state, NOW + timedelta(seconds=190))
                progressed = json.loads(path.read_text())
                self.assertEqual((progressed['state'], progressed['updatedAt']), ('working', agent.stamp(NOW + timedelta(seconds=190))))
                self.assertNotIn('_pendingInput', progressed)

    def test_repaired_legacy_completion_survives_later_actual_ingest_history_rollover(self):
        events = [self.event('Stop', 1), self.event('Notification', 61, notification_type='idle_prompt')]
        old = self.summary(events)
        import hashlib
        path = self.state / 'hooks' / (hashlib.sha256(b'claude\0fixture').hexdigest() + '.json')
        old.rename(path)
        for index in range(agent.MAX_HOOK_EVENTS + 1):
            seconds = 120 + index
            agent.ingest_hook('claude', self.event('Notification', seconds, notification_type='idle_prompt'),
                              self.root, self.state, NOW + timedelta(seconds=seconds))
        stored = json.loads(path.read_text())
        self.assertTrue(all(event.get('notification_type') == 'idle_prompt' for event in stored['_hookEvents']))
        for result in (stored, agent.valid_session(stored, 'claude'), self.snapshot(200), self.snapshot(201)):
            self.assertEqual((result['state'], result['activity'], result['updatedAt']),
                             ('finished', 'Turn completed', events[0]['_observedAt']))


if __name__ == '__main__':
    unittest.main()
