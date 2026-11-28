"""Metadata-only provider adapters, isolated from real installations and sessions."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('additional_agent', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 11, 24, 20, tzinfo=timezone.utc)
IDENTITY = 'ec33ebf9-0cba-4100-8142-c61503f6c587'


class AdditionalProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.state = self.home / 'state'
        self.event_counter = 0

    def tearDown(self):
        self.temp.cleanup()

    def antigravity(self, name='PreInvocation', flavor='antigravity', **extra):
        return dict(conversationId=IDENTITY, workspacePaths=['/workspace/project'],
                    transcriptPath=str(self.home / '.gemini' / flavor / 'brain' / IDENTITY / '.system_generated/logs/transcript.jsonl'),
                    hook_event_name=name, lastUserInput='PRIVATE PROMPT', **extra)

    def opencode(self, name='session.execution.started', identity='ses_example', **data):
        self.event_counter += 1
        return dict(id=f'evt_fixture_{self.event_counter}', type=name, created=int(NOW.timestamp() * 1000),
                    location={'directory': '/workspace/project'}, data=dict(sessionID=identity, **data))

    def sessions(self, now=NOW):
        return agent.make_snapshot(self.home, self.state, now)['sessions']

    def one(self):
        rows = self.sessions()
        self.assertEqual(len(rows), 1, rows)
        return rows[0]

    def ingest(self, provider, event, now=NOW):
        agent.ingest_hook(provider, event, self.home, self.state, now)

    def cli(self, *args, payload=None):
        return subprocess.run([sys.executable, agent.__file__, '--home', str(self.home),
                               '--state-dir', str(self.state), *args], input=json.dumps(payload or {}),
                              capture_output=True, text=True, timeout=10)

    def test_antigravity_app_and_cli_share_identity_without_ide(self):
        for flavor in ('antigravity', 'antigravity-cli'):
            self.ingest('antigravity', self.antigravity(flavor=flavor))
        rows = self.sessions()
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['provider'], rows[0]['id'], rows[0]['project'], rows[0]['state']),
                         ('antigravity', IDENTITY, 'project', 'working'))
        self.assertNotIn('PRIVATE PROMPT', json.dumps(rows))
        self.ingest('antigravity', self.antigravity('Stop', 'antigravity-ide', terminationReason='model_stop', fullyIdle=True))
        self.assertEqual(self.one()['state'], 'working')

    def test_antigravity_stop_needs_explicit_success_and_full_idle(self):
        for reason, idle, want in [('model_stop', True, 'finished'), ('error', True, 'needsAttention'),
                                   ('max_steps_exceeded', True, 'needsAttention'), ('model_stop', False, 'unknown'),
                                   ('model_stop', None, 'unknown'), ('unknown', True, 'unknown')]:
            with self.subTest(reason=reason, idle=idle):
                self.ingest('antigravity', self.antigravity('Stop', terminationReason=reason, fullyIdle=idle))
                self.assertEqual(self.one()['state'], want)

    def test_post_invocation_and_tool_results_never_imply_turn_completion(self):
        for name in ('PostInvocation', 'PostToolUse', 'PreToolUse'):
            self.ingest('antigravity', self.antigravity(name, toolCall={'name': 'run_command', 'args': {'CommandLine': 'PRIVATE COMMAND'}},
                                                        toolResponse='PRIVATE OUTPUT'))
            self.assertEqual(self.one()['state'], 'working')
        self.assertNotIn('PRIVATE', ''.join(p.read_text() for p in self.state.rglob('*.json')))

    def test_antigravity_missing_invalid_and_symlinked_roots_are_ignored(self):
        events = [self.antigravity(flavor='antigravity-ide'), self.antigravity(flavor='other')]
        event = self.antigravity(); event.pop('transcriptPath'); events.append(event)
        event = self.antigravity(); event['conversationId'] = '../escape'; events.append(event)
        outside = self.home / 'unrelated'; outside.mkdir()
        root = self.home / '.gemini/antigravity'; root.parent.mkdir(parents=True)
        root.symlink_to(outside, target_is_directory=True)
        events.append(self.antigravity())
        for event in events:
            self.ingest('antigravity', event)
        self.assertEqual(self.sessions(), [])
        self.assertEqual(list(outside.iterdir()), [])

    def test_antigravity_discovery_observes_bounded_metadata_and_never_transcript_bodies(self):
        event = self.antigravity()
        path = Path(event['transcriptPath']); path.parent.mkdir(parents=True)
        path.write_text('{"arbitrary":"PRIVATE BODY", "state":"completed"}\n')
        os.utime(path, (NOW.timestamp(), NOW.timestamp()))
        rows = self.sessions()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['state'], 'unknown')
        self.assertNotIn('PRIVATE', json.dumps(rows))
        self.ingest('antigravity', event)
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(self.one()['state'], 'working')

    def test_antigravity_transcript_mtime_does_not_override_real_hook_lifecycle(self):
        event = self.antigravity()
        path = Path(event['transcriptPath']); path.parent.mkdir(parents=True)
        path.write_text('PRIVATE BODY')
        os.utime(path, ((NOW + timedelta(seconds=1)).timestamp(), (NOW + timedelta(seconds=1)).timestamp()))
        self.ingest('antigravity', event)
        rows = self.sessions(NOW + timedelta(seconds=2))
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['state'], rows[0]['project']), ('working', 'project'))

    def test_deep_malformed_hook_input_still_returns_neutral_policy_output(self):
        result = subprocess.run([sys.executable, agent.__file__, '--home', str(self.home),
                                 '--state-dir', str(self.state), 'hook', '--provider', 'antigravity',
                                 '--event', 'PreToolUse'], input='[' * 10000 + '0' + ']' * 10000,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'decision': 'allow'})

    def test_deep_optional_provider_evidence_cannot_break_healthy_snapshot(self):
        self.ingest('opencode', self.opencode())
        (self.state / 'provider-links.json').write_text('[' * 10000 + '0' + ']' * 10000)
        try:
            rows = self.sessions()
        except RecursionError:
            self.fail('Malformed optional provider metadata broke the snapshot')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['state'], 'working')

    def test_antigravity_unavailable_write_and_malformed_input_still_preserve_policy(self):
        self.state.write_text('not a directory')
        result = self.cli('hook', '--provider', 'antigravity', '--event', 'PreToolUse', payload=self.antigravity())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'decision': 'allow'})
        self.assertNotIn('PRIVATE', result.stderr)

    def test_optional_bad_url_values_and_encoded_controls_do_not_break_snapshot(self):
        self.ingest('opencode', self.opencode())
        for value in ('https://example.com/%0Asecret', 'https://example.com/auth/connect/PRIVATE',
                      'https://example.com/?api_key=PRIVATE', ['https://example.com'], {'url': 'PRIVATE'}):
            agent.atomic_json(self.state / 'provider-links.json', {'version': 1, 'sessions': [
                {'provider': 'opencode', 'id': 'ses_example', 'iOS': value}]})
            self.assertNotIn('openURLs', self.one())

    def test_additional_provider_stale_signals_become_unknown(self):
        self.ingest('antigravity', self.antigravity('Stop', terminationReason='model_stop', fullyIdle=True))
        self.ingest('opencode', self.opencode('permission.asked', id='perm_1', action='write', resources=['PRIVATE']))
        rows = self.sessions(NOW + timedelta(hours=2))
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row['state'] == 'unknown' for row in rows))

    def test_opencode_lifecycle_deduplicates_app_cli_and_does_not_export_bodies(self):
        created = self.opencode('session.created', title='Review', parentID='ses_parent', metadata={'private': 'PRIVATE'})
        self.ingest('opencode', created)
        for _ in range(2):
            self.ingest('opencode', self.opencode())
        row = self.one()
        self.assertEqual((row['title'], row['state'], row['parentId'], row['isHelper']), ('Review', 'working', 'ses_parent', True))
        event = self.opencode('session.execution.succeeded'); event['created'] += 1
        self.ingest('opencode', event)
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(self.one()['state'], 'finished')
        self.assertNotIn('PRIVATE', ''.join(p.read_text() for p in self.state.rglob('*.json')))

    def test_opencode_idle_compatibility_event_cannot_erase_completion_or_error(self):
        for name, want in [('session.execution.succeeded', 'finished'), ('session.execution.failed', 'needsAttention')]:
            self.ingest('opencode', self.opencode(name))
            idle = self.opencode('session.idle'); idle['created'] += 1
            self.ingest('opencode', idle)
            self.assertEqual(self.one()['state'], want)

    def test_antigravity_reinstall_preserves_explicit_disabled_observer(self):
        self.assertEqual(self.cli('install-hooks', '--provider', 'antigravity').returncode, 0)
        path = self.home / '.gemini/config/hooks.json'
        config = json.loads(path.read_text()); config['wokintosh-observer']['enabled'] = False
        path.write_text(json.dumps(config))
        result = self.cli('install-hooks', '--provider', 'antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(path.read_text())['wokintosh-observer']['enabled'])

    def test_opencode_fifo_plugin_target_is_rejected_without_blocking_or_writes(self):
        plugin = self.home / '.local/share/wokintosh/opencode-observer'; plugin.mkdir(parents=True)
        os.mkfifo(plugin / 'index.js')
        try:
            result = subprocess.run([sys.executable, agent.__file__, '--home', str(self.home),
                                     '--state-dir', str(self.state), 'install-hooks', '--provider', 'opencode'],
                                    capture_output=True, text=True, timeout=2)
        except subprocess.TimeoutExpired:
            self.fail('Provider installation blocked while reading a FIFO')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((plugin / 'package.json').exists())
        self.assertFalse((self.home / '.config/opencode/opencode.json').exists())

    def test_opencode_foreign_package_is_preserved(self):
        plugin = self.home / '.local/share/wokintosh/opencode-observer'; plugin.mkdir(parents=True)
        package = plugin / 'package.json'; package.write_text('{"name":"foreign-package"}')
        result = self.cli('install-hooks', '--provider', 'opencode')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(package.read_text(), '{"name":"foreign-package"}')
        self.assertFalse((plugin / 'index.js').exists())

    def test_opencode_failure_interruption_idle_and_tool_success_are_not_done(self):
        for name, want in [('session.execution.failed', 'needsAttention'), ('session.execution.interrupted', 'idle'),
                           ('session.idle', 'idle'), ('session.tool.success', 'working')]:
            self.ingest('opencode', self.opencode(name, error={'message': 'PRIVATE ERROR'}))
            self.assertEqual(self.one()['state'], want)

    def test_opencode_permission_requests_require_matching_replies(self):
        for request in ('perm_a', 'perm_b'):
            self.ingest('opencode', self.opencode('permission.asked', id=request, action='write', resources=['PRIVATE']))
        self.ingest('opencode', self.opencode('permission.replied', requestID='unrelated', reply='once'))
        self.assertEqual(self.one()['state'], 'needsAttention')
        self.ingest('opencode', self.opencode('permission.replied', requestID='perm_a', reply='once'))
        self.assertEqual(self.one()['state'], 'needsAttention')
        self.ingest('opencode', self.opencode('permission.replied', requestID='perm_b', reply='once'))
        self.assertEqual(self.one()['state'], 'unknown')
        self.ingest('opencode', self.opencode())
        self.assertEqual(self.one()['state'], 'working')

    def test_opencode_out_of_order_and_inventory_cannot_erase_lifecycle(self):
        self.ingest('opencode', self.opencode('session.execution.succeeded'))
        earlier = self.opencode(); earlier['created'] -= 1000
        self.ingest('opencode', earlier)
        self.ingest('opencode', self.opencode('wokintosh.session.discovered', title='Recovered metadata', parentID='ses_parent'))
        row = self.one()
        self.assertEqual((row['state'], row['title'], row['isHelper']), ('finished', 'Recovered metadata', True))

    def test_opencode_inventory_without_activity_is_unknown_despite_outcome(self):
        self.ingest('opencode', self.opencode('wokintosh.session.discovered', title='Existing session', outcome='succeeded'))
        self.assertEqual(self.one()['state'], 'unknown')

    def test_opencode_malformed_future_and_unknown_events_do_not_invent_sessions(self):
        events = [self.opencode('unknown.event'), self.opencode(identity='../escape'), self.opencode()]
        events[-1]['created'] = int((NOW + timedelta(hours=1)).timestamp() * 1000)
        events += [dict(type='session.execution.succeeded', data={'sessionID': 'ses_missing_time'}), self.opencode(identity='')]
        for event in events:
            self.ingest('opencode', event)
        self.assertEqual(self.sessions(), [])

    def test_unverified_opencode_background_work_keeps_completion_unknown(self):
        self.ingest('opencode', self.opencode('session.shell.started', shellID='shell_1'))
        event = self.opencode('session.execution.succeeded'); event['created'] += 1
        self.ingest('opencode', event)
        self.assertEqual(self.one()['state'], 'unknown')
        self.assertTrue(self.one()['background']['incomplete'])

    def test_new_helper_idle_is_not_fabricated_background_completion(self):
        self.ingest('opencode', self.opencode(identity='ses_parent'))
        self.ingest('opencode', self.opencode('session.created', parentID='ses_parent'))
        self.ingest('opencode', self.opencode('session.execution.interrupted'))
        rows = self.sessions()
        self.assertEqual(len(rows), 2, rows)
        parent = next(row for row in rows if row['id'] == 'ses_parent')
        self.assertEqual(parent['background']['tasks'][0]['status'], 'unknown')

    def test_links_require_bounded_explicit_config_and_support_nullable_platforms(self):
        self.ingest('antigravity', self.antigravity())
        self.assertNotIn('openURLs', self.one())
        link = 'https://antigravity.google.com/r/captured-instance?p=c%2F' + IDENTITY
        agent.atomic_json(self.state / 'provider-links.json', {'version': 1, 'sessions': [
            {'provider': 'antigravity', 'id': IDENTITY, 'iOS': link}]})
        row = self.one()
        self.assertEqual(row['openURLs'], {'iOS': {'primary': link}})

    def test_bad_and_body_urls_never_reach_protocol(self):
        for url in ('javascript:alert(1)', 'https://user:secret@example.com/session', 'https://example.com/\nsecret',
                    'https://example.com/?token=PRIVATE', 'https://example.com/#access_token=PRIVATE'):
            self.ingest('opencode', self.opencode(openURLs={'iOS': {'primary': url}}, url=url))
            agent.atomic_json(self.state / 'provider-links.json', {'version': 1, 'sessions': [
                {'provider': 'opencode', 'id': 'ses_example', 'iOS': url}]})
            self.assertNotIn('openURLs', self.one())

    def test_documented_antigravity_remote_url_survives_repeated_snapshots(self):
        self.ingest('antigravity', self.antigravity())
        url = 'https://antigravity.google.com/r/captured-instance?p=c%2F' + IDENTITY
        agent.atomic_json(self.state / 'provider-links.json', {'version': 1, 'sessions': [
            {'provider': 'antigravity', 'id': IDENTITY, 'macOS': url, 'iOS': url}]})
        for _ in range(2):
            self.assertEqual(self.one().get('openURLs'), {'macOS': {'primary': url}, 'iOS': {'primary': url}})

    def test_opencode_jsonc_install_retains_comments_permissions_and_trailing_commas(self):
        path = self.home / '.config/opencode/opencode.jsonc'; path.parent.mkdir(parents=True)
        original = '{\n// keep this policy\n"plugins": ["foreign", /* keep plugin */],\n"permissions": [{"action":"shell", "effect":"ask",}],\n}\n'
        path.write_text(original)
        result = self.cli('install-hooks', '--provider', 'opencode')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = path.read_text()
        self.assertIn('// keep this policy', installed)
        self.assertIn('/* keep plugin */', installed)
        self.assertIn('"permissions": [{"action":"shell", "effect":"ask",}]', installed)
        self.assertFalse(path.with_suffix('.json').exists())
        before = installed
        self.assertEqual(self.cli('install-hooks', '--provider', 'opencode').returncode, 0)
        self.assertEqual(path.read_text(), before)
        self.assertEqual([p.read_text() for p in path.parent.glob('*.wokintosh-backup-*')], [original])

    def test_opencode_jsonc_without_plugins_gets_valid_array_without_policy_changes(self):
        path = self.home / '.config/opencode/opencode.jsonc'; path.parent.mkdir(parents=True)
        original = '{/* policy */"permissions": [], "literal": ",}//url",}'
        path.write_text(original)
        result = self.cli('install-hooks', '--provider', 'opencode')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"literal": ",}//url"', path.read_text())
        self.assertIn('"plugins"', path.read_text())

    def test_oversized_fifo_and_symlinked_provider_evidence_is_bounded_and_ignored(self):
        self.ingest('opencode', self.opencode())
        path = self.state / 'provider-links.json'
        path.write_bytes(b'x' * (256 * 1024 + 1))
        self.assertNotIn('openURLs', self.one())
        path.unlink(); os.mkfifo(path)
        self.assertNotIn('openURLs', self.one())
        path.unlink(); outside = self.home / 'outside-links.json'
        outside.write_text('{"version":1,"sessions":[]}'); path.symlink_to(outside)
        self.assertNotIn('openURLs', self.one())

    def test_generated_opencode_plugin_executes_metadata_bridge_without_mutating_provider(self):
        if shutil.which('node') is None:
            self.skipTest('Node is needed only for generated JavaScript bridge verification')
        result = self.cli('install-hooks', '--provider', 'opencode')
        self.assertEqual(result.returncode, 0, result.stderr)
        plugin = self.home / '.local/share/wokintosh/opencode-observer'
        sdk = plugin / 'node_modules/@opencode/plugin'; sdk.mkdir(parents=True)
        (sdk / 'package.json').write_text('{"name":"@opencode/plugin","type":"module","exports":"./index.js"}')
        # Plugin.define is the SDK's definition boundary; the real generated bridge and Python collector run.
        (sdk / 'index.js').write_text('export const Plugin = { define: value => value };')
        events = [self.opencode('session.created', title='Bridge fixture'),
                  self.opencode('permission.asked', id='perm_a', action='shell', resources=['PRIVATE RESOURCE'], message='PRIVATE MESSAGE'),
                  self.opencode('permission.replied', requestID='perm_a', reply='once'),
                  self.opencode('session.execution.succeeded')]
        for index, event in enumerate(events):
            event['created'] += index
        harness = self.home / 'verify-plugin.mjs'
        harness.write_text("""import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
const plugin = (await import(pathToFileURL(process.argv[2]))).default;
const events = JSON.parse(process.argv[3]);
const original = JSON.stringify(events);
let resolveDone;
const done = new Promise(resolve => { resolveDone = resolve; });
let signal;
const cleanup = await plugin.setup({
  location: { directory: '/workspace/project' },
  session: { async list(input) {
    assert.deepEqual(input, { directory: '/workspace/project', limit: 20 });
    // Make bootstrap slower than the old fixed cleanup delay on purpose.
    await new Promise(resolve => setTimeout(resolve, 500));
    return { data: [{ id: 'ses_inventory', title: 'Inventory', outcome: 'succeeded',
      location: {directory: '/workspace/project'}, time: { updated: events[0].created } }], cursor: {} };
  } },
  event: { async *subscribe(input) {
    assert(input.types.includes('permission.asked'));
    assert(input.types.includes('session.execution.succeeded'));
    signal = input.signal;
    try { for (const event of events) yield event; } finally { resolveDone(); }
  } },
  tool: { hook() { throw new Error('must not intercept tools'); } },
  permission: { hook() { throw new Error('must not change approvals'); } },
});
await done;
// Bootstrap runs independently of the event stream. Keep the provider alive
// until its real bridge write arrives, rather than racing a fixed sleep/cleanup.
async function inventoryArrived() {
  try {
    const directory = join(process.argv[4], 'hooks');
    const names = (await readdir(directory)).filter(name => name.endsWith('.json'));
    const rows = await Promise.all(names.map(async name => {
      try { return JSON.parse(await readFile(join(directory, name), 'utf8')); } catch { return null; }
    }));
    return rows.some(row => row?.id === 'ses_inventory');
  } catch { return false; }
}
const deadline = Date.now() + 5000;
while (!(await inventoryArrived()) && Date.now() < deadline) {
  await new Promise(resolve => setTimeout(resolve, 20));
}
assert(await inventoryArrived(), 'The bootstrap metadata bridge did not finish');
assert.equal(JSON.stringify(events), original);
cleanup();
assert.equal(signal.aborted, true);
""")
        run = subprocess.run(['node', str(harness), str(plugin / 'index.js'), json.dumps(events), str(self.state)],
                             capture_output=True, text=True, timeout=15)
        self.assertEqual(run.returncode, 0, run.stderr)
        rows = {row['id']: row for row in self.sessions()}
        self.assertEqual(rows['ses_example']['state'], 'finished')
        self.assertEqual(rows['ses_inventory']['state'], 'unknown')
        self.assertNotIn('PRIVATE', ''.join(p.read_text() for p in self.state.rglob('*.json')))

    def test_antigravity_install_preserves_named_hooks_and_backups_is_idempotent(self):
        path = self.home / '.gemini/config/hooks.json'; path.parent.mkdir(parents=True)
        original = {'existing-safety': {'PreToolUse': [{'matcher': '*', 'hooks': [{'command': 'retain safety'}]}]}}
        path.write_text(json.dumps(original))
        before = path.read_bytes()
        result = self.cli('install-hooks', '--provider', 'antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(path.read_text())
        self.assertEqual(config['existing-safety'], original['existing-safety'])
        entry = config['wokintosh-observer']
        self.assertEqual(set(entry), {'SessionStart', 'PreInvocation', 'PostInvocation', 'PreToolUse', 'PostToolUse', 'Stop'})
        for name, handlers in entry.items():
            handler = handlers[0]['hooks'][0] if name in ('PreToolUse', 'PostToolUse') else handlers[0]
            self.assertIn('--event ' + name, handler['command'])
        self.assertEqual([p.read_bytes() for p in path.parent.glob('hooks.json.wokintosh-backup-*')], [before])
        files = {p: p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        self.assertEqual(self.cli('install-hooks', '--provider', 'antigravity').returncode, 0)
        self.assertEqual(files, {p: p.read_bytes() for p in self.home.rglob('*') if p.is_file()})

    def test_antigravity_pretooluse_output_delegates_default_policy_even_for_ignored_ide(self):
        for flavor in ('antigravity', 'antigravity-ide'):
            result = self.cli('hook', '--provider', 'antigravity', '--event', 'PreToolUse', payload=self.antigravity(flavor=flavor))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {'decision': 'allow'})
        result = self.cli('hook', '--provider', 'antigravity', '--event', 'Stop', payload=self.antigravity('Stop', fullyIdle=True, terminationReason='model_stop'))
        self.assertEqual(json.loads(result.stdout), {'decision': 'allow'})

    def test_opencode_install_preserves_foreign_plugins_and_dry_run_has_no_writes(self):
        path = self.home / '.config/opencode/opencode.json'; path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'model': 'keep', 'plugins': ['foreign']}))
        before = path.read_bytes()
        dry = self.cli('install-hooks', '--provider', 'opencode', '--dry-run')
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.state.glob('*')), [])
        result = self.cli('install-hooks', '--provider', 'opencode')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(path.read_text())
        self.assertEqual(config['plugins'][0], 'foreign')
        self.assertEqual(config['model'], 'keep')
        plugin = Path(config['plugins'][1]); self.assertTrue((plugin / 'index.js').is_file())
        self.assertEqual([p.read_bytes() for p in path.parent.glob('opencode.json.wokintosh-backup-*')], [before])
        files = {p: p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        self.assertEqual(self.cli('install-hooks', '--provider', 'opencode').returncode, 0)
        self.assertEqual(files, {p: p.read_bytes() for p in self.home.rglob('*') if p.is_file()})

    def test_install_refuses_symlinks_foreign_owned_name_and_malformed_config_without_writes(self):
        path = self.home / '.gemini/config/hooks.json'; path.parent.mkdir(parents=True)
        for value in ('{', json.dumps({'wokintosh-observer': {'Stop': [{'command': 'foreign command'}]}})):
            path.write_text(value)
            result = self.cli('install-hooks', '--provider', 'antigravity')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), value)
        path.unlink(); foreign = self.home / 'unrelated'; foreign.write_text('{}'); path.symlink_to(foreign)
        self.assertNotEqual(self.cli('install-hooks', '--provider', 'antigravity').returncode, 0)
        self.assertEqual(foreign.read_text(), '{}')


if __name__ == '__main__':
    unittest.main()
