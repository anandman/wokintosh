import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location('collector_updates', Path(__file__).parents[1] / 'wokintosh_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class CollectorUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.source = Path(agent.__file__)
        self.observer = self.home / 'Library/Application Support/Wokintosh/bin/Wokintosh-status-observer.py'
        self.old = self.source.read_bytes() + b'\n# older observer fixture\n'

    def install_old(self):
        self.observer.parent.mkdir(parents=True)
        self.observer.write_bytes(self.old)
        self.observer.chmod(0o700)

    def test_snapshot_reports_body_free_source_identity_and_observer_status(self):
        self.install_old()
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            snapshot = agent.make_snapshot(self.home, self.home/'state', datetime.now(timezone.utc))
        info = snapshot['collector']
        self.assertEqual(info['revision'], hashlib.sha256(self.source.read_bytes().split(b'\n', 1)[1]).hexdigest())
        self.assertEqual(info['observerStatus'], 'updateAvailable')
        self.assertEqual(snapshot['schemaVersion'], 1)
        self.assertNotIn(str(self.home), json.dumps(info))
        self.assertNotIn('older observer fixture', json.dumps(info))

    def test_pinned_shebang_does_not_cause_a_false_observer_update(self):
        self.install_old()
        self.observer.write_bytes(b'#!/different/python3\n' + self.source.read_bytes().split(b'\n', 1)[1])
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            info = agent.collector_metadata(self.home)
        self.assertEqual(info['observerStatus'], 'current')

    def test_refresh_backs_up_existing_copy_and_preserves_provider_settings(self):
        self.install_old()
        settings = self.home / '.codex/config.toml'
        settings.parent.mkdir()
        original = b'# provider configuration and trust must stay exact\n'
        settings.write_bytes(original)
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            result = agent.refresh_managed_observer(self.home)
            again = agent.refresh_managed_observer(self.home)
        self.assertEqual(result['status'], 'updated')
        self.assertEqual(Path(result['backupPath']).read_bytes(), self.old)
        self.assertEqual(self.observer.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.observer.stat().st_mode & 0o777, 0o700)
        self.assertEqual(settings.read_bytes(), original)
        self.assertEqual(again['status'], 'current')
        self.assertEqual(len(list(self.observer.parent.glob('*.wokintosh-backup-*'))), 1)

    def test_missing_observer_is_not_created_or_enabled(self):
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            self.assertEqual(agent.refresh_managed_observer(self.home)['status'], 'notInstalled')
        self.assertFalse(self.observer.parent.exists())

    def test_unknown_file_and_symlink_are_never_overwritten(self):
        self.install_old()
        foreign = b'#!/usr/bin/env python3\nprint("custom observer")\n'
        self.observer.write_bytes(foreign)
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            with self.assertRaises(ValueError): agent.refresh_managed_observer(self.home)
            self.assertEqual(agent.collector_metadata(self.home)['observerStatus'], 'unavailable')
        self.assertEqual(self.observer.read_bytes(), foreign)
        target = self.home / 'unrelated.py'
        target.write_bytes(self.old)
        self.observer.unlink()
        self.observer.symlink_to(target)
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            with self.assertRaises(ValueError): agent.refresh_managed_observer(self.home)
        self.assertEqual(target.read_bytes(), self.old)
        self.assertTrue(self.observer.is_symlink())

    def test_symlinked_parent_and_shared_writable_file_are_refused(self):
        self.install_old()
        self.observer.chmod(0o777)
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            with self.assertRaises(ValueError): agent.refresh_managed_observer(self.home)
        self.observer.chmod(0o700)
        real_bin = self.observer.parent.with_name('real-bin')
        self.observer.parent.rename(real_bin)
        self.observer.parent.symlink_to(real_bin, target_is_directory=True)
        with patch.object(agent.platform, 'system', return_value='Darwin'):
            with self.assertRaises(ValueError): agent.refresh_managed_observer(self.home)
        self.assertEqual((real_bin/self.observer.name).read_bytes(), self.old)

    def test_read_only_observer_is_preserved_without_creating_a_backup(self):
        self.install_old()
        for mode in (0o400, 0o500):
            self.observer.chmod(mode)
            with patch.object(agent.platform, 'system', return_value='Darwin'):
                with self.assertRaises(ValueError): agent.refresh_managed_observer(self.home)
            self.assertEqual(self.observer.read_bytes(), self.old)
            self.assertEqual(self.observer.stat().st_mode & 0o777, mode)
            self.assertEqual(list(self.observer.parent.glob('*.wokintosh-backup-*')), [])

    def test_cli_refresh_returns_json_without_changing_hook_configuration(self):
        self.install_old()
        # Physical platform chooses the managed macOS copy; Linux has no such copy.
        run = subprocess.run([sys.executable, str(self.source), '--home', str(self.home),
                              'refresh-observer', '--json'], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        expected = 'updated' if sys.platform == 'darwin' else 'notInstalled'
        self.assertEqual(json.loads(run.stdout)['status'], expected)
        self.assertFalse((self.home/'.codex').exists())
        self.assertFalse((self.home/'.claude').exists())
