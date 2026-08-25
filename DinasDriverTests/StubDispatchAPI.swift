import Foundation
@testable import DinasDriver

/// Stub del `DispatchAPI` (+ `AuthAPI`). Sirve respuestas fijas, registra las llamadas y puede
/// simular OFFLINE (transitorio), 404 (sin camión) o rechazos permanentes.
final class StubDispatchAPI: AuthAPI, DispatchAPI, @unchecked Sendable {
    var loginResponse: LoginResponse?
    var loginError: Error?

    var route: RouteDownload?
    var offline = false
    var permanentError: APIError?          // p. ej. 400
    var summary: RouteSummary?

    private(set) var startRouteCalls = 0
    private(set) var deliverCalls: [(uuid: String, request: DeliverRequest)] = []
    private(set) var finishCalls = 0
    private(set) var returnCalls: [SubmitReturnRequest] = []
    private(set) var notCollectedCalls: [(requestUUID: String, request: PickupNotCollectedRequest)] = []
    private(set) var paymentCalls: [SubmitPaymentRequest] = []
    /// Intentos de submitPayment, contados ANTES de decidir online/offline/rechazo (para verificar
    /// el número EXACTO de reintentos, incluidos los que terminan en error).
    private(set) var submitPaymentAttempts = 0
    private(set) var voidCalls: [(uuid: String, request: VoidPaymentRequest)] = []

    private func guardOnline() throws {
        if offline { throw URLError(.notConnectedToInternet) }
        if let e = permanentError { throw e }
    }

    // MARK: Auth
    func login(username: String, password: String) async throws -> LoginResponse {
        if let e = loginError { throw e }
        return loginResponse ?? LoginResponse(token: "T", role: "DRIVER",
                                              salespersonCode: nil, displayName: "Driver")
    }

    // MARK: Dispatch
    func fetchMyRoute() async throws -> RouteDownload {
        if offline { throw URLError(.notConnectedToInternet) }
        guard let route else { throw APIError.server(status: 404, message: "Sin camión asignado") }
        return route
    }

    func startRoute() async throws -> RouteDownload {
        try guardOnline(); startRouteCalls += 1
        guard let route else { throw APIError.server(status: 404, message: nil) }
        return route
    }

    func deliver(orderUUID: String, request: DeliverRequest) async throws -> DeliveryRecord {
        try guardOnline()
        deliverCalls.append((orderUUID, request))
        // El servidor DERIVA el estado de lo que marcó el driver.
        let status: DeliveryStatus
        if request.orderReason != nil { status = .noEntregado }
        else if request.rejectedItems?.isEmpty == false { status = .entregadoParcial }
        else { status = .entregado }
        return DeliveryRecord(orderUUID: orderUUID, status: status)
    }

    func finishRoute() async throws -> RouteSummary {
        try guardOnline(); finishCalls += 1
        return summary ?? RouteSummary(truckID: route?.truckID ?? "T")
    }

    func submitReturn(_ request: SubmitReturnRequest) async throws -> ProductReturn {
        try guardOnline()
        returnCalls.append(request)
        return ProductReturn(returnID: "RET-\(returnCalls.count)")
    }

    func notCollectedPickup(requestUUID: String, request: PickupNotCollectedRequest) async throws -> PickupNotCollectedAck {
        try guardOnline()
        notCollectedCalls.append((requestUUID, request))
        return PickupNotCollectedAck()
    }

    func submitPayment(_ request: SubmitPaymentRequest) async throws -> PaymentAck {
        submitPaymentAttempts += 1
        try guardOnline()
        paymentCalls.append(request)
        return PaymentAck(paymentUUID: request.paymentUUID)
    }

    func voidPayment(paymentUUID: String, request: VoidPaymentRequest) async throws -> PaymentAck {
        try guardOnline()
        voidCalls.append((paymentUUID, request))
        return PaymentAck(paymentUUID: paymentUUID)
    }

    // ── Custodia del dinero (Dr2) ──
    var myCash = DriverCash(totalAmount: 0, payments: [])
    /// Si no es nil, `declareHandover`/`undoHandover` lanzan este error (p. ej. 409).
    var handoverError: APIError?
    private(set) var declareCalls: [String] = []
    private(set) var undoCalls: [String] = []

    func fetchMyCash() async throws -> DriverCash {
        try guardOnline(); return myCash
    }
    func declareHandover(paymentUUID: String) async throws -> RemotePayment {
        try guardOnline()
        if let e = handoverError { throw e }
        declareCalls.append(paymentUUID)
        return myCash.payments.first { $0.paymentUUID == paymentUUID }
            ?? RemotePayment(paymentUUID: paymentUUID, clientCode: "C", amount: 0,
                             occurredAt: Date(timeIntervalSince1970: 0),
                             recordedAt: Date(timeIntervalSince1970: 0),
                             handedOverAt: Date(timeIntervalSince1970: 1))
    }
    func undoHandover(paymentUUID: String) async throws -> RemotePayment {
        try guardOnline()
        if let e = handoverError { throw e }
        undoCalls.append(paymentUUID)
        return RemotePayment(paymentUUID: paymentUUID, clientCode: "C", amount: 0,
                             occurredAt: Date(timeIntervalSince1970: 0),
                             recordedAt: Date(timeIntervalSince1970: 0),
                             handedOverAt: nil, handoverUndoneCount: 1)
    }

    // ── Historial de rutas (Dr4/Dr5) ──
    var closedRoutes = ClosedRoutesPage(page: 1, pageSize: 25, total: 0, routes: [])
    var routeDetail: RouteSummary?
    func fetchClosedRoutes(page: Int) async throws -> ClosedRoutesPage {
        try guardOnline(); return closedRoutes
    }
    func fetchRouteDetail(truckID: String) async throws -> RouteSummary {
        try guardOnline()
        guard let d = routeDetail else { throw APIError.server(status: 404, message: "no existe") }
        return d
    }
}
