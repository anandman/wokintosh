import base64
import copy
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('validate_update', Path(__file__).resolve().parents[1] / 'validate_update.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class UpdateReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wokintosh-feed-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'Wokintosh-1.1.0-macOS-arm64.dmg'
        self.archive.write_bytes(b'controlled archive bytes')
        self.app = self.root / 'Wokintosh.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.key = 'TAaCU1G+fT+qcAYYVMB3G4Kkb2aPqpNk0wLEaubfdlQ='
        self.info = dict(CFBundleIdentifier='dev.wokintosh.dashboard', CFBundleShortVersionString='1.1.0', CFBundleVersion='13', LSMinimumSystemVersion='14.0', SUFeedURL='https://github.com/anandman/wokintosh/releases/latest/download/appcast.xml', SUPublicEDKey=self.key, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True, SUEnableSystemProfiling=False)
        self.feed = self.root / 'appcast.xml'
        self.signature = base64.b64encode(b's' * 64).decode()
        self.url = 'https://github.com/anandman/wokintosh/releases/download/v1.1.0/Wokintosh-1.1.0-macOS-arm64.dmg'
        self.write()

    def write(self, **overrides):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        values = dict(url=self.url, length=self.archive.stat().st_size, signature=self.signature, build='13', version='1.1.0', minimum='14.0')
        values.update(overrides)
        self.feed.write_text('''<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion><enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>'''.format(**values))

    def validate(self):
        return MODULE.validate_metadata(self.app, self.archive, self.feed, '1.1.0', '13', self.key)

    def test_matching_feed_returns_archive_signature_for_crypto_verification(self):
        self.assertEqual(self.validate(), self.signature)

    def test_rejects_wrong_download_host_or_release(self):
        for url in ['http://github.com/anandman/wokintosh/releases/download/v1.1.0/test.dmg', 'https://example.org/update.dmg', self.url.replace('v1.1.0', 'v1.0.2')]:
            with self.subTest(url=url):
                self.write(url=url)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_rejects_mismatched_archive_bytes_and_missing_signature(self):
        for overrides in [dict(length=1), dict(signature=''), dict(signature='not-base64'), dict(build='12'), dict(version='1.0.2'), dict(minimum='15.0')]:
            with self.subTest(overrides=overrides):
                self.write(**overrides)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_rejects_release_without_required_verification_or_matching_public_key(self):
        baseline = copy.copy(self.info)
        for field, value in [('SURequireSignedFeed', False), ('SUVerifyUpdateBeforeExtraction', False), ('SUPublicEDKey', base64.b64encode(b'x' * 32).decode()), ('SUFeedURL', 'https://example.org/feed.xml'), ('CFBundleIdentifier', 'other.app')]:
            with self.subTest(field=field):
                self.info = {**baseline, field: value}
                self.write()
                with self.assertRaises(ValueError):
                    self.validate()

    def test_rejects_truncated_xml_or_absent_archive(self):
        self.feed.write_text('<rss>')
        with self.assertRaises(ValueError):
            self.validate()
        self.write()
        self.archive.unlink()
        with self.assertRaises(ValueError):
            self.validate()


if __name__ == '__main__':
    unittest.main()
