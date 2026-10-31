"""Regressions from the 0.2 follow-up: provider metadata and safe hook migration."""
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('followup_agent', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 30, 20, tzinfo=timezone.utc)


class LifecycleMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def read(self, rows, provider='codex'):
        path = self.root / 'session.jsonl'
        path.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        return getattr(agent, 'read_' + provider)(path, NOW + timedelta(minutes=20))
    def row(self, kind, payload, seconds=0):
        return {'type': kind, 'payload': payload, 'timestamp': agent.stamp(NOW + timedelta(seconds=seconds))}
    def codex(self, **meta):
        return [self.row('session_meta', {'id': 'child', 'cwd': '/src', **meta}),
                self.row('event_msg', {'type': 'task_complete'}, 1)]
    def test_guardian_top_level_parent_is_a_helper_in_snapshot_and_cache(self):
        rows = self.codex(source={'subagent': {'other': 'review'}}, parent_thread_id='actual-parent')
        path = self.root / '.codex/sessions/child.jsonl'
        path.parent.mkdir(parents=True)
        path.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        for _ in range(2):
            session = agent.make_snapshot(self.root, self.root / 'state', NOW + timedelta(seconds=2))['sessions'][0]
            self.assertEqual(session['parentId'], 'actual-parent')
            self.assertTrue(session.get('isHelper'))
    def test_unknown_parent_helper_keeps_real_identity(self):
        session = self.read(self.codex(source={'subagent': {'other': 'review'}}))
        self.assertTrue(session.get('isHelper'))
        self.assertIsNone(session['parentId'])
        self.assertEqual(session['id'], 'child')
    def test_completion_timestamp_ignores_metadata_and_token_accounting(self):
        rows = self.codex() + [self.row('turn_context', {'model': 'fixture'}, 200),
                               self.row('event_msg', {'type': 'token_count'}, 300)]
        session = self.read(rows)
        self.assertEqual(session['state'], 'finished')
        self.assertEqual(session['updatedAt'], agent.stamp(NOW + timedelta(seconds=1)))
    def test_repeated_session_metadata_does_not_reset_completed_turn(self):
        rows = self.codex() + [self.row('session_meta', {'id': 'child', 'cwd': '/src/new'}, 500)]
        session = self.read(rows)
        self.assertEqual(session['state'], 'finished')
        self.assertEqual(session['updatedAt'], agent.stamp(NOW + timedelta(seconds=1)))
        self.assertEqual(session['project'], 'new')
    def test_claude_completion_timestamp_ignores_queue_metadata(self):
        rows = [{'type': 'assistant', 'sessionId': 'a', 'timestamp': agent.stamp(NOW),
                 'message': {'stop_reason': 'end_turn'}},
                {'type': 'queue-operation', 'sessionId': 'a', 'timestamp': agent.stamp(NOW + timedelta(minutes=10))}]
        self.assertEqual(self.read(rows, 'claude')['updatedAt'], agent.stamp(NOW))
    def test_resume_hook_does_not_replay_completion_as_new_activity(self):
        session = agent.base_session('a', 'codex', '', NOW)
        session.update(state='finished', activity='Turn completed')
        result = agent.apply_hook_state(session, {'session_id': 'a', 'hook_event_name': 'SessionStart'}, NOW + timedelta(hours=1))
        self.assertEqual((result['state'], result['updatedAt']), ('finished', agent.stamp(NOW)))
    def test_unknown_hook_does_not_refresh_lifecycle(self):
        session = agent.base_session('a', 'codex', '', NOW)
        session.update(state='finished', activity='Turn completed')
        result = agent.apply_hook_state(session, {'session_id': 'a', 'hook_event_name': 'PreCompact'}, NOW + timedelta(hours=1))
        self.assertEqual(result, session)
    def test_legacy_cache_without_helper_flag_remains_valid(self):
        session = agent.base_session('a', 'codex', '', NOW, parent='parent')
        session.pop('isHelper', None)
        self.assertTrue(agent.valid_session(session).get('isHelper'))


class HookSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / '.codex/config.toml'
        self.json_path = self.config.with_name('hooks.json')
        self.config.parent.mkdir()
    def tearDown(self):
        self.temp.cleanup()
    def install(self, dry_run=False):
        args = [sys.executable, str(Path(agent.__file__).resolve()), '--home', str(self.root),
                '--state-dir', str(self.root / 'state'), 'install-hooks', '--provider', 'codex']
        if dry_run:
            args.append('--dry-run')
        return subprocess.run(args, capture_output=True, text=True, timeout=10)
    def test_inline_hooks_preserve_all_unrelated_text_and_trust(self):
        original = '''# personal configuration\nmodel = "fixture"\n[[hooks.Stop]] # existing group\nmatcher = "keep"\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = 'unrelated-hook' # retain this\ntimeout = 11\n[hooks.state."fixture:stop:0:0"]\ntrusted_hash = "leave-exactly"\n[other]\nkeep = true # trailing comment\n'''
        self.config.write_text(original)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.config.read_text()
        self.assertTrue(installed.startswith(original))
        self.assertIn('Wokintosh · Done', installed)
        self.assertFalse(self.json_path.exists())
        self.assertTrue(list(self.config.parent.glob('config.toml.wokintosh-backup-*')))
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.config.read_text(), installed)
    def test_marked_toml_updates_only_own_command_and_status_preserving_extras(self):
        original = '''# keep comment\n[[hooks.Stop]]\nmatcher = 'specific'\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = '/old hook # wokintosh-observer' # command note\nstatusMessage = "Old label" # status note\ntimeout = 7\nasync = true\n[hooks.Stop.hooks.extra]\npreserve = "metadata"\n[hooks.state."fixture"]\ntrusted_hash = "unchanged"\n'''
        self.config.write_text(original)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.config.read_text()
        for text in ('# keep comment', "matcher = 'specific'", '# command note', '# status note',
                     'timeout = 7', 'async = true', 'preserve = "metadata"', 'trusted_hash = "unchanged"'):
            self.assertIn(text, installed)
        self.assertNotIn('/old hook', installed)
        self.assertEqual(installed.count('Wokintosh · Done'), 1)
        self.assertFalse(self.json_path.exists())
    def test_migrate_only_owned_json_hooks_into_existing_toml(self):
        self.config.write_text('[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "other"\n')
        self.json_path.write_text(json.dumps(agent.hook_install_config('codex', '/old hook', {})))
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.json_path.exists(), 'owned-only JSON source must be removed after its backup')
        self.assertIn('command = "other"', self.config.read_text())
        self.assertTrue(list(self.config.parent.glob('hooks.json.wokintosh-backup-*')))
    def test_mixed_json_retains_unrelated_entries_and_reports_dual_source(self):
        self.config.write_text('[hooks]\n# use TOML\n')
        other = {'type': 'command', 'command': 'unrelated-hook', 'extra': {'keep': True}}
        existing = agent.hook_install_config('codex', '/old hook', {'other': {'keep': True}, 'hooks': {'Stop': [{'matcher': '*', 'hooks': [other]}]}})
        self.json_path.write_text(json.dumps(existing))
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        remaining = json.loads(self.json_path.read_text())
        self.assertEqual(remaining['other'], {'keep': True})
        self.assertEqual(remaining['hooks']['Stop'], [{'matcher': '*', 'hooks': [other]}])
        self.assertNotIn('wokintosh-observer', self.json_path.read_text())
        self.assertIn('both', (result.stdout + result.stderr).lower())
        self.assertIn('unrelated', (result.stdout + result.stderr).lower())
        installed = self.config.read_text()
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.config.read_text(), installed)
    def test_dry_run_never_changes_either_source(self):
        self.config.write_text('[hooks]\n')
        self.json_path.write_text(json.dumps(agent.hook_install_config('codex', '/old hook', {})))
        before = (self.config.read_bytes(), self.json_path.read_bytes())
        result = self.install(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.config.read_bytes(), self.json_path.read_bytes()), before)
        self.assertFalse(list(self.config.parent.glob('*.wokintosh-backup-*')))
    def test_inline_value_form_refuses_without_any_partial_write(self):
        self.config.write_text('hooks = { Stop = [{ hooks = [{ type = "command", command = "other" }] }] }\n')
        before = self.config.read_bytes()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse(self.json_path.exists())
    def test_duplicate_toml_with_nested_metadata_refuses_without_reparenting_it(self):
        original = """[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "/first # wokintosh-observer"
[hooks.Stop.hooks.extra]
preserve = "first"
[[hooks.Stop.hooks]]
type = "command"
command = "/second # wokintosh-observer"
[hooks.Stop.hooks.extra]
preserve = "second"
"""
        self.config.write_text(original)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), original)
        self.assertFalse(self.json_path.exists())

    def test_duplicate_toml_with_unparsed_assignments_refuses_without_any_write(self):
        prefix = """[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "/first # wokintosh-observer"
[[hooks.Stop.hooks]]
type = "command"
command = "/second # wokintosh-observer"
"""
        for assignment in ('extra.preserve = "second"', '"extra"."preserve" = "second"',
                           'extra-flag = true', '99 = "metadata"'):
            with self.subTest(assignment=assignment):
                original = prefix + assignment + '\n'
                self.config.write_text(original)
                result = self.install()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), original)
                self.assertFalse(self.json_path.exists())
                self.assertFalse(list(self.config.parent.glob('*.wokintosh-backup-*')))

    def test_first_marked_toml_preserves_dotted_and_unknown_assignments(self):
        metadata = 'extra.preserve = "first" # keep dotted metadata\nextra-flag = true\n99 = "numeric key"\n'
        original = '[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "/first # wokintosh-observer"\n' + metadata
        self.config.write_text(original)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.config.read_text()
        self.assertIn(metadata, installed)
        self.assertIn('Wokintosh · Done', installed)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.config.read_text(), installed)

    def test_quoted_dotted_inline_hooks_refuse_before_json_source_creation(self):
        self.config.write_text('"hooks".Stop = [{ hooks = [{ type = "command", command = "other" }] }]\n')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.json_path.exists())

    def test_json_marker_duplicates_collapse_only_within_one_group(self):
        own = {'type': 'command', 'command': '/old # wokintosh-observer'}
        other = {'type': 'command', 'command': 'other'}
        existing = {'hooks': {'Stop': [{'hooks': [own, copy.deepcopy(own), other]}, {'hooks': [copy.deepcopy(own)]}]}}
        result = agent.hook_install_config('codex', '/new hook', existing)
        handlers = [h for e in result['hooks']['Stop'] for h in e['hooks']]
        self.assertEqual(sum(agent.MARKER in h['command'] for h in handlers), 2)
        self.assertEqual([len(e['hooks']) for e in result['hooks']['Stop']], [2, 1])
        self.assertIn(other, handlers)
    def test_json_preserves_distinct_matcher_groups_and_handler_metadata(self):
        own = {'type': 'command', 'command': '/old # wokintosh-observer', 'timeout': 7, 'extra': {'preserve': True}}
        existing = {'hooks': {'PreToolUse': [
            {'matcher': 'Bash', 'groupExtra': 'first', 'hooks': [copy.deepcopy(own)]},
            {'matcher': 'Write', 'groupExtra': 'second', 'hooks': [copy.deepcopy(own)]}]}}
        result = agent.hook_install_config('codex', '/new hook', existing)
        groups = result['hooks']['PreToolUse']
        self.assertEqual([g['matcher'] for g in groups], ['Bash', 'Write'])
        self.assertEqual([g['groupExtra'] for g in groups], ['first', 'second'])
        self.assertTrue(all(len(g['hooks']) == 1 for g in groups))
        self.assertTrue(all(g['hooks'][0]['timeout'] == 7 and g['hooks'][0]['extra'] == {'preserve': True} for g in groups))
        self.assertEqual(agent.hook_install_config('codex', '/new hook', result), result)

    def test_json_same_group_preserves_own_handlers_with_distinct_metadata(self):
        first = {'type': 'command', 'command': '/old # wokintosh-observer', 'timeout': 7}
        second = {**first, 'timeout': 12, 'async': True}
        existing = {'hooks': {'Stop': [{'hooks': [first, second]}]}}
        result = agent.hook_install_config('codex', '/new hook', existing)
        self.assertEqual([h['timeout'] for h in result['hooks']['Stop'][0]['hooks']], [7, 12])
        self.assertTrue(result['hooks']['Stop'][0]['hooks'][1]['async'])

    def test_toml_preserves_distinct_matcher_groups_and_handler_metadata(self):
        original = """[[hooks.PreToolUse]]
matcher = "Bash"
groupExtra = "first"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/old # wokintosh-observer"
timeout = 7
[[hooks.PreToolUse]]
matcher = "Write"
groupExtra = "second"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/old # wokintosh-observer"
timeout = 12
async = true
"""
        self.config.write_text(original)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.config.read_text()
        # Both existing groups retain a real observer handler, not an empty matcher group.
        for group in installed.split('[[hooks.PreToolUse]]')[1:3]:
            self.assertIn(agent.MARKER, group.split('[[hooks.', 1)[-1])
        self.assertIn('matcher = "Bash"\ngroupExtra = "first"', installed)
        self.assertIn('matcher = "Write"\ngroupExtra = "second"', installed)
        self.assertIn('timeout = 7', installed)
        self.assertIn('timeout = 12\nasync = true', installed)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.config.read_text(), installed)

    def test_mixed_migration_keeps_additional_matcher_and_metadata(self):
        self.config.write_text('[[hooks.PreToolUse]]\nmatcher = "Bash"\n[[hooks.PreToolUse.hooks]]\ntype = "command"\ncommand = "/old # wokintosh-observer"\n')
        owned = {'type': 'command', 'command': '/old # wokintosh-observer', 'timeout': 17, 'extra': {'preserve': True}}
        self.json_path.write_text(json.dumps({'hooks': {'PreToolUse': [{'matcher': 'Write', 'groupExtra': 42, 'hooks': [owned]}]}}))
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.config.read_text()
        self.assertIn('matcher = "Bash"', installed)
        self.assertIn('"matcher" = "Write"', installed)
        self.assertIn('"groupExtra" = 42', installed)
        self.assertIn('"timeout" = 17', installed)
        self.assertIn('"extra" = { "preserve" = true }', installed)
        self.assertEqual(installed.count('[[hooks.PreToolUse.hooks]]'), 2)
        self.assertFalse(self.json_path.exists())
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.config.read_text(), installed)

    def test_event_labels_are_distinct_and_clear(self):
        config = agent.hook_install_config('codex', 'safe hook', {})
        labels = {name: groups[0]['hooks'][0]['statusMessage'] for name, groups in config['hooks'].items()}
        self.assertEqual(labels['Stop'], 'Wokintosh · Done')
        self.assertEqual(labels['PermissionRequest'], 'Wokintosh · Needs permission')
        self.assertEqual(labels['UserPromptSubmit'], 'Wokintosh · Working')
        self.assertNotEqual(labels['SessionStart'], labels['Stop'])


class CPUSamplingTests(unittest.TestCase):
    def test_macos_cpu_remains_available_when_memory_command_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            with patch.object(agent.platform, 'system', return_value='Darwin'), \
                 patch.object(agent, 'command_output', return_value=''), \
                 patch.object(agent, 'macos_cpu_ticks', side_effect=[(1000, 600), (1400, 700)], create=True):
                agent.system_stats(home, home / 'state')
                second = agent.system_stats(home, home / 'state')
            self.assertEqual(second.get('cpuPercent'), 75)

    def test_macos_uses_counter_delta_not_process_lifetime_cpu(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            def output(args):
                if args[-1] == 'hw.memsize': return '10000'
                if args == ['/usr/bin/vm_stat']: return 'Mach Virtual Memory Statistics: (page size of 4096 bytes)\nPages free: 1.'
                if args == ['df', '-P', '-k']: return ''
                self.fail('CPU must use host tick counters, not ps process averages')
            with patch.object(agent.platform, 'system', return_value='Darwin'), \
                 patch.object(agent, 'command_output', side_effect=output), \
                 patch.object(agent, 'macos_cpu_ticks', side_effect=[(1000, 600), (1400, 700)], create=True):
                first = agent.system_stats(home, home / 'state')
                second = agent.system_stats(home, home / 'state')
            self.assertNotIn('cpuPercent', first)
            self.assertEqual(second['cpuPercent'], 75)


if __name__ == '__main__':
    unittest.main()
