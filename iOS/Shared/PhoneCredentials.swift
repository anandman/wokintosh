import Foundation
import Security
import WokintoshCore

struct KeychainPhoneCredentials:PhoneCredentialStore {
    private let accessGroup:String
    init(accessGroup:String?=nil)throws {
        guard let group=accessGroup ?? Bundle.main.object(forInfoDictionaryKey:"WokintoshKeychainAccessGroup") as? String,
              !group.isEmpty,!group.contains("$(") else {throw PhoneStorageError.notConfigured}
        self.accessGroup=group
    }
    private var query:[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.wokintosh.phone",kSecAttrAccount as String:"publisher",
         kSecAttrAccessGroup as String:accessGroup]
    }
    func load()throws->PhonePairing? {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var item:CFTypeRef?
        let result=SecItemCopyMatching(q as CFDictionary,&item)
        if result==errSecItemNotFound {return nil}
        guard result==errSecSuccess,let data=item as? Data else {throw PhoneStorageError.keychain}
        return try PhonePairing.decode(data)
    }
    func save(_ value:PhonePairing)throws {
        let data=try value.encoded()
        let result=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result==errSecItemNotFound {
            var add=query;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else {throw PhoneStorageError.keychain}
        } else if result != errSecSuccess {throw PhoneStorageError.keychain}
    }
    func remove()throws {
        let result=SecItemDelete(query as CFDictionary)
        guard result==errSecSuccess || result==errSecItemNotFound else {throw PhoneStorageError.keychain}
    }
}
