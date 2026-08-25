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
    /// `POST /dispatch/returns`. Registra un retorno de producto (foto base64 en el JSON). 201.
    /// También registra una RECOGIDA cuando el body trae `pickup_for_request_uuid` (★ v0.45.0).
    func submitReturn(_ request: SubmitReturnRequest) async throws -> ProductReturn
    /// `POST /dispatch/pickups/{request_uuid}/not-collected` (★ v0.45.0). Declara que una recogida
    /// no se pudo hacer. Idempotente. `occurred_at` = hora de la visita.
    func notCollectedPickup(requestUUID: String, request: PickupNotCollectedRequest) async throws -> PickupNotCollectedAck
    /// `POST /dispatch/payments`. Registra un pago (idempotente por payment_uuid). 201/200.
    func submitPayment(_ request: SubmitPaymentRequest) async throws -> PaymentAck
    /// `POST /dispatch/payments/{uuid}/void`. Anula un pago con motivo. Idempotente. 200.
    func voidPayment(paymentUUID: String, request: VoidPaymentRequest) async throws -> PaymentAck

    // ── Custodia del dinero (Dr2, ★ v0.80.0) ──
    /// `GET /dispatch/my-cash`. Lo que el driver tiene SIN declarar entregado (cruza rutas).
    func fetchMyCash() async throws -> DriverCash
    /// `POST /dispatch/payments/{uuid}/handover`. Declara que el dinero se entregó en bodega
    /// (pone `handed_over_at` con hora del servidor). Idempotente → 200. 409 si el pago está anulado.
    func declareHandover(paymentUUID: String) async throws -> RemotePayment
    /// `DELETE /dispatch/payments/{uuid}/handover`. Deshace la declaración (suma al conteo, con hora).
    /// NO idempotente en el conteo. 409 si ya está en un depósito, o si no estaba declarado.
    func undoHandover(paymentUUID: String) async throws -> RemotePayment

    // ── Historial de rutas (Dr4/Dr5, ★ v0.69.0) ──
    /// `GET /dispatch/routes`. Rutas que este driver ya cerró (paginado). Solo jornadas terminadas.
    func fetchClosedRoutes(page: Int) async throws -> ClosedRoutesPage
    /// `GET /dispatch/routes/{truck_id}`. El MISMO `RouteSummary` que el cierre. 404 si no es suya.
    func fetchRouteDetail(truckID: String) async throws -> RouteSummary
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

    func fetchClosedRoutes(page: Int) async throws -> ClosedRoutesPage {
        let request = try makeRequest(path: "dispatch/routes", method: "GET",
                                      query: [URLQueryItem(name: "page", value: String(page))])
        return try await send(request, decode: ClosedRoutesPage.self)
    }

    func fetchRouteDetail(truckID: String) async throws -> RouteSummary {
        let request = try makeRequest(path: "dispatch/routes/\(truckID)", method: "GET")
        return try await send(request, decode: RouteSummary.self)
    }

    func submitReturn(_ body: SubmitReturnRequest) async throws -> ProductReturn {
        let data = try JSONCoding.encoder.encode(body)
        let request = try makeRequest(path: "dispatch/returns", method: "POST", body: data)
        return try await send(request, decode: ProductReturn.self)
    }

    func notCollectedPickup(requestUUID: String, request body: PickupNotCollectedRequest) async throws -> PickupNotCollectedAck {
        let data = try JSONCoding.encoder.encode(body)
        let request = try makeRequest(path: "dispatch/pickups/\(requestUUID)/not-collected",
                                      method: "POST", body: data)
        return try await send(request, decode: PickupNotCollectedAck.self)
    }

    func submitPayment(_ body: SubmitPaymentRequest) async throws -> PaymentAck {
        let data = try JSONCoding.encoder.encode(body)
        let request = try makeRequest(path: "dispatch/payments", method: "POST", body: data)
        return try await send(request, decode: PaymentAck.self)
    }

    func voidPayment(paymentUUID: String, request body: VoidPaymentRequest) async throws -> PaymentAck {
        let data = try JSONCoding.encoder.encode(body)
        let request = try makeRequest(path: "dispatch/payments/\(paymentUUID)/void", method: "POST", body: data)
        return try await send(request, decode: PaymentAck.self)
    }

    // MARK: - Custodia del dinero (Dr2)

    func fetchMyCash() async throws -> DriverCash {
        let request = try makeRequest(path: "dispatch/my-cash", method: "GET")
        return try await send(request, decode: DriverCash.self)
    }

    func declareHandover(paymentUUID: String) async throws -> RemotePayment {
        let request = try makeRequest(path: "dispatch/payments/\(paymentUUID)/handover", method: "POST")
        return try await send(request, decode: RemotePayment.self)
    }

    func undoHandover(paymentUUID: String) async throws -> RemotePayment {
        let request = try makeRequest(path: "dispatch/payments/\(paymentUUID)/handover", method: "DELETE")
        return try await send(request, decode: RemotePayment.self)
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

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = [],
                             body: Data? = nil, authenticated: Bool = true) throws -> URLRequest {
        guard let baseURL else { throw APIError.missingBaseURL }
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
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
