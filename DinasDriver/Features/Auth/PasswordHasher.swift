import Foundation
import CryptoKit
import Security

/// Hash salado de la contraseña, para **verificación offline**. NO se guarda la
/// contraseña en claro; solo este derivado (salt + iteraciones + hash) vive en el Keychain.
struct PasswordHash: Codable, Equatable, Sendable {
    var salt: Data
    var iterations: Int
    var derived: Data
}

protocol PasswordHashing: Sendable {
    func hash(_ password: String) throws -> PasswordHash
    func verify(_ password: String, _ stored: PasswordHash) -> Bool
}

/// PBKDF2-HMAC-SHA256 implementado sobre CryptoKit (sin dependencias externas).
///
/// El KDF con muchas iteraciones + salt aleatorio encarece un ataque de fuerza bruta
/// offline si alguien lograra extraer el Keychain de un dispositivo comprometido. La
/// protección principal sigue siendo el passcode del dispositivo (JAMF) + Keychain.
struct PBKDF2Hasher: PasswordHashing {
    var iterations: Int = 210_000
    private let saltLength = 16   // 128 bits

    func hash(_ password: String) throws -> PasswordHash {
        var salt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &salt) == errSecSuccess else {
            throw PasswordHashError.randomFailed
        }
        let derived = Self.derive(password: Array(password.utf8), salt: salt, iterations: iterations)
        return PasswordHash(salt: Data(salt), iterations: iterations, derived: Data(derived))
    }

    func verify(_ password: String, _ stored: PasswordHash) -> Bool {
        let derived = Self.derive(password: Array(password.utf8),
                                  salt: [UInt8](stored.salt),
                                  iterations: stored.iterations)
        return Self.constantTimeEquals(derived, [UInt8](stored.derived))
    }

    /// PBKDF2 con bloque único (la clave de 32 bytes cabe en un bloque SHA-256).
    private static func derive(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])   // INT_32_BE(1)
        var u = Array(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var result = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for i in 0..<result.count { result[i] ^= u[i] }
            }
        }
        return result
    }

    /// Comparación en tiempo constante (evita fugas por timing).
    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

enum PasswordHashError: Error { case randomFailed }
