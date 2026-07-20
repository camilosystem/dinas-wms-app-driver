import Foundation

/// Contenedor de dependencias de la app de DRIVER (composición raíz).
///
/// Mantiene vivas las piezas de larga duración: base local, cliente HTTP, sesión, servicio de
/// despacho y monitor de conectividad. Se inyecta por el árbol de vistas como `EnvironmentObject`.
@MainActor
final class AppEnvironment: ObservableObject {
    let database: AppDatabase
    let api: APIClient
    let dispatch: DispatchService
    let auth: AuthSession
    let network: NetworkMonitor

    /// Usuario cuyo archivo de base está abierto ahora (para detectar el cambio de usuario).
    private var currentDBUser: String?

    init() {
        // La sesión (con el JWT) vive en el Keychain. El cliente HTTP toma el token de ahí.
        let sessionStore = KeychainSessionStore()

        // ★ Aislamiento por usuario: se abre el archivo del usuario YA guardado (si reabrimos la
        // app con sesión). Cada driver tiene su propio archivo → nunca ve la ruta de otro.
        let initialUser = (try? sessionStore.read())?.username
        let database: AppDatabase
        do {
            database = try AppDatabase.makeForUser(initialUser)
        } catch {
            fatalError("No se pudo abrir la base local: \(error)")
        }
        self.database = database
        self.currentDBUser = initialUser

        let api = APIClient(
            baseURL: AppConfig.middlewareBaseURL,
            tokenProvider: { try? sessionStore.read()?.token }
        )
        self.api = api

        // Esta app es SOLO para DRIVER: el login rechaza cualquier otro rol.
        let auth = AuthSession(api: api, store: sessionStore, requiredRole: "DRIVER")
        self.auth = auth

        // Servicio de despacho. Un 401 al sincronizar expira la sesión → vuelve al login.
        let dispatch = DispatchService(database: database, api: api,
                                       onUnauthorized: { auth.sessionExpired() })
        self.dispatch = dispatch

        // Conectividad re-evaluada activamente (sondea el middleware, se recupera sola o con
        // el botón "Reintentar"). Al volver la red, reintenta enviar lo pendiente del despacho.
        self.network = NetworkMonitor(
            probe: { await api.checkReachability() },
            onReconnect: { [weak dispatch] in Task { await dispatch?.syncPending() } }
        )

        // Al hacer login ONLINE de OTRO usuario, apunta la base a SU archivo (el login offline
        // solo reactiva al MISMO usuario). Aislamiento estructural; este hook solo hace el
        // cambio en caliente.
        auth.onOnlineLogin = { [weak self, weak dispatch] in
            guard let self else { return }
            let user = (try? sessionStore.read())?.username
            guard user != self.currentDBUser else { return }
            self.currentDBUser = user
            if let db = try? AppDatabase.makeForUser(user) {
                dispatch?.useDatabase(db)
            }
        }
    }
}
