"""Regression fixtures for the additional-provider release review."""
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import timedelta
from test_additional_providers import agent, NOW, IDENTITY


class ProviderReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.state = self.home / 'state'
        self.counter = 0

    def tearDown(self):
        self.temp.cleanup()

    def event(self, name='session.execution.started', seq=None, identity='ses_one', **data):
        self.counter += 1
        event = dict(id=f'evt_{self.counter}', type=name, created=1795550400000,
                     data=dict(sessionID=identity, **data))
        if seq is not None:
            event['durable'] = dict(aggregateID=identity, seq=seq, version=1)
        return event

    def ingest(self, event):
        agent.ingest_hook('opencode', event, self.home, self.state, NOW)

    def rows(self):
        return agent.make_snapshot(self.home, self.state, NOW)['sessions']

    def one(self):
        rows = self.rows(); self.assertEqual(len(rows), 1, rows)
        return rows[0]

    def cli(self, payload, provider='opencode', timeout=2):
        argv = [sys.executable, agent.__file__, '--home', str(self.home), '--state-dir', str(self.state),
                'hook', '--provider', provider]
        if provider == 'antigravity':
            argv += ['--event', 'PreToolUse']
        try:
            return subprocess.run(argv, input=json.dumps(payload), capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            self.fail('Observational hook blocked instead of returning neutral output')

    def ag(self):
        return dict(conversationId=IDENTITY, workspacePaths=['/workspace/project'], transcriptPath=str(
            self.home / '.gemini/antigravity/brain' / IDENTITY / '.system_generated/logs/transcript.jsonl'))

    def links(self, provider, identity, **targets):
        agent.atomic_json(self.state / 'provider-links.json', dict(version=1, sessions=[dict(provider=provider,id=identity,**targets)]))

    def test_unicode_scalars_and_persisted_surrogates_cannot_poison_protocol(self):
        self.ingest(self.event('session.created', title='A' * 89 + '😀'))
        row = self.one(); self.assertEqual(row['title'], 'A' * 89 + '😀')
        path = next((self.state / 'hooks').glob('*.json'))
        saved = json.loads(path.read_text()); saved['title'] = 'bad\ud800title'; saved['project'] = '\udfff'
        path.write_text(json.dumps(saved))
        row = self.one()
        for value in (row['title'], row['project']):
            self.assertFalse(any(0xd800 <= ord(char) <= 0xdfff for char in value), repr(value))
        saved['id'] = 'ses_bad\ud800'; path.write_text(json.dumps(saved))
        self.assertEqual(self.rows(), [])

    def test_incoming_surrogate_display_metadata_is_sanitized_before_storage(self):
        self.ingest(self.event('session.created', title='unsafe\ud800title', location={'directory':'/workspace/bad\udfffproject'}))
        row = self.one()
        self.assertFalse(any(0xd800 <= ord(char) <= 0xdfff for char in row['title'] + row['project']))

    def test_durable_order_wins_over_same_or_older_timestamp_and_replayed_ids(self):
        success = self.event('session.execution.succeeded', seq=10); success['id'] = 'evt_10'
        self.ingest(success)
        start = self.event(seq=11); start['created'] -= 1
        self.ingest(start)
        self.ingest(success)
        self.assertEqual(self.one()['state'], 'working')
        forged = dict(success, durable=dict(aggregateID='ses_one', seq=12, version=1))
        self.ingest(forged)
        self.assertEqual(self.one()['state'], 'working', 'Duplicate event identity cannot acquire a newer ordering value')
        restart = self.event('session.execution.succeeded', seq=11)
        self.ingest(restart)
        self.assertEqual(self.one()['state'], 'working')

    def test_delete_tombstone_suppresses_delayed_lifecycle_and_bootstrap(self):
        self.ingest(self.event(seq=11))
        deleted = self.event('session.deleted', seq=12); deleted['created'] -= 500
        self.ingest(deleted)
        self.ingest(self.event('session.execution.succeeded', seq=10))
        self.ingest(self.event('wokintosh.session.discovered', title='inflight metadata', parentID='ses_parent'))
        self.assertEqual(self.rows(), [])
        receipt = json.loads(next((self.state / 'hooks').glob('*.json')).read_text())
        self.assertNotIn('inflight metadata', json.dumps(receipt))
        self.assertNotIn('openURLs', receipt)

    def test_permission_reply_validates_enum_and_waits_for_positive_activity(self):
        for reply in ('once', 'always', 'reject'):
            identity = 'ses_' + reply
            self.ingest(self.event('permission.asked', identity=identity, id='perm_a'))
            self.ingest(self.event('permission.asked', identity=identity, id='perm_b'))
            self.ingest(self.event('permission.replied', identity=identity, requestID='perm_a', reply=reply))
            row = next(row for row in self.rows() if row['id'] == identity)
            self.assertEqual(row['state'], 'needsAttention')
            self.ingest(self.event('permission.replied', identity=identity, requestID='perm_b', reply=reply))
            row = next(row for row in self.rows() if row['id'] == identity)
            self.assertEqual(row['state'], 'unknown')
            self.ingest(self.event(identity=identity))
            row = next(row for row in self.rows() if row['id'] == identity)
            self.assertEqual(row['state'], 'working')

    def test_permission_reply_missing_or_bad_enum_does_not_clear_wait(self):
        self.ingest(self.event('permission.asked', id='perm_a'))
        for data in ({}, {'reply':'allow'}, {'reply':['once']}):
            self.ingest(self.event('permission.replied', requestID='perm_a', **data))
            self.assertEqual(self.one()['state'], 'needsAttention')

    def test_antigravity_targets_require_matching_official_conversation_route(self):
        event = self.ag(); event['hook_event_name'] = 'PreInvocation'
        agent.ingest_hook('antigravity',event,self.home,self.state,NOW)
        good = 'https://antigravity.google.com/r/opaque-instance?p=c%2F' + IDENTITY
        invalid = ['https://example.com/r/i?p=c%2F' + IDENTITY,
                   'https://antigravity.google.com/?p=c%2F' + IDENTITY,
                   'https://antigravity.google.com/r/?p=c%2F' + IDENTITY,
                   'https://antigravity.google.com/r/i?p=c%2F00000000-0000-0000-0000-000000000000',
                   good + '&p=c%2F' + IDENTITY]
        for target in invalid:
            self.links('antigravity',IDENTITY,macOS=good,iOS=target)
            self.assertEqual(self.one().get('openURLs'), {'macOS':{'primary':good}})
        self.links('antigravity',IDENTITY,macOS=good,iOS=good)
        self.assertEqual(self.one()['openURLs']['iOS']['primary'],good)

    def test_opencode_credential_routes_are_rejected_after_path_normalization(self):
        self.ingest(self.event())
        for path in ('/%61uth/connect/private', '/safe/../auth/connect/private', '/%2e%2e/auth/connect/private',
                     '/safe/%2E%2E/%6fauth/login/private', '/%2561uth/connect/private', '/auth'):
            self.links('opencode','ses_one',iOS='https://example.com' + path)
            self.assertNotIn('openURLs',self.one(),path)

    def test_jsonc_primitives_survive_and_malformed_primitive_sequences_refuse_writes(self):
        config = self.home / '.config/opencode/opencode.jsonc'; config.parent.mkdir(parents=True)
        original = '{// retain\n"plugins":["foreign"],"settings":[1,2,true,false,null,-3.5e+2,],"nested":{"count":1,"enabled":false,}}'
        config.write_text(original)
        argv = [sys.executable,agent.__file__,'--home',str(self.home),'install-hooks','--provider','opencode']
        result = subprocess.run(argv,capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('"settings":[1,2,true,false,null,-3.5e+2,]',config.read_text())
        installed = config.read_text()
        self.assertEqual(subprocess.run(argv,capture_output=True,timeout=5).returncode,0)
        self.assertEqual(config.read_text(),installed)
        for malformed in ('{"settings":[,2]}','{"settings":[1,,2]}','{"settings":[1true]}','{"settings":[undefined]}'):
            config.write_text(malformed)
            result = subprocess.run(argv,capture_output=True,text=True,timeout=5)
            self.assertNotEqual(result.returncode,0,malformed)
            self.assertEqual(config.read_text(),malformed)

    def test_human_fork_is_visible_linkable_and_never_parent_background_work(self):
        self.ingest(self.event(identity='ses_original'))
        for event_first in (False,True):
            identity = 'ses_fork' + str(int(event_first))
            discovered = self.event('wokintosh.session.discovered',identity=identity,parentID='ses_original',fork=True)
            forked = self.event('session.forked',identity=identity,parentID='ses_original')
            for event in ((forked,discovered) if event_first else (discovered,forked)):
                self.ingest(event)
            self.ingest(self.event(identity=identity))
            self.links('opencode',identity,iOS='https://example.com/session/' + identity)
            row = next(row for row in self.rows() if row['id'] == identity)
            self.assertFalse(row['isHelper']); self.assertIsNone(row.get('parentId'))
            self.assertIn('openURLs',row)
        parent = next(row for row in self.rows() if row['id'] == 'ses_original')
        self.assertFalse(parent.get('background'))
        self.ingest(self.event('session.created',identity='ses_helper',parentID='ses_original'))
        helper = next(row for row in self.rows() if row['id'] == 'ses_helper')
        self.assertTrue(helper['isHelper']); self.assertEqual(helper['parentId'],'ses_original')

    def test_lock_fifo_symlink_and_symlinked_hooks_are_neutral_without_outside_writes(self):
        self.state.mkdir()
        outside = self.home / 'outside'; outside.mkdir()
        for provider in ('opencode','antigravity'):
            payload = self.event() if provider == 'opencode' else self.ag()
            lock = self.state / '.provider-hook.lock'
            lock.unlink(missing_ok=True)
            os.mkfifo(lock)
            result = self.cli(payload,provider); self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout), {} if provider=='opencode' else {'decision':'allow'})
            lock.unlink(); target = outside / 'lock'; target.write_text('untouched'); lock.symlink_to(target)
            result = self.cli(payload,provider); self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(target.read_text(),'untouched'); lock.unlink()
            hooks = self.state / 'hooks'
            if hooks.exists(): shutil.rmtree(hooks)
            hooks.symlink_to(outside,target_is_directory=True)
            result = self.cli(payload,provider); self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(sorted(p.name for p in outside.iterdir()), ['lock'])
            hooks.unlink()

    def test_contended_lock_has_bounded_wait_and_neutral_output(self):
        self.state.mkdir(); lock = (self.state / '.provider-hook.lock').open('a')
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            began = time.monotonic(); result = self.cli(self.ag(),'antigravity')
            self.assertLess(time.monotonic()-began,1.5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),{'decision':'allow'})
        finally: lock.close()

    def test_snapshot_does_not_scan_symlinked_hook_directory(self):
        self.state.mkdir(); outside = self.home / 'outside'; outside.mkdir()
        saved = agent.base_session('ses_outside','opencode','',NOW)
        (outside/'private.json').write_text(json.dumps(saved))
        (self.state/'hooks').symlink_to(outside,target_is_directory=True)
        self.assertEqual(self.rows(),[])

    def test_generated_bridge_preserves_scalars_order_reply_and_fork_metadata(self):
        if shutil.which('node') is None: self.skipTest('Node needed for generated bridge boundary')
        plugin = self.home/'plugin'; plugin.mkdir()
        sdk = plugin/'node_modules/@opencode/plugin'; sdk.mkdir(parents=True)
        (plugin/'package.json').write_text('{"type":"module"}')
        (sdk/'package.json').write_text('{"name":"@opencode/plugin","type":"module","exports":"./index.js"}')
        (sdk/'index.js').write_text('export const Plugin = {define: value => value};')
        capture = self.home/'capture.py'; output = self.home/'captured.jsonl'
        capture.write_text('import sys\nwith open(sys.argv[1],"a") as f: f.write(sys.stdin.read()+"\\n")\n')
        command = shlex.join([sys.executable,str(capture),str(output)])
        (plugin/'index.js').write_text(agent.opencode_plugin_source(command))
        events = [self.event('session.created',seq=1,title='A'*89+'😀'),
                  self.event('permission.replied',requestID='perm_a',reply='reject')]
        harness = self.home/'harness.mjs'
        harness.write_text('''import {pathToFileURL} from 'node:url';
const plugin=(await import(pathToFileURL(process.argv[2]))).default;
const events=JSON.parse(process.argv[3]); let done; const finished=new Promise(r=>done=r);
const stop=await plugin.setup({location:{directory:'/workspace'},session:{async list(){return {data:[{
id:'ses_inventory',title:'Inventory',parentID:'ses_origin',fork:{sessionID:'ses_origin'},time:{updated:events[0].created},location:{directory:'/workspace'}}]};}},
event:{async *subscribe(){for(const event of events) yield event;done();}}});
await finished; await new Promise(r=>setTimeout(r,100)); stop();''')
        result = subprocess.run(['node',str(harness),str(plugin/'index.js'),json.dumps(events)],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        rows = [json.loads(line) for line in output.read_text().splitlines()]
        created = next(row for row in rows if row['type']=='session.created')
        self.assertEqual(created['data']['title'],'A'*89+'😀')
        self.assertEqual(created.get('id'),events[0]['id']); self.assertEqual(created.get('durable'),events[0]['durable'])
        reply = next(row for row in rows if row['type']=='permission.replied')
        self.assertEqual(reply['data'].get('reply'),'reject')
        discovered = next(row for row in rows if row['type']=='wokintosh.session.discovered')
        self.assertTrue(discovered['data'].get('fork'))


if __name__ == '__main__': unittest.main()
