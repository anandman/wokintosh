"""Explicit, lossless Codex hook source consolidation, using isolated homes only."""
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import tomllib
except ImportError:  # The collector supports Python 3.10 without a TOML dependency.
    tomllib = None

spec = importlib.util.spec_from_file_location('consolidation_agent', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class HookConsolidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / '.codex/config.toml'
        self.json_path = self.config.with_name('hooks.json')
        self.config.parent.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def install(self, *flags, provider='codex'):
        return subprocess.run([sys.executable, str(Path(agent.__file__).resolve()),
                               '--home', str(self.root), '--state-dir', str(self.root / 'state'),
                               'install-hooks', '--provider', provider, *flags],
                              capture_output=True, text=True, timeout=10)

    def write_json(self, value):
        self.json_path.write_text(json.dumps(value, indent=2) + '\n')
        return self.json_path.read_bytes()

    def files(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}

    def parsed(self):
        if tomllib is None:
            self.skipTest('TOML semantic roundtrip requires Python 3.11+; CLI safety tests also run on 3.10')
        return tomllib.loads(self.config.read_text())

    def test_normal_install_explains_description_only_source_without_exposing_values(self):
        self.config.write_text('[hooks]\n')
        description = 'private description should never appear in install diagnostics'
        self.write_json({'description': description})
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.json_path.read_text()), {'description': description})
        self.assertIn('0 event handlers', result.stdout)
        self.assertIn('description', result.stdout)
        self.assertIn('wokintosh-agent install-hooks --provider codex --consolidate-sources', result.stdout)
        self.assertNotIn(description, result.stdout + result.stderr)

    def test_normal_install_reports_remaining_handler_count_and_metadata_keys(self):
        self.config.write_text('[hooks]\n')
        existing = {'custom': {'secret': 'private metadata value'}, 'hooks': {
            'state': {'private-trust-key': 'private trust value'},
            'Stop': [{'matcher': 'private matcher', 'hooks': [
                {'type': 'command', 'command': 'private command value'},
                {'type': 'mcp_tool', 'server': 'private server', 'tool': 'private tool'}]}]}}
        original = self.write_json(existing)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.json_path.read_bytes(), original)
        self.assertIn('2 event handlers', result.stdout)
        self.assertIn('custom', result.stdout)
        self.assertIn('hooks.state', result.stdout)
        for value in ('private metadata value', 'private trust value', 'private command value', 'private matcher', 'private server'):
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_normal_install_retains_reserved_state_metadata_even_when_it_is_an_array(self):
        self.config.write_text('[hooks]\n')
        self.write_json({'hooks': {'state': []}})
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.json_path.exists())
        self.assertEqual(json.loads(self.json_path.read_text()), {'hooks': {'state': []}})
        self.assertIn('0 event handlers', result.stdout)
        self.assertIn('hooks.state', result.stdout)

    def test_explicit_consolidation_archives_custom_description_then_removes_json(self):
        original_toml = '# keep original text\n[hooks]\n[hooks.state."trusted"]\ntrusted_hash = "keep-exact"\n'
        self.config.write_text(original_toml)
        original_json = self.write_json({'description': 'Custom description to archive, not activate'})
        result = self.install('--consolidate-sources')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.json_path.exists())
        self.assertTrue(self.config.read_text().startswith(original_toml))
        self.assertEqual([p.read_bytes() for p in self.config.parent.glob('hooks.json.wokintosh-backup-*')], [original_json])
        self.assertIn('description', result.stdout)
        self.assertIn('backup', result.stdout.lower())
        self.assertNotIn('Custom description to archive', self.config.read_text())
        installed = self.files()
        self.assertEqual(self.install('--consolidate-sources').returncode, 0)
        self.assertEqual(self.files(), installed, 'repeat consolidation must not change files or create extra backups')

    def test_consolidation_preserves_foreign_groups_all_handlers_and_nested_metadata(self):
        original_toml = ('# retain comments and trust\nmodel = "fixture"\n[[hooks.Stop]]\nmatcher = "existing"\n'
                         '[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "old observer # wokintosh-observer"\n'
                         'timeout = 3\n[hooks.state."trusted"]\ntrusted_hash = "keep-exact"\n')
        self.config.write_text(original_toml)
        foreign = {'matcher': 'Bash|Write', 'groupExtra': {'flag': True, 'values': [1, 2.5, 'line\nquote"']},
                   'hooks': [{'type': 'command', 'command': 'foreign --secret=keep', 'async': True,
                              'extra': {'nested': [{'enabled': False}]}},
                             {'type': 'mcp_tool', 'server': 'fixture', 'tool': 'record',
                              'arguments': {'text': 'hello', 'count': 4}, 'hooks': []}]}
        original_json = self.write_json({'description': 'Foreign hook collection', 'hooks': {
            'Stop': [foreign], 'Custom.Event': [{'matcher': '*', 'hooks': []}]}})
        result = self.install('--consolidate-sources')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.config.read_text()
        self.assertIn('# retain comments and trust', installed)
        self.assertIn('[hooks.state."trusted"]\ntrusted_hash = "keep-exact"', installed)
        self.assertFalse(self.json_path.exists())
        self.assertEqual([p.read_bytes() for p in self.config.parent.glob('hooks.json.wokintosh-backup-*')], [original_json])
        parsed = self.parsed()
        self.assertEqual(parsed['hooks']['Stop'][1], foreign)
        self.assertEqual(parsed['hooks']['Custom.Event'], [{'matcher': '*', 'hooks': []}])
        self.assertEqual(sum(agent.observer_handler(h) for g in parsed['hooks']['Stop'] for h in g.get('hooks', [])), 1,
                         'foreign JSON groups must not add a second default observer for an event already observed in TOML')
        before = self.files()
        self.assertEqual(self.install('--consolidate-sources').returncode, 0)
        self.assertEqual(self.files(), before)

    def test_consolidation_refuses_unknown_active_metadata_before_any_write(self):
        self.config.write_text('[hooks]\n')
        for metadata in ({'custom': {'secret': 'do not print me'}}, {'hooks': {'state': {'trusted_hash': 'do not print me'}}},
                         {'hooks': {'state': []}}):
            with self.subTest(metadata=metadata):
                self.write_json(metadata)
                before = self.files()
                result = self.install('--consolidate-sources')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('metadata', result.stderr.lower())
                self.assertIn('settings were not changed', result.stderr)
                self.assertNotIn('do not print me', result.stdout + result.stderr)
                self.assertEqual(self.files(), before)

    def test_consolidation_refuses_toml_table_collisions_before_any_write(self):
        for original_toml in ('[[hooks]]\n', '[hooks.Stop]\n', '[hooks.Stop.hooks]\n', '[hooks.Custom]\nkeep = true\n',
                              '[hooks]\nCustom = { keep = true }\n', '[hooks]\nCustom.keep = true\n',
                              '[hooks]\n"Custom"."keep" = true\n'):
            with self.subTest(original_toml=original_toml):
                self.config.write_text(original_toml)
                self.write_json({'hooks': {'Custom': [{'hooks': [{'type': 'command', 'command': 'foreign'}]}]}})
                before = self.files()
                result = self.install('--consolidate-sources')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('TOML', result.stderr)
                self.assertIn('settings were not changed', result.stderr)
                self.assertEqual(self.files(), before)

    def test_consolidated_distinct_own_handler_metadata_remains_idempotent(self):
        self.config.write_text('[hooks]\n')
        first = {'type': 'command', 'command': 'old # wokintosh-observer', 'timeout': 7, 'extra': {'preserve': True}}
        second = {**first, 'timeout': 12, 'async': True}
        self.write_json({'hooks': {'Stop': [{'matcher': 'Write', 'hooks': [first, second]}]}})
        result = self.install('--consolidate-sources')
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.files()
        result = self.install('--consolidate-sources')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.files(), before)
        group = self.parsed()['hooks']['Stop'][0]
        self.assertEqual([h['timeout'] for h in group['hooks']], [7, 12])
        self.assertEqual([h['extra'] for h in group['hooks']], [{'preserve': True}, {'preserve': True}])

    def test_old_equivalent_toml_observers_deduplicate_within_their_group(self):
        self.config.write_text('[[hooks.Stop]]\nmatcher = "Write"\n[[hooks.Stop.hooks]]\ntype = "command"\n'
                               'command = "old # wokintosh-observer"\ntimeout = 3\n'
                               '[[hooks.Stop.hooks]]\n# retain duplicate comment\ntype = "command"\n'
                               'command = "newer # wokintosh-observer"\ntimeout = 3\n')
        result = self.install('--consolidate-sources')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('# retain duplicate comment', self.config.read_text())
        self.assertEqual(len(self.parsed()['hooks']['Stop'][0]['hooks']), 1)
        before = self.files()
        self.assertEqual(self.install('--consolidate-sources').returncode, 0)
        self.assertEqual(self.files(), before)

    def test_consolidation_refuses_unrepresentable_values_before_any_write(self):
        self.config.write_text('[hooks]\n')
        for value in (None, float('nan'), float('inf'), -float('inf'), 2 ** 64, '\ud800'):
            with self.subTest(value=repr(value)):
                self.write_json({'hooks': {'Stop': [{'hooks': [{'type': 'mcp_tool', 'extra': {'nested': value}}]}]}})
                before = self.files()
                result = self.install('--consolidate-sources')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('TOML', result.stderr)
                self.assertIn('settings were not changed', result.stderr)
                self.assertEqual(self.files(), before)

    def test_consolidation_dry_run_lists_every_affected_path_without_writes(self):
        self.config.write_text('[hooks]\n')
        self.write_json({'description': 'archived description', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'foreign'}]}]}})
        before = self.files()
        result = self.install('--consolidate-sources', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.files(), before)
        self.assertIn(str(self.config), result.stderr)
        self.assertIn(str(self.json_path), result.stderr)
        self.assertIn('backup', result.stderr.lower())
        self.assertIn('remove', result.stderr.lower())
        self.assertIn('description', result.stderr)

    def test_json_is_removed_only_after_toml_replacement_and_all_backups(self):
        self.config.write_text('[hooks]\n')
        original_json = self.write_json({'description': 'Archive me'})
        original_toml = self.config.read_bytes()
        def replace_failure(source, target):
            self.assertEqual(Path(target), self.config)
            self.assertEqual(self.json_path.read_bytes(), original_json)
            self.assertEqual([p.read_bytes() for p in self.config.parent.glob('hooks.json.wokintosh-backup-*')], [original_json])
            self.assertEqual([p.read_bytes() for p in self.config.parent.glob('config.toml.wokintosh-backup-*')], [original_toml])
            raise OSError('synthetic replacement failure')
        with patch.object(agent.os, 'replace', side_effect=replace_failure):
            with self.assertRaisesRegex(OSError, 'synthetic replacement failure'):
                agent.install_hooks('codex', self.root, self.root / 'state', 'fixture hook', consolidate_sources=True)
        self.assertEqual(self.config.read_bytes(), original_toml)
        self.assertEqual(self.json_path.read_bytes(), original_json)

    def test_opt_in_does_not_create_toml_without_existing_hook_tables(self):
        self.config.write_text('model = "fixture"\n')
        original_toml = self.config.read_bytes()
        self.write_json({'description': 'keep active in JSON', 'custom': {'preserve': True}})
        result = self.install('--consolidate-sources')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_bytes(), original_toml)
        installed = json.loads(self.json_path.read_text())
        self.assertEqual(installed['custom'], {'preserve': True})
        self.assertEqual(installed['description'], 'keep active in JSON')
        before = self.files()
        self.assertEqual(self.install('--consolidate-sources').returncode, 0)
        self.assertEqual(self.files(), before)

    def test_claude_rejects_codex_consolidation_flag_without_writes(self):
        before = self.files()
        result = self.install('--consolidate-sources', provider='claude')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Codex', result.stderr)
        self.assertEqual(self.files(), before)

    def test_previous_versions_migrate_in_json_toml_and_mixed_forms(self):
        versions = [('/legacy hook # wokintosh-observer', None, None),
                    ('/legacy hook # Wokintosh status observer; wokintosh-observer', 'Wokintosh status observer', 'Wokintosh status observer hooks'),
                    ('/legacy hook # Wokintosh status observer; wokintosh-observer', 'Wokintosh · Done', 'Wokintosh status observer hooks')]
        for version, (command, label, description) in enumerate(versions, 1):
            for source in ('json', 'toml', 'mixed'):
                with self.subTest(version=version, source=source), tempfile.TemporaryDirectory() as directory:
                    self.root = Path(directory)
                    self.config = self.root / '.codex/config.toml'
                    self.json_path = self.config.with_name('hooks.json')
                    self.config.parent.mkdir()
                    state = self.root / 'state/hooks/existing.json'
                    state.parent.mkdir(parents=True)
                    state.write_text('{"fixture": "collector state preserved"}\n')
                    own = {'type': 'command', 'command': command, 'timeout': 7, 'extra': {'preserve': True}}
                    if label:
                        own['statusMessage'] = label
                    if source in ('json', 'mixed'):
                        older_command, older_label, _ = versions[(version - 2) % len(versions)]
                        older = {**copy.deepcopy(own), 'command': older_command}
                        if older_label:
                            older['statusMessage'] = older_label
                        else:
                            older.pop('statusMessage', None)
                        payload = {'hooks': {'Stop': [{'matcher': 'Write', 'groupExtra': 42, 'hooks': [own, older]}]}}
                        if description:
                            payload['description'] = description
                        self.write_json(payload)
                    if source in ('toml', 'mixed'):
                        toml_command, toml_label, _ = versions[(version - 2) % len(versions)] if source == 'mixed' else (command, label, description)
                        status = 'statusMessage = ' + json.dumps(toml_label) + '\n' if toml_label else ''
                        self.config.write_text('[[hooks.Stop]]\nmatcher = "Bash"\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = ' + json.dumps(toml_command) + '\n' + status + 'timeout = 11\n[hooks.state."previous"]\ntrusted_hash = "preserve"\n')
                    else:
                        self.config.write_text('model = "fixture"\n')
                    result = self.install('--consolidate-sources')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(state.read_text(), '{"fixture": "collector state preserved"}\n')
                    if source == 'json':
                        groups = json.loads(self.json_path.read_text())['hooks']['Stop']
                    else:
                        self.assertFalse(self.json_path.exists())
                        parsed = self.parsed()
                        self.assertEqual(parsed['hooks']['state']['previous']['trusted_hash'], 'preserve')
                        groups = parsed['hooks']['Stop']
                    self.assertEqual([g.get('matcher') for g in groups], ['Bash', 'Write'] if source == 'mixed' else ['Bash'] if source == 'toml' else ['Write'])
                    self.assertTrue(all(len(g['hooks']) == 1 for g in groups))
                    if source != 'toml':
                        self.assertEqual(groups[-1]['groupExtra'], 42)
                        self.assertEqual(groups[-1]['hooks'][0]['extra'], {'preserve': True})
                    self.assertTrue(all(g['hooks'][0]['statusMessage'] == 'Wokintosh · Done' for g in groups))
                    before = self.files()
                    self.assertEqual(self.install('--consolidate-sources').returncode, 0)
                    self.assertEqual(self.files(), before)

    def test_consolidated_observer_still_returns_neutral_json(self):
        self.config.write_text('[hooks]\n')
        self.write_json({'description': 'Archive me'})
        self.assertEqual(self.install('--consolidate-sources').returncode, 0)
        handler = self.parsed()['hooks']['Stop'][0]['hooks'][0]
        result = subprocess.run(handler['command'], shell=True, input=json.dumps({'hook_event_name': 'Stop', 'session_id': 'fixture', 'private': 'do not retain'}),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '{}')
        observations = list((self.root / 'state/hooks').glob('*.json'))
        self.assertEqual(len(observations), 1)
        self.assertNotIn('do not retain', observations[0].read_text())

    def test_undecodable_toml_unicode_keys_refuse_before_writes(self):
        fixtures = [
            '[hooks]\n"Custom\\U0000002EEvent".keep = true\n',
            '[hooks]\n"Custom\\U0000002EEvent" = { keep = true }\n',
            '[hooks."Custom\\U0000002EEvent"]\nkeep = true\n',
            '["h\\U0000006foks"."Custom.Event"]\nkeep = true\n',
        ]
        for source in fixtures:
            with self.subTest(source=source):
                for p in list(self.config.parent.iterdir()): p.unlink()
                self.config.write_text(source)
                if tomllib is not None: tomllib.loads(source)
                self.write_json({'hooks': {'Custom.Event': [{'hooks': [{'type': 'command', 'command': 'foreign'}]}]}})
                before=self.files()
                result=self.install('--consolidate-sources')
                self.assertNotEqual(result.returncode,0)
                self.assertIn('settings were not changed',result.stderr)
                self.assertEqual(self.files(),before)


if __name__ == '__main__':
    unittest.main()
