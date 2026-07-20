import Foundation

/// Configuración de la app por entorno.
///
/// La URL del middleware se lee de la clave `MIDDLEWARE_BASE_URL` del Info.plist
/// (inyectada por build settings / xcconfig por ambiente: dev, staging, prod).
/// Mientras no esté configurada, `middlewareBaseURL` es `nil` y las llamadas de red
/// fallan con un error claro (`APIError.missingBaseURL`).
enum AppConfig {
    static var middlewareBaseURL: URL? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "MIDDLEWARE_BASE_URL") as? String,
            !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }
}
