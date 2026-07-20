import Foundation

/// Sesión persistida en el dispositivo. Marca "este dispositivo tiene sesión establecida"
/// y permite abrir la app **sin conexión** (offline-first). Incluye el JWT para el sync.
struct StoredSession: Codable, Equatable, Sendable {
    var token: String
    var username: String
    var displayName: String?
    var salespersonCode: String?
    /// Momento del último login ONLINE exitoso (hora del dispositivo).
    var lastOnlineLoginAt: Date
    /// Hash de la contraseña para re-login OFFLINE (no se guarda la contraseña).
    var passwordHash: PasswordHash
    /// `true` tras un logout explícito: la sesión persiste (para re-login offline con
    /// contraseña) pero la app arranca en el login, no directo.
    var loggedOut: Bool = false
}

/// Almacenamiento de la sesión.
///
/// Producción: Keychain (protegido por el passcode del dispositivo, no viaja a iCloud).
/// Tests: en memoria. No se guarda la contraseña — la "credencial offline" es haber
/// iniciado sesión antes en este dispositivo.
protocol SessionStore {
    func read() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

/// Implementación de producción: serializa la sesión (JSON) y la guarda en el Keychain.
struct KeychainSessionStore: SessionStore {
    private let keychain: KeychainStore
    private let key: String

    init(keychain: KeychainStore = KeychainStore(), key: String = "session") {
        self.keychain = keychain
        self.key = key
    }

    func read() throws -> StoredSession? {
        guard let json = try keychain.get(key), let data = json.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.set(String(decoding: data, as: UTF8.self), for: key)
    }

    func clear() throws { try keychain.delete(key) }
}

/// Implementación en memoria para tests y previews.
final class InMemorySessionStore: SessionStore {
    private var session: StoredSession?

    init(session: StoredSession? = nil) { self.session = session }

    func read() throws -> StoredSession? { session }
    func save(_ session: StoredSession) throws { self.session = session }
    func clear() throws { session = nil }
}
