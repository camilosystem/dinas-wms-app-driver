import Foundation
import Security

/// Almacenamiento seguro del JWT en el Keychain del dispositivo.
/// El token nunca se guarda en UserDefaults ni en la base local.
struct KeychainStore {
    let service: String

    init(service: String = "com.dinas.driver.auth") {
        self.service = service
    }

    /// Guarda (o reemplaza) un valor para una clave.
    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: key)

        // Reemplaza si ya existe.
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        // Accesible tras el primer desbloqueo (sobrevive reinicios, sirve offline) y
        // ligado a ESTE dispositivo (no se sincroniza a iCloud Keychain).
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    /// Lee el valor de una clave, o `nil` si no existe.
    func get(_ key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unhandled(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Elimina el valor de una clave (por ejemplo, al cerrar sesión).
    func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

enum KeychainError: Error {
    case unhandled(OSStatus)
}
