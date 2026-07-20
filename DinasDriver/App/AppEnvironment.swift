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

    init() {
        // Base local. Si falla la apertura, es irrecuperable: la app offline-first no
        // puede operar sin su base.
        let database: AppDatabase
        do {
            database = try AppDatabase.makeShared()
        } catch {
            fatalError("No se pudo abrir la base local: \(error)")
        }
        self.database = database

        // La sesión (con el JWT) vive en el Keychain. El cliente HTTP toma el token de ahí.
        let sessionStore = KeychainSessionStore()
        let api = APIClient(
            baseURL: AppConfig.middlewareBaseURL,
            tokenProvider: { try? sessionStore.read()?.token }
        )
        self.api = api

        // Esta app es SOLO para DRIVER: el login rechaza cualquier otro rol.
        let auth = AuthSession(api: api, store: sessionStore, requiredRole: "DRIVER")
        self.auth = auth

        // Servicio de despacho. Un 401 al sincronizar expira la sesión → vuelve al login.
        self.dispatch = DispatchService(database: database, api: api,
                                        onUnauthorized: { auth.sessionExpired() })

        // Conectividad re-evaluada activamente (sondea el middleware, se recupera sola o con
        // el botón "Reintentar"). Al volver la red, reintenta enviar lo pendiente del despacho.
        let dispatch = self.dispatch
        self.network = NetworkMonitor(
            probe: { await api.checkReachability() },
            onReconnect: { [weak dispatch] in Task { await dispatch?.syncPending() } }
        )
    }
}
