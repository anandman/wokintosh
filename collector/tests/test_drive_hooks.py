"""Drive inventory and named observer migration contracts."""
import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import textwrap
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('drive_collector', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
USAGE = shutil._ntuple_diskusage(total=1000, used=600, free=400)


class DriveTests(unittest.TestCase):
    def snapshot(self, system, output, usage=None):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            with patch.object(agent.platform, 'system', return_value=system), \
                 patch.object(agent, 'command_output', side_effect=lambda args: output if args == ['df', '-P', '-k'] else ''), \
                 patch.object(agent.shutil, 'disk_usage', side_effect=usage or (lambda path: USAGE)):
                return agent.make_snapshot(home, home / 'state', datetime.now(timezone.utc))

    def test_blocked_extra_volume_cannot_prevent_healthy_snapshot(self):
        # A filesystem stat on this mounted share would block for 60 seconds.
        # The whole real snapshot must still complete within the process deadline.
        script = textwrap.dedent("""
            import importlib.util, json, tempfile, time
            from datetime import datetime, timezone
            from pathlib import Path
            from types import SimpleNamespace
            spec = importlib.util.spec_from_file_location('collector', SCRIPT_PATH)
            agent = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(agent)
            agent.platform.system = lambda: 'Darwin'
            agent.command_output = lambda args: 'server:/share 500 300 200 60% /Volumes/Slow' if args == ['df', '-P', '-k'] else ''
            def usage(path):
                if str(path) == '/Volumes/Slow':
                    time.sleep(60)
                return SimpleNamespace(total=1000, used=600, free=400)
            agent.shutil.disk_usage = usage
            with tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                log = home / '.codex/sessions/healthy.jsonl'
                log.parent.mkdir(parents=True)
                now = datetime.now(timezone.utc)
                log.write_text(json.dumps({'type': 'session_meta', 'timestamp': now.isoformat(), 'payload': {'id': 'healthy', 'cwd': '/src'}}) + chr(10))
                print(json.dumps(agent.make_snapshot(home, home / 'state', now)))
        """).replace('SCRIPT_PATH', repr(str(Path(agent.__file__).resolve())))
        try:
            result = subprocess.run([sys.executable, '-c', script], capture_output=True,
                                    text=True, timeout=3, check=True)
        except subprocess.TimeoutExpired:
            self.fail('blocked extra drive prevented healthy host snapshot')
        snapshot = json.loads(result.stdout)
        self.assertEqual([item['id'] for item in snapshot['sessions']], ['healthy'])
        self.assertEqual(snapshot['system']['drives'][-1], {
            'id': '/Volumes/Slow', 'name': 'Slow', 'mountPoint': '/Volumes/Slow',
            'freeBytes': 204800, 'totalBytes': 512000})

    def test_macos_measures_root_and_external_volumes_with_spaces(self):
        output = '''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1 100 50 50 50% /
/dev/disk3s5 100 50 50 50% /System/Volumes/Data
/dev/disk9s1 2000 1400 600 70% /Volumes/Work Drive
/dev/disk10s1 3000 1800 1200 60% /Volumes/Backup\\040Disk
/dev/disk9s1 2000 1400 600 70% /Volumes/Work Drive
'''
        snapshot = self.snapshot('Darwin', output)
        self.assertIn('drives', snapshot['system'], 'snapshot must expose measured drive selections')
        self.assertEqual(snapshot['system']['drives'], [
            {'id': '/', 'name': 'System', 'mountPoint': '/', 'freeBytes': 400, 'totalBytes': 1000},
            {'id': '/Volumes/Backup Disk', 'name': 'Backup Disk', 'mountPoint': '/Volumes/Backup Disk', 'freeBytes': 1228800, 'totalBytes': 3072000},
            {'id': '/Volumes/Work Drive', 'name': 'Work Drive', 'mountPoint': '/Volumes/Work Drive', 'freeBytes': 614400, 'totalBytes': 2048000}])
        self.assertEqual(snapshot['schemaVersion'], 1)
        self.assertEqual(snapshot['system']['diskFreeBytes'], 400)
        self.assertEqual(snapshot['system']['diskTotalBytes'], 1000)

    def test_linux_excludes_pseudo_and_container_bind_mounts(self):
        output = '''Filesystem 1024-blocks Used Available Capacity Mounted on
overlay 100 50 50 50% /
tmpfs 100 50 50 50% /run
proc 100 50 50 50% /proc
/dev/sda 100 50 50 50% /etc/hosts
/dev/sda 100 50 50 50% /etc/resolv.conf
/dev/sda 100 50 50 50% /etc/hostname
/dev/sdb1 100 50 50 50% /media/user/USB Drive
/dev/nvme1n1 100 50 50 50% /data
server:/share 100 50 50 50% /mnt/Share
//server/smb 100 50 50 50% /run/media/user/SMB
/dev/sda1 100 50 50 50% /boot/efi
tmpfs 100 50 50 50% /mnt/temporary
'''
        snapshot = self.snapshot('Linux', output)
        self.assertIn('drives', snapshot['system'])
        self.assertEqual([d['mountPoint'] for d in snapshot['system']['drives']],
                         ['/', '/data', '/media/user/USB Drive', '/mnt/Share', '/run/media/user/SMB'])

    def test_enumeration_failure_still_measures_root(self):
        snapshot = self.snapshot('Darwin', '')
        self.assertIn('drives', snapshot['system'])
        self.assertEqual(snapshot['system']['drives'], [
            {'id': '/', 'name': 'System', 'mountPoint': '/', 'freeBytes': 400, 'totalBytes': 1000}])

    def test_unreadable_drive_keeps_other_measurements_and_legacy_failure_is_safe(self):
        def usage(path):
            if str(path) != '/':
                raise OSError('volume unavailable')
            return USAGE
        try:
            snapshot = self.snapshot('Darwin', '/dev/disk9 100 50 unavailable 50% /Volumes/Locked', usage)
        except OSError:
            self.fail('unreadable disk must not abort a healthy snapshot')
        self.assertIn('drives', snapshot['system'])
        self.assertIsNone(snapshot['system']['diskFreeBytes'])
        self.assertEqual(snapshot['system']['drives'][-1], {
            'id': '/Volumes/Locked', 'name': 'Locked', 'mountPoint': '/Volumes/Locked',
            'freeBytes': None, 'totalBytes': None})
        self.assertEqual(snapshot['system']['drives'][0]['freeBytes'], 400)

    def test_inventory_bounds_emitted_user_volumes_to_64(self):
        output = '\n'.join(f'/dev/disk{i} 100 50 50 50% /Volumes/Drive{i:03}' for i in range(100))
        snapshot = self.snapshot('Darwin', output)
        self.assertIn('drives', snapshot['system'])
        self.assertEqual(len(snapshot['system']['drives']), 65)
        self.assertEqual(snapshot['system']['drives'][-1]['mountPoint'], '/Volumes/Drive063')


class NamedHookTests(unittest.TestCase):
    def test_new_hook_metadata_is_supported_and_identifies_wokintosh(self):
        for provider in ('codex', 'claude'):
            config = agent.hook_install_config(provider, '/safe/Wokintosh-status-observer.py hook', {})
            if provider == 'codex':
                self.assertTrue(config.get('description', '').startswith('Wokintosh'))
            else:
                self.assertNotIn('description', config)
            for entries in config['hooks'].values():
                for entry in entries:
                    handler = entry['hooks'][0]
                    self.assertTrue(handler.get('statusMessage', '').startswith('Wokintosh'))
                    self.assertIn('# Wokintosh status observer; wokintosh-observer', handler['command'])
                    self.assertNotIn('name', handler)

    def test_reenable_migrates_marked_handlers_and_preserves_matchers_and_extras(self):
        unrelated = {'type': 'command', 'command': 'other-hook', 'statusMessage': 'Other', 'timeout': 19}
        existing = {'description': 'My hooks', 'other': {'keep': True}, 'hooks': {
            'Stop': [{'matcher': 'keep-matcher', 'groupExtra': 42, 'hooks': [
                unrelated, {'type': 'command', 'command': '/old/collector hook # wokintosh-observer',
                            'timeout': 7, 'async': True, 'extra': {'preserve': True}}]}],
            'CustomEvent': [{'matcher': '*', 'hooks': [
                {'type': 'command', 'command': '/old/collector hook # wokintosh-observer'}]}]}}
        before = copy.deepcopy(existing)
        for provider in ('codex', 'claude'):
            result = agent.hook_install_config(provider, '/new/Wokintosh-status-observer.py hook', existing)
            self.assertEqual(result['description'], 'My hooks')
            self.assertEqual(result['other'], {'keep': True})
            self.assertEqual(existing, before)
            stop = result['hooks']['Stop']
            self.assertEqual(len(stop), 1)
            self.assertEqual(stop[0]['matcher'], 'keep-matcher')
            self.assertEqual(stop[0]['groupExtra'], 42)
            self.assertEqual(stop[0]['hooks'][0], unrelated)
            own = stop[0]['hooks'][1]
            self.assertTrue(own['command'].startswith('/new/Wokintosh-status-observer.py hook'))
            self.assertTrue(own.get('statusMessage', '').startswith('Wokintosh'))
            self.assertEqual((own['timeout'], own['async'], own['extra']), (7, True, {'preserve': True}))
            custom = result['hooks']['CustomEvent'][0]['hooks'][0]
            self.assertTrue(custom['command'].startswith('/new/Wokintosh-status-observer.py hook'))
            self.assertEqual(agent.hook_install_config(provider, '/new/Wokintosh-status-observer.py hook', result), result)


if __name__ == '__main__':
    unittest.main()
