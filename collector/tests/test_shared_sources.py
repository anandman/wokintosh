"""Private native publication transport; all fixtures use fictional temporary homes."""
import base64
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('shared_collector', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc)
STAMP = '2026-11-08T12:00:00Z'


def publication():
    # Matches JSONEncoder.dateEncodingStrategy = .iso8601 and Data's base64 encoding.
    return {
        'version': 1, 'generatedAt': STAMP,
        'music': {'available': True, 'updatedAt': STAMP, 'status': 'Playing',
                  'title': 'Fictional Song', 'artist': 'Example Artist', 'album': 'Example Album',
                  'isPlaying': True, 'position': 12.5, 'duration': 180, 'artworkBase64': 'AQID'},
        'calendar': {'available': True, 'updatedAt': STAMP, 'status': 'Ready',
                     'calendars': [{'id': 'selected', 'title': 'Example Calendar', 'sourceTitle': 'Example Account'}],
                     'events': [{'id': 'event-1', 'title': 'Fictional Meeting',
                                 'startDate': '2026-11-08T13:00:00Z', 'endDate': '2026-11-08T14:00:00Z',
                                 'isAllDay': False, 'calendarID': 'selected', 'calendarTitle': 'Example Calendar'}]}}


class SharedSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.path = self.home / 'Library/Application Support/Wokintosh/shared-sources.json'

    def publish(self, value=None):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(publication() if value is None else value))
        self.path.chmod(0o600)
        return self.path

    def snapshot(self):
        # System collection shells out on macOS; keep this unrelated external boundary deterministic.
        with patch.object(agent, 'system_stats', return_value={'cpuPercent': 1}):
            return agent.make_snapshot(self.home, self.home / 'state', NOW)

    def test_missing_publication_keeps_linux_snapshot_without_shared_sources(self):
        with patch.object(agent.platform, 'system', return_value='Linux'):
            result = self.snapshot()
        self.assertNotIn('sharedSources', result)
        self.assertEqual(result['schemaVersion'], 1)
        self.assertEqual(result['host']['platform'], 'linux')
        self.assertEqual(result['errors'], [])

    def test_swift_dto_shape_is_included_without_private_fields(self):
        expected = publication()
        value = copy.deepcopy(expected)
        value['sharingOptions'] = {'calendarIDs': ['private']}
        value['music']['artworkPath'] = '/private/secret-image'
        value['calendar']['calendars'][0]['accountEmail'] = 'private@example.invalid'
        value['calendar']['events'][0].update(notes='private notes', location='private location',
                                              attendees=['private'], url='https://private.invalid')
        self.publish(value)
        result = self.snapshot()
        self.assertIn('sharedSources', result)
        self.assertEqual(result['sharedSources'], expected)
        self.assertEqual(result['errors'], [])
        self.assertEqual(result['system'], {'cpuPercent': 1})
        self.assertNotIn('private', json.dumps(result))


    def read(self):
        return agent.read_shared_sources(self.home, NOW)

    def test_owner_read_only_mode_is_private_enough(self):
        self.publish().chmod(0o400)
        self.assertEqual(self.read(), publication())

    def test_unavailable_sources_clear_content_even_if_private_fields_are_malformed(self):
        value = publication()
        value['music'].update(available=False, title={'private': 'title'}, artist='private artist',
                              album='private album', artworkBase64='private artwork', isPlaying=True)
        value['calendar'].update(available=False, calendars={'private': 'calendars'}, events='private events')
        self.publish(value)
        result = self.read()
        self.assertEqual(result['music'], {
            'available': False, 'updatedAt': STAMP, 'status': 'Playing',
            'title': '', 'artist': '', 'album': '', 'isPlaying': False, 'position': 0, 'duration': 0})
        self.assertEqual(result['calendar'], {
            'available': False, 'updatedAt': STAMP, 'status': 'Ready', 'calendars': [], 'events': []})
        self.assertNotIn('private', json.dumps(result))

    def test_stale_and_future_timestamps_are_preserved_and_freeze_playback(self):
        for target, field in [('publication', 'generatedAt'), ('music', 'updatedAt')]:
            for seconds in [-91, 31]:
                with self.subTest(target=target, seconds=seconds):
                    value = publication()
                    timestamp = (NOW + timedelta(seconds=seconds)).isoformat()
                    (value if target == 'publication' else value['music'])[field] = timestamp
                    self.publish(value)
                    result = self.read()
                    self.assertEqual((result if target == 'publication' else result['music'])[field], timestamp)
                    self.assertFalse(result['music']['isPlaying'])
                    self.assertEqual(result['music']['position'], 12.5)
                    self.assertEqual(result['calendar']['updatedAt'], STAMP)

    def test_freshness_boundary_and_timezone_offsets_are_accepted_without_rewriting(self):
        for timestamp in ['2026-11-08T11:58:30Z', '2026-11-08T12:00:30Z', '2026-11-08T04:00:00-08:00']:
            with self.subTest(timestamp=timestamp):
                value = publication()
                value['generatedAt'] = value['music']['updatedAt'] = timestamp
                self.publish(value)
                result = self.read()
                self.assertEqual(result['generatedAt'], timestamp)
                self.assertEqual(result['music']['updatedAt'], timestamp)
                self.assertTrue(result['music']['isPlaying'])

    def test_unsupported_or_bad_header_is_omitted(self):
        for key, bad_values in {
                'version': [2, True, 1.0, '1', None],
                'generatedAt': [None, 1794139200, '', '2026-11-08', '2026-11-08T12:00:00',
                                '2026-11-32T12:00:00Z', '2026-11-08T12:00:00+25:00']}.items():
            for bad in bad_values:
                with self.subTest(key=key, bad=bad):
                    value = publication()
                    value[key] = bad
                    self.publish(value)
                    self.assertIsNone(self.read())

    def test_invalid_music_is_omitted_while_valid_calendar_survives(self):
        bad_fields = {
            'available': [1, 'true', None], 'updatedAt': [None, '2026-11-08T12:00:00', 123],
            'status': [{}, 'x' * 513], 'title': [[], 'x' * 513], 'artist': [False], 'album': [None],
            'isPlaying': [1, 'true'], 'position': [-1, 181, True, '12', float('nan'), float('inf')],
            'duration': [-1, 604801, False, '180', float('nan'), float('inf')]}
        for field, values in bad_fields.items():
            for bad in values:
                with self.subTest(field=field, bad=bad):
                    value = publication()
                    value['music'][field] = bad
                    self.publish(value)
                    result = self.read()
                    self.assertIsNotNone(result)
                    self.assertNotIn('music', result)
                    self.assertEqual(result['calendar'], publication()['calendar'])
        for value in [None, [], 'private music']:
            payload = publication()
            payload['music'] = value
            self.publish(payload)
            self.assertNotIn('music', self.read())

    def test_missing_required_source_fields_do_not_poison_other_source(self):
        for source, fields in [('music', ['available', 'updatedAt', 'status', 'title', 'artist', 'album', 'isPlaying', 'position', 'duration']),
                               ('calendar', ['available', 'updatedAt', 'status', 'calendars', 'events'])]:
            for field in fields:
                with self.subTest(source=source, field=field):
                    value = publication()
                    del value[source][field]
                    self.publish(value)
                    result = self.read()
                    self.assertIsNotNone(result)
                    self.assertNotIn(source, result)
                    self.assertIn('calendar' if source == 'music' else 'music', result)

    def test_invalid_calendar_is_omitted_while_valid_music_survives(self):
        for field, bad in [('available', 1), ('updatedAt', '2026-11-08T12:00:00'), ('status', []),
                           ('calendars', {}), ('events', None), ('status', 'x' * 513)]:
            with self.subTest(field=field, bad=bad):
                value = publication()
                value['calendar'][field] = bad
                self.publish(value)
                result = self.read()
                self.assertIsNotNone(result)
                self.assertNotIn('calendar', result)
                self.assertEqual(result['music'], publication()['music'])
        for value in [None, [], 'private calendar']:
            payload = publication()
            payload['calendar'] = value
            self.publish(payload)
            self.assertNotIn('calendar', self.read())

    def test_invalid_unicode_cannot_poison_swift_snapshot_decoding(self):
        value = publication()
        value['music']['title'] = '\ud800'
        value['calendar']['events'].append(dict(value['calendar']['events'][0], id='invalid', title='\udfff'))
        self.publish(value)
        result = self.read()
        self.assertNotIn('music', result)
        self.assertEqual(result['calendar'], publication()['calendar'])

    def test_valid_strings_and_numeric_upper_bounds_are_preserved(self):
        value = publication()
        value['music'].update(title='é' * 512, status='s' * 512, duration=604800, position=604800)
        self.publish(value)
        result = self.read()
        self.assertEqual(result['music'], value['music'])

    def test_invalid_artwork_is_stripped_without_losing_music(self):
        for bad in [123, '', '***', 'AQID\n', 'AQI', 'AQID====',
                    base64.b64encode(b'x' * (128 * 1024 + 1)).decode()]:
            with self.subTest(kind=type(bad).__name__, length=len(bad) if isinstance(bad, str) else 0):
                value = publication()
                value['music']['artworkBase64'] = bad
                self.publish(value)
                result = self.read()
                self.assertIsNotNone(result)
                self.assertEqual(result['music']['title'], 'Fictional Song')
                self.assertNotIn('artworkBase64', result['music'])

    def test_maximum_artwork_and_omitted_optional_artwork_are_accepted(self):
        value = publication()
        value['music']['artworkBase64'] = base64.b64encode(b'x' * (128 * 1024)).decode()
        self.publish(value)
        self.assertEqual(self.read()['music']['artworkBase64'], value['music']['artworkBase64'])
        del value['music']['artworkBase64']
        self.publish(value)
        self.assertEqual(self.read()['music'], value['music'])

    def test_calendar_drops_unselected_malformed_and_out_of_window_events(self):
        value = publication()
        valid = value['calendar']['events'][0]
        changes = [
            {'calendarID': 'unselected'}, {'title': {}}, {'title': 'x' * 513}, {'id': None},
            {'isAllDay': 1}, {'startDate': '2026-11-08T13:00:00'}, {'endDate': 'invalid'},
            {'startDate': '2026-11-08T14:00:00Z'},
            {'startDate': '2026-11-08T15:00:00Z'},
            {'startDate': '2026-11-08T11:00:00Z', 'endDate': STAMP},
            {'startDate': '2026-11-15T12:00:00Z', 'endDate': '2026-11-15T13:00:00Z'}]
        invalid = [dict(valid, **change) for change in changes] + [None, 'private event']
        ongoing = dict(valid, id='ongoing', startDate='2026-11-07T12:00:00Z', endDate='2026-11-08T12:01:00Z')
        value['calendar']['events'] = invalid + [valid, ongoing]
        self.publish(value)
        result = self.read()
        self.assertEqual([event['id'] for event in result['calendar']['events']], ['ongoing', 'event-1'])

    def test_calendar_drops_bad_descriptors_and_their_events(self):
        value = publication()
        value['calendar']['calendars'] += [None, {'id': 'private', 'title': [], 'sourceTitle': 'Source'},
                                          {'id': 'long', 'title': 'x' * 513, 'sourceTitle': 'Source'}]
        value['calendar']['events'].append(dict(value['calendar']['events'][0], calendarID='private'))
        self.publish(value)
        result = self.read()
        self.assertEqual(result['calendar'], publication()['calendar'])

    def test_calendar_array_limits_bound_output_and_selected_membership(self):
        value = publication()
        value['calendar']['calendars'] = [dict(id=f'cal-{index}', title='Example', sourceTitle='Source') for index in range(130)]
        event = value['calendar']['events'][0]
        value['calendar']['events'] = [dict(event, id=f'event-{index}', calendarID='cal-0') for index in range(260)]
        value['calendar']['events'].insert(0, dict(event, id='unselected', calendarID='cal-129'))
        self.publish(value)
        result = self.read()
        self.assertEqual(len(result['calendar']['calendars']), 128)
        self.assertEqual(len(result['calendar']['events']), 256)
        self.assertNotIn('unselected', {event['id'] for event in result['calendar']['events']})

    def test_oversize_file_is_rejected_even_if_stat_size_was_smaller(self):
        value = publication()
        value['ignored'] = 'x' * (1024 * 1024)
        self.publish(value)
        self.assertIsNone(self.read())
        info = self.path.stat()
        observed = SimpleNamespace(st_mode=info.st_mode, st_uid=info.st_uid, st_size=0)
        with patch.object(agent.os, 'fstat', return_value=observed):
            self.assertIsNone(self.read())

    def test_exact_file_byte_limit_is_accepted(self):
        value = publication()
        value['ignored'] = ''
        encoded = json.dumps(value)
        value['ignored'] = 'x' * (1024 * 1024 - len(encoded.encode()))
        self.publish(value)
        self.assertEqual(self.path.stat().st_size, 1024 * 1024)
        self.assertEqual(self.read(), publication())

    def test_symlink_is_rejected(self):
        self.publish()
        target = self.path.with_name('private-target.json')
        self.path.rename(target)
        self.path.symlink_to(target)
        self.assertIsNone(self.read())

    def test_fifo_is_rejected_without_blocking(self):
        self.path.parent.mkdir(parents=True)
        os.mkfifo(self.path, 0o600)
        script = ("import importlib.util; from pathlib import Path; from datetime import datetime, timezone; "
                  f"s=importlib.util.spec_from_file_location('collector',{str(Path(agent.__file__).resolve())!r}); "
                  "a=importlib.util.module_from_spec(s); s.loader.exec_module(a); "
                  f"assert a.read_shared_sources(Path({str(self.home)!r}), datetime.now(timezone.utc)) is None")
        try:
            result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=3)
        except subprocess.TimeoutExpired:
            self.fail('native publication FIFO blocked the collector')
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_group_or_other_file_permissions_are_rejected(self):
        for mode in [0o644, 0o640, 0o601, 0o660]:
            with self.subTest(mode=oct(mode)):
                self.publish().chmod(mode)
                self.assertIsNone(self.read())

    def test_wrong_owner_is_rejected(self):
        self.publish()
        uid = os.getuid()
        with patch.object(agent.os, 'getuid', return_value=uid + 1):
            self.assertIsNone(self.read())

    def test_malformed_publication_cannot_break_healthy_agent_or_add_global_errors(self):
        log = self.home / '.codex/sessions/healthy.jsonl'
        log.parent.mkdir(parents=True)
        log.write_text(json.dumps({'type': 'session_meta', 'timestamp': STAMP,
                                   'payload': {'id': 'healthy', 'cwd': '/fictional/project'}}) + '\n')
        self.publish()
        for bad in [b'{', b'\xff', b'[]', b'null', b'[' * 1100 + b']' * 1100]:
            with self.subTest(bytes=len(bad)):
                self.path.write_bytes(bad)
                result = self.snapshot()
                self.assertNotIn('sharedSources', result)
                self.assertEqual([session['id'] for session in result['sessions']], ['healthy'])
                self.assertEqual(result['errors'], [])
                self.assertEqual(result['system'], {'cpuPercent': 1})


if __name__ == '__main__':
    unittest.main()
