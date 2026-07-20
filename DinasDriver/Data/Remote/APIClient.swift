import Foundation
import os

// Los clientes de red se invocan con `await` desde el @MainActor y corren en el ejecutor
// genérico: deben ser `Sendable` para cruzar ese límite sin riesgo de carrera.

/// Superficie de autenticación (login público, sin token).
protocol AuthAPI: Sendable {
    /// `POST /auth/login`. Lanza `APIError.unauthorized` en 401.
    func login(username: String, password: String) async throws -> LoginResponse
}

/// Superficie del DESPACHO (driver, requiere token DRIVER). Contrato v0.14.0.
protocol DispatchAPI: Sendable {
    /// `GET /dispatch/my-route`. TODO para trabajar offline. 404 → sin camión asignado.
    func fetchMyRoute() async throws -> RouteDownload
    /// `POST /dispatch/start-route`. ASIGNADO_DRIVER → EN_RUTA. Idempotente.
    func startRoute() async throws -> RouteDownload
    /// `POST /dispatch/orders/{uuid}/deliver`. Idempotente por pedido. `occurred_at` = hora
    /// real en la calle.
    func deliver(orderUUID: String, request: DeliverRequest) async throws -> DeliveryRecord
    /// `POST /dispatch/finish-route`. EN_RUTA → RUTA_CERRADA. Devuelve el resumen.
    func finishRoute() async throws -> RouteSummary
}

/// Cliente HTTP contra el middleware, según `contracts/openapi.yaml` (v0.14.0).
///
/// El JWT se inyecta vía `tokenProvider` y se añade como `Authorization: Bearer` en todos los
/// endpoints salvo `login` (público). Si falta un campo/endpoint en el contrato, no se inventa:
/// se eleva al Arquitecto.
struct APIClient: AuthAPI, DispatchAPI {
    /// URL base del middleware (incluye el path base `/v1`). Ver `AppConfig`.
    var baseURL: URL?
    var session: URLSession
    /// Provee el JWT actual (desde Keychain). `nil` cuando no hay sesión.
    var tokenProvider: @Sendable () -> String?

    init(baseURL: URL? = nil,
         session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () -> String? = { nil }) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws -> LoginResponse {
        let body = try JSONCoding.encoder.encode(LoginRequest(username: username, password: password))
        let request = try makeRequest(path: "auth/login", method: "POST",
                                      body: body, authenticated: false)
        return try await send(request, decode: LoginResponse.self)
    }

    // MARK: - Despacho

    func fetchMyRoute() async throws -> RouteDownload {
        let request = try makeRequest(path: "dispatch/my-route", method: "GET")
        return try await send(request, decode: RouteDownload.self)
    }

    func startRoute() async throws -> RouteDownload {
        let request = try makeRequest(path: "dispatch/start-route", method: "POST")
        return try await send(request, decode: RouteDownload.self)
    }

    func deliver(orderUUID: String, request body: DeliverRequest) async throws -> DeliveryRecord {
        let data = try JSONCoding.encoder.encode(body)
        let request = try makeRequest(path: "dispatch/orders/\(orderUUID)/deliver",
                                      method: "POST", body: data)
        return try await send(request, decode: DeliveryRecord.self)
    }

    func finishRoute() async throws -> RouteSummary {
        let request = try makeRequest(path: "dispatch/finish-route", method: "POST")
        return try await send(request, decode: RouteSummary.self)
    }

    // MARK: - Alcanzabilidad

    /// Sondeo ligero: ¿responde el middleware? Cualquier respuesta HTTP (incluido 401/404)
    /// cuenta como ALCANZABLE; solo un error de TRANSPORTE significa inalcanzable.
    func checkReachability() async -> Bool {
        guard let baseURL else { return false }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Infra HTTP

    private func makeRequest(path: String, method: String,
                             body: Data? = nil, authenticated: Bool = true) throws -> URLRequest {
        guard let baseURL else { throw APIError.missingBaseURL }
        guard let url = URLComponents(url: baseURL.appendingPathComponent(path),
                                      resolvingAgainstBaseURL: false)?.url else {
            throw APIError.missingBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Timeout corto: si el middleware no responde, fallar rápido (caer a offline).
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token = tokenProvider() else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: -1, message: nil)
        }
        // Método + path + estado. Sin body ni cabeceras (evita loguear el token).
        AppLog.api.debug("\(request.httpMethod ?? "?", privacy: .public) \(request.url?.path ?? "?", privacy: .public) → \(http.statusCode, privacy: .public)")
        switch http.statusCode {
        case 200..<300:
            return try JSONCoding.decoder.decode(T.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            let message = (try? JSONCoding.decoder.decode(ErrorBody.self, from: data))?.message
            throw APIError.server(status: http.statusCode, message: message)
        }
    }
}

/// Cuerpo de error del contrato (`Error { code, message }`).
private struct ErrorBody: Decodable {
    let code: String?
    let message: String?
}

enum APIError: Error, Equatable {
    case notImplemented
    case missingBaseURL
    case unauthorized
    case server(status: Int, message: String?)

    /// Error PERMANENTE: reintentar no ayuda (validación/no encontrado). 4xx salvo 401.
    var isPermanent: Bool {
        if case let .server(status, _) = self { return (400..<500).contains(status) }
        return false
    }

    var serverMessage: String? {
        if case let .server(_, message) = self { return message }
        return nil
    }

    var serverStatus: Int {
        if case let .server(status, _) = self { return status }
        return 0
    }
}
