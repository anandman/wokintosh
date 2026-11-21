#!/usr/bin/env python3
"""Check that a signed companion app and widget share their configured storage."""
from pathlib import Path
import plistlib
import subprocess
import sys


def validate_capabilities(app_info, app_ent, widget_info, widget_ent):
    identifier = app_info.get('CFBundleIdentifier')
    group = app_info.get('WokintoshAppGroupIdentifier')
    if (not isinstance(identifier, str) or not identifier or '$(' in identifier or
            widget_info.get('CFBundleIdentifier') != identifier + '.agents' or
            not isinstance(group, str) or not group.startswith('group.') or '$(' in group or
            widget_info.get('WokintoshAppGroupIdentifier') != group):
        raise ValueError('Configure matching app/widget identifiers and App Groups in your local signing settings.')
    teams, prefixes = set(), set()
    for info, ent in [(app_info, app_ent), (widget_info, widget_ent)]:
        bundle_id = info['CFBundleIdentifier']
        team = ent.get('com.apple.developer.team-identifier')
        application = ent.get('application-identifier', '')
        if not team or not application.endswith('.' + bundle_id):
            raise ValueError('The app and widget need explicit iOS/iPadOS development provisioning profiles.')
        prefix = application[:-len(bundle_id)]
        shared = prefix + identifier + '.shared'
        if (group not in ent.get('com.apple.security.application-groups', []) or
                shared not in ent.get('keychain-access-groups', []) or
                info.get('WokintoshKeychainAccessGroup') != shared):
            raise ValueError('The signed app and widget need matching App Group and Keychain Sharing capabilities.')
        teams.add(team)
        prefixes.add(prefix)
    if len(teams) != 1 or len(prefixes) != 1:
        raise ValueError('The app and widget must use the same signing team and App ID prefix.')


def validate(app):
    bundles = [Path(app), Path(app) / 'PlugIns/WokintoshAgentWidget.appex']
    infos, entitlements = [], []
    for bundle in bundles:
        infos.append(plistlib.loads((bundle / 'Info.plist').read_bytes()))
        signed = subprocess.check_output(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], stderr=subprocess.DEVNULL)
        entitlements.append(plistlib.loads(signed))
    validate_capabilities(infos[0], entitlements[0], infos[1], entitlements[1])


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: validate_iphone.py WokintoshPhone.app')
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit('Companion signing validation failed: ' + str(error))
