import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('validate_iphone', Path(__file__).resolve().parents[1] / 'validate_iphone.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class IOSSigningTests(unittest.TestCase):
    def setUp(self):
        self.identifier='org.example.dashboard'
        self.group='group.org.example.dashboard.shared'
        self.team='ABCDE12345'
        self.app_info={'CFBundleIdentifier':self.identifier,'WokintoshAppGroupIdentifier':self.group,'WokintoshKeychainAccessGroup':self.team+'.'+self.identifier+'.shared'}
        self.widget_info={**self.app_info,'CFBundleIdentifier':self.identifier+'.agents'}
        def ent(identifier):return {'application-identifier':self.team+'.'+identifier,'com.apple.developer.team-identifier':self.team,'com.apple.security.application-groups':[self.group],'keychain-access-groups':[self.team+'.'+self.identifier+'.shared']}
        self.app_ent=ent(self.identifier)
        self.widget_ent=ent(self.identifier+'.agents')
    def validate(self):return MODULE.validate_capabilities(self.app_info,self.app_ent,self.widget_info,self.widget_ent)
    def test_accepts_developer_owned_identifiers(self):
        self.validate()
    def test_rejects_different_app_groups(self):
        self.widget_info['WokintoshAppGroupIdentifier']='group.org.example.other'
        with self.assertRaises(ValueError):self.validate()
    def test_rejects_missing_group_entitlement(self):
        self.widget_ent['com.apple.security.application-groups']=[]
        with self.assertRaises(ValueError):self.validate()
    def test_rejects_different_signing_teams(self):
        self.widget_ent['com.apple.developer.team-identifier']='OTHER12345'
        with self.assertRaises(ValueError):self.validate()
    def test_rejects_private_keychain_instead_of_shared_group(self):
        self.widget_ent['keychain-access-groups']=[self.team+'.'+self.identifier+'.agents']
        with self.assertRaises(ValueError):self.validate()
    def test_rejects_unresolved_identifiers(self):
        self.app_info['WokintoshAppGroupIdentifier']='$(WOKINTOSH_PHONE_APP_GROUP_ID)'
        with self.assertRaises(ValueError):self.validate()
