import Foundation
import os

/// Motivo de un login fallido (para mostrar el mensaje correcto y para tests).
enum LoginFailure: Equatable {
    case badCredentials     // 401: usuario/contraseña incorrectos
    case offlineNoSession   // sin red y sin sesión previa en el dispositivo
    case offlineExpired     // >7 días sin login online: se exige autenticación online
    case serverError        // 5xx / configuración
    case connectionError    // la red falló pese a estar "online"
    case wrongRole          // credenciales válidas pero el rol no es el de esta app
}

/// Estado de sesión del vendedor y fuente de verdad para mostrar login o app.
///
/// **Sesión ligada al dispositivo (offline-first):** si el dispositivo ya tiene una
/// sesión guardada (login online previo), la app se abre SIN conexión y el vendedor
/// trabaja con los últimos datos sincronizados. No se guarda la contraseña.
@MainActor
final class AuthSession: ObservableObject {

    enum State: Equatable {
        case unknown     // aún no se consultó el almacenamiento
        case signedOut   // sin sesión en el dispositivo
        case signedIn    // sesión establecida (online u offline)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var isAuthenticating = false
    @Published private(set) var displayName: String?
    @Published private(set) var username: String?
    /// Token vencido (401): la app sigue usable offline, pero NO puede sincronizar hasta
    /// re-autenticarse con conexión.
    @Published private(set) var needsReauth = false
    @Published private(set) var loginFailure: LoginFailure?
    @Published var errorMessage: String?

    /// Máxima antigüedad del último login ONLINE para seguir permitiendo login offline.
    /// Pasados 7 días sin autenticación online, se exige volver a autenticarse online.
    static let offlineSessionMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Se invoca tras un login ONLINE exitoso (el vendedor pudo cambiar) → se usa para
    /// resetear las marcas de sync y forzar una bajada completa.
    var onOnlineLogin: () -> Void = {}

    private let api: AuthAPI
    private let store: SessionStore
    private let hasher: PasswordHashing
    private let now: () -> Date
    /// Rol exigido por esta app (BODEGUERO). Si el login devuelve otro rol, se rechaza con
    /// un mensaje claro. `nil` = sin restricción de rol.
    private let requiredRole: String?

    private func isOfflineExpired(_ session: StoredSession) -> Bool {
        now().timeIntervalSince(session.lastOnlineLoginAt) > Self.offlineSessionMaxAge
    }

    init(api: AuthAPI, store: SessionStore,
         hasher: PasswordHashing = PBKDF2Hasher(),
         requiredRole: String? = nil,
         now: @escaping () -> Date = Date.init) {
        self.api = api
        self.store = store
        self.hasher = hasher
        self.requiredRole = requiredRole
        self.now = now
    }

    /// Restaura la sesión al arrancar. Entra directo solo si hay sesión activa (no se
    /// cerró sesión). Tras un logout explícito arranca en el login (aunque la credencial
    /// siga guardada para re-login offline).
    func restore() {
        do {
            guard let session = try store.read(), !session.loggedOut else {
                state = .signedOut
                return
            }
            if isOfflineExpired(session) {
                // Caducó la ventana offline: se exige login online. Los datos y pedidos
                // locales NO se tocan.
                loginFailure = .offlineExpired
                errorMessage = "Tu sesión offline expiró. Conéctate para continuar."
                state = .signedOut
                AppLog.auth.warning("sesión offline caducada (>7 días sin login online)")
            } else {
                displayName = session.displayName
                username = session.username
                state = .signedIn
            }
        } catch {
            state = .signedOut
        }
    }

    /// Inicia sesión. `isOnline` decide la estrategia y el mensaje de error.
    func login(username: String, password: String, isOnline: Bool) async {
        errorMessage = nil
        loginFailure = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        guard isOnline else {
            tryOfflineLogin(username: username, password: password, serverUnreachable: false)
            return
        }

        do {
            let response = try await api.login(username: username, password: password)
            // Rol equivocado: credenciales válidas pero esta app es solo para BODEGUERO.
            if let required = requiredRole, response.role != required {
                loginFailure = .wrongRole
                errorMessage = "Esta app es para drivers. Tu usuario no tiene ese rol."
                AppLog.auth.warning("login: rol \(response.role ?? "nil", privacy: .public) ≠ \(required, privacy: .public)")
                return
            }
            let session = StoredSession(
                token: response.token,
                username: username,
                displayName: response.displayName,
                salespersonCode: response.salespersonCode,
                lastOnlineLoginAt: now(),
                passwordHash: try hasher.hash(password),
                loggedOut: false
            )
            try store.save(session)
            displayName = response.displayName
            self.username = username
            needsReauth = false
            state = .signedIn
            AppLog.auth.info("login exitoso")
            // Login ONLINE: el vendedor pudo cambiar → resetea marcas para bajar el set
            // completo y reconciliarlo en el próximo sync.
            onOnlineLogin()
        } catch APIError.unauthorized {
            // El servidor respondió que las credenciales son inválidas: NO caer a offline.
            loginFailure = .badCredentials
            errorMessage = "Usuario o contraseña incorrectos."
            AppLog.auth.warning("login: credenciales inválidas")
        } catch APIError.server(let status, _) {
            // El servidor es alcanzable pero erró: tampoco caemos a offline.
            loginFailure = .serverError
            errorMessage = "El servidor no responde (\(status)). Intenta más tarde."
            AppLog.auth.error("login: server \(status, privacy: .public)")
        } catch {
            // No se pudo ALCANZAR el servidor (timeout, red caída, URL faltante) → se
            // intenta la verificación OFFLINE con el hash guardado.
            AppLog.auth.warning("login: servidor inalcanzable → intento offline")
            tryOfflineLogin(username: username, password: password, serverUnreachable: true)
        }
    }

    /// Verifica la contraseña contra el hash guardado en el dispositivo y entra offline.
    /// Se usa tanto sin red como cuando el login online no pudo alcanzar el servidor
    /// (`serverUnreachable`), que solo cambia el mensaje si no hay credencial.
    private func tryOfflineLogin(username: String, password: String, serverUnreachable: Bool) {
        guard let cred = try? store.read() else {
            loginFailure = serverUnreachable ? .connectionError : .offlineNoSession
            errorMessage = serverUnreachable
                ? "No se pudo conectar con el servidor. La primera vez necesitas conexión."
                : "Sin conexión. La primera vez necesitas conexión para iniciar sesión."
            AppLog.auth.warning("login offline sin credencial")
            return
        }
        guard !isOfflineExpired(cred) else {
            loginFailure = .offlineExpired
            errorMessage = "Tu sesión offline expiró. Conéctate para continuar."
            AppLog.auth.warning("login offline rechazado: sesión caducada (>7 días)")
            return
        }
        guard cred.username == username, hasher.verify(password, cred.passwordHash) else {
            loginFailure = .badCredentials
            errorMessage = "Usuario o contraseña incorrectos."
            AppLog.auth.warning("login offline: credencial no coincide")
            return
        }
        // Reactiva la sesión guardada (mismo token; se validará al sincronizar online).
        var updated = cred
        updated.loggedOut = false
        try? store.save(updated)
        displayName = cred.displayName
        self.username = cred.username
        state = .signedIn
        AppLog.auth.info("login verificado offline con contraseña")
    }

    /// Se invoca al cerrar sesión (además de conservar la credencial). Se usa para LIMPIAR el
    /// snapshot de ruta → el siguiente login empieza limpio. Conserva la cola/pagos.
    var onLogout: () -> Void = {}

    /// Cierra sesión: la app vuelve al login, pero la credencial se conserva para poder
    /// re-loguearse OFFLINE con la contraseña (offline-first, decisión aprobada).
    func logout() {
        if var cred = try? store.read() {
            cred.loggedOut = true
            try? store.save(cred)
        }
        displayName = nil
        username = nil
        needsReauth = false
        loginFailure = nil
        state = .signedOut
        onLogout()
    }

    /// La sesión expiró (401 durante el sync). NO borra la sesión: el vendedor sigue
    /// trabajando offline. Solo marca que hace falta re-autenticarse para sincronizar.
    func sessionExpired() {
        AppLog.auth.warning("sesión expirada (401) — se mantiene el acceso offline")
        needsReauth = true
    }
}
