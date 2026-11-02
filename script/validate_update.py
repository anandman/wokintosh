#!/usr/bin/env python3
"""Fail closed if the final update archive, app, or signed feed disagree."""
import argparse
import base64
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

FEED_URL = 'https://github.com/anandman/wokintosh/releases/latest/download/appcast.xml'
NAMESPACE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate_metadata(app, archive, feed, version, build, public_key):
    app, archive, feed = Path(app), Path(archive), Path(feed)
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        size = archive.stat().st_size
        data = feed.read_bytes()
        if not size or len(data) > 2_000_000:
            raise ValueError('Empty archive or oversized appcast')
        tree = ET.fromstring(data)
    except (OSError, ET.ParseError, plistlib.InvalidFileException) as error:
        raise ValueError('Unreadable update artifact: ' + str(error)) from error
    expected = dict(CFBundleIdentifier='dev.wokintosh.dashboard', CFBundleShortVersionString=version,
                    CFBundleVersion=build, SUFeedURL=FEED_URL, SUPublicEDKey=public_key,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True, SUEnableSystemProfiling=False)
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError('Unexpected app updater setting: ' + key)
    try:
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError('Invalid updater public key')
    except Exception as error:
        raise ValueError('Invalid updater public key') from error
    name = f'Wokintosh-{version}-macOS-arm64.dmg'
    if archive.name != name:
        raise ValueError('Unexpected archive filename')
    items = tree.findall('./channel/item')
    matching = [item for item in items if item.findtext(NAMESPACE + 'version') == build]
    if len(matching) != 1:
        raise ValueError('Missing or ambiguous update build in appcast')
    item = matching[0]
    minimum = item.findtext(NAMESPACE + 'minimumSystemVersion')
    if item.findtext(NAMESPACE + 'shortVersionString') != version or not minimum:
        raise ValueError('Incorrect appcast version or minimum macOS')
    if tuple(map(int, minimum.split('.')))[:2] != tuple(map(int, info['LSMinimumSystemVersion'].split('.')))[:2]:
        raise ValueError('Appcast minimum macOS does not match the app')
    if item.findtext(NAMESPACE + 'channel'):
        raise ValueError('Stable releases must not specify a beta channel')
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Missing appcast download')
    url = f'https://github.com/anandman/wokintosh/releases/download/v{version}/{name}'
    if enclosure.get('url') != url or enclosure.get('length') != str(size):
        raise ValueError('Appcast download URL or byte length does not match the release')
    signature = enclosure.get(NAMESPACE + 'edSignature', '')
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError('Invalid archive signature')
    except Exception as error:
        raise ValueError('Missing or invalid EdDSA archive signature') from error
    return signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'archive', 'feed', 'version', 'build', 'public-key', 'tools', 'account'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    signature = validate_metadata(args.app, args.archive, args.feed, args.version, args.build, args.public_key)
    tools = Path(args.tools)
    key = subprocess.check_output([str(tools / 'generate_keys'), '--account', args.account, '-p'], text=True).strip()
    if key != args.public_key:
        raise SystemExit('Keychain public key differs from the app public key')
    for command in ([str(tools / 'sign_update'), '--account', args.account, '--verify', args.archive, signature],
                    [str(tools / 'sign_update'), '--account', args.account, '--verify', args.feed]):
        subprocess.run(command, check=True)
    print('Verified update metadata, archive signature, and signed appcast.')


if __name__ == '__main__':
    main()
