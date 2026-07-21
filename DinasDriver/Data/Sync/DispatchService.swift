import Foundation

/// Estado de la descarga de la ruta (gobierna el aviso de "Mi ruta").
enum RouteDownloadState: Equatable {
    case notDownloaded    // sin snapshot local → AVISO: descarga antes de salir
    case noRouteAssigned  // el servidor respondió 404 → "no tienes ruta asignada"
    case downloaded       // snapshot local presente → trabaja offline
}

/// Estado de entrega a MOSTRAR de un pedido (reflejo, no cálculo de negocio).
/// `isPending` = registrado localmente pero aún sin confirmar por el servidor.
struct DeliveryDisplay: Equatable {
    var status: DeliveryStatus?
    var isPending: Bool
    static let none = DeliveryDisplay(status: nil, isPending: false)
}

/// Resumen LOCAL de la ruta (offline), derivado de lo REGISTRADO. Se reconcilia con el
/// `RouteSummary` del servidor al sincronizar.
struct LocalRouteSummary: Equatable {
    var deliveredCount = 0
    var partialCount = 0
    var notDeliveredCount = 0
    var pendingCount = 0            // pedidos sin registrar
    var unsyncedDelivers = 0        // registrados pero aún en cola (≠ confirmados)
    var returnedItems: [ReturnedItem] = []
}

/// Motor de despacho offline-first. Leer = snapshot local + overlay de la cola; registrar =
/// encolar OPTIMISTA (`occurred_at` = hora de la calle) + replay idempotente. Nada bloquea
/// esperando al servidor.
@MainActor
final class DispatchService: ObservableObject {
    @Published private(set) var downloadState: RouteDownloadState = .notDownloaded
    @Published private(set) var pendingCount = 0
    @Published private(set) var isSyncing = false
    @Published var loadError: String?
    /// El resumen del servidor tras cerrar (si llegó). Si no, se usa el local.
    @Published private(set) var serverSummary: RouteSummary?

    private(set) var repo: DriverRepository
    private let api: DispatchAPI
    private let onUnauthorized: () -> Void
    private let now: () -> Date
    let photos: PhotoStore

    init(database: AppDatabase, api: DispatchAPI,
         now: @escaping () -> Date = Date.init,
         photos: PhotoStore = PhotoStore(),
         onUnauthorized: @escaping () -> Void = {}) {
        self.repo = DriverRepository(database: database, now: now)
        self.api = api
        self.now = now
        self.photos = photos
        self.onUnauthorized = onUnauthorized
        downloadState = ((try? repo.hasRoute()) == true) ? .downloaded : .notDownloaded
        refreshPending()
    }

    /// Cambia a la base de OTRO usuario (★ aislamiento por usuario). Reapunta el repo al archivo
    /// del usuario nuevo y LIMPIA el estado en memoria: nada de la ruta del anterior queda
    /// visible. Estructural — un driver nunca ve la ruta de otro (ni entrega en su dirección).
    func useDatabase(_ database: AppDatabase) {
        repo = DriverRepository(database: database, now: now)
        serverSummary = nil
        loadError = nil
        downloadState = ((try? repo.hasRoute()) == true) ? .downloaded : .notDownloaded
        refreshPending()
    }

    // MARK: - Descarga

    /// Descarga la ruta y la guarda local. Requiere red. 404 → sin camión asignado.
    func downloadRoute() async {
        loadError = nil
        do {
            let route = try await api.fetchMyRoute()
            try repo.saveRoute(route)
            downloadState = .downloaded
        } catch APIError.unauthorized {
            onUnauthorized()
        } catch let e as APIError where e.serverStatus == 404 {
            downloadState = ((try? repo.hasRoute()) == true) ? .downloaded : .noRouteAssigned
        } catch {
            // Sin red: si ya había snapshot, se sigue trabajando; si no, queda el aviso.
            if (try? repo.hasRoute()) == true {
                downloadState = .downloaded
            } else {
                loadError = "No se pudo descargar la ruta. Conéctate e inténtalo de nuevo."
            }
        }
    }

    // MARK: - Acciones (encolan optimista, nunca bloquean)

    func startRoute(truckID: String) {
        try? repo.markStartedLocally()
        try? repo.enqueueStartRoute(truckID: truckID)
        refreshPending()
        Task { await syncPending() }
    }

    /// Registra la entrega de un pedido. `occurred_at` se captura AQUÍ (hora de la calle).
    func deliver(truckID: String, orderUUID: String,
                 orderReason: OrderRejectionReason? = nil,
                 rejectedItems: [RejectedItemInput]? = nil, note: String? = nil) {
        try? repo.enqueueDeliver(truckID: truckID, orderUUID: orderUUID,
                                 orderReason: orderReason, rejectedItems: rejectedItems,
                                 note: note, occurredAt: now())
        refreshPending()
        Task { await syncPending() }
    }

    func finishRoute(truckID: String) {
        try? repo.enqueueFinishRoute(truckID: truckID)
        refreshPending()
        Task { await syncPending() }
    }

    /// Redimensiona y guarda la foto de la cámara en disco; devuelve su RUTA (para el retorno).
    func savePhoto(_ imageData: Data) throws -> String {
        try photos.saveResized(from: imageData)
    }

    /// Registra un RETORNO de producto. El `return_uuid` se GENERA AQUÍ (al crear, no al enviar) y
    /// se guarda en la cola → el reintento manda el mismo y el servidor no duplica. `occurred_at`
    /// se captura aquí (hora de la visita). La foto ya está en disco; en la cola solo va su ruta.
    @discardableResult
    func registerReturn(truckID: String, clientCode: String, items: [ProductReturnItemInput],
                        note: String?, clientReference: String?, photoPath: String) -> String {
        let returnUUID = UUID().uuidString
        try? repo.enqueueReturn(truckID: truckID, returnUUID: returnUUID, clientCode: clientCode,
                                items: items, note: note, clientReference: clientReference,
                                photoPath: photoPath, occurredAt: now())
        refreshPending()
        Task { await syncPending() }
        return returnUUID
    }

    // MARK: - Pagos (★ v0.16.0)

    /// Registra un PAGO. El `payment_uuid` se GENERA AQUÍ (al crear, no al enviar) → el reintento
    /// manda el mismo y el servidor no duplica el dinero. Se guarda al instante como registro local
    /// durable (fuente de la caja) y se muestra hecho; el envío sincroniza sola. `occurred_at` = la
    /// hora real. `photoPath` (cheque) ya está en disco.
    @discardableResult
    func registerPayment(truckID: String, clientCode: String, clientName: String, amount: Double,
                         type: PaymentType, checkNumber: String?, note: String?,
                         photoPath: String?) -> String {
        let uuid = UUID().uuidString
        let payment = Payment(paymentUUID: uuid, truckID: truckID, clientCode: clientCode,
                              clientName: clientName, amount: amount, paymentType: type,
                              checkNumber: checkNumber, note: note, photoPath: photoPath,
                              occurredAt: now(), createdAt: now(), isVoided: false, voidReason: nil,
                              voidedAt: nil, createSynced: false, voidSynced: false)
        try? repo.insertPayment(payment)
        refreshPending()
        Task { await syncPending() }
        return uuid
    }

    /// Anula un pago con MOTIVO. Nada se borra: queda marcado como anulado. Se puede anular en
    /// cualquier momento (incluso ruta cerrada). Idempotente en el servidor.
    func voidPayment(paymentUUID: String, reason: String) {
        try? repo.voidPaymentLocally(paymentUUID: paymentUUID, reason: reason, at: now())
        refreshPending()
        Task { await syncPending() }
    }

    // MARK: - Sincronización (replay idempotente)

    func syncPending() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let actions = (try? repo.pendingActions()) ?? []
        for action in actions {
            guard let id = action.id else { continue }
            do {
                try await send(action)
                try? repo.deleteAction(id: id)
            } catch APIError.unauthorized {
                onUnauthorized()
                break
            } catch let error as APIError where error.isPermanent {
                let reason = error.serverMessage ?? "Rechazado por el servidor (\(error.serverStatus))."
                try? repo.markActionFailed(id: id, error: reason)
                AppLog.api.error("acción \(id, privacy: .public) RECHAZADA (\(error.serverStatus, privacy: .public))")
            } catch {
                // Transitorio: detener; el resto sigue en cola y se reintenta al reconectar.
                break
            }
        }

        // ★ Pagos (dinero → máxima robustez). El registro local NO se pierde: se sincroniza crear
        // (idempotente por payment_uuid, borra la foto del cheque al lograrlo) y anular (idempotente).
        for payment in (try? repo.paymentsNeedingSync()) ?? [] {
            do {
                if !payment.createSynced {
                    var base64: String?
                    if payment.paymentType == .cheque, let path = payment.photoPath {
                        guard FileManager.default.fileExists(atPath: path) else {
                            throw APIError.server(status: 400, message: "Falta la foto del cheque.")
                        }
                        base64 = try photos.base64(atPath: path)
                    }
                    let req = SubmitPaymentRequest(
                        paymentUUID: payment.paymentUUID, clientCode: payment.clientCode,
                        amount: payment.amount, paymentType: payment.paymentType,
                        checkNumber: payment.checkNumber, photoBase64: base64,
                        note: payment.note, occurredAt: payment.occurredAt)
                    _ = try await api.submitPayment(req)
                    try? repo.markPaymentCreateSynced(paymentUUID: payment.paymentUUID)
                    if let path = payment.photoPath { photos.delete(atPath: path) }
                }
                if payment.isVoided && !payment.voidSynced {
                    let req = VoidPaymentRequest(reason: payment.voidReason ?? "",
                                                 occurredAt: payment.voidedAt ?? now())
                    _ = try await api.voidPayment(paymentUUID: payment.paymentUUID, request: req)
                    try? repo.markPaymentVoidSynced(paymentUUID: payment.paymentUUID)
                }
            } catch APIError.unauthorized {
                onUnauthorized(); break
            } catch let error as APIError where error.isPermanent {
                // Permanente (400): NO se descarta un pago (es dinero). Queda visible como
                // pendiente para que se note y se corrija; se salta al siguiente.
                AppLog.api.error("pago \(payment.paymentUUID, privacy: .public) RECHAZADO: \(error.serverMessage ?? "", privacy: .public)")
                continue
            } catch {
                break   // transitorio: reintenta luego
            }
        }
        refreshPending()
    }

    private func send(_ action: PendingAction) async throws {
        switch action.kind {
        case .startRoute:
            _ = try await api.startRoute()
        case .deliver:
            let lines = action.rejectedItems?.map {
                DeliverRequest.Line(itemCode: $0.itemCode, quantity: $0.quantity, reason: $0.reason)
            }
            let request = DeliverRequest(orderReason: action.orderReason, rejectedItems: lines,
                                         note: action.note, occurredAt: action.occurredAt)
            let record = try await api.deliver(orderUUID: action.orderUUID ?? "", request: request)
            try? repo.applyDeliveryRecord(record)   // pliega el estado autoritativo
        case .finishRoute:
            let summary = try await api.finishRoute()
            serverSummary = summary
        case .productReturn:
            guard let path = action.photoPath, let clientCode = action.clientCode,
                  let items = action.returnItems, !items.isEmpty,
                  let returnUUID = action.returnUUID else {
                throw APIError.server(status: 400, message: "Retorno incompleto.")   // permanente → FAILED
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw APIError.server(status: 400, message: "La foto del retorno ya no está en el teléfono.")
            }
            let base64 = try photos.base64(atPath: path)
            // ★ Mismo return_uuid en cada reintento (viene de la cola) → idempotente.
            let request = SubmitReturnRequest(
                returnUUID: returnUUID, clientCode: clientCode,
                items: items.map { .init(itemCode: $0.itemCode, quantity: $0.quantity, reason: $0.reason) },
                photoBase64: base64, note: action.note, occurredAt: action.occurredAt,
                clientReference: action.clientReference)
            _ = try await api.submitReturn(request)
            photos.delete(atPath: path)   // ★ borra la foto del teléfono al sincronizar
        }
    }

    private func refreshPending() {
        let actions = (try? repo.pendingCount()) ?? 0
        let payments = (try? repo.pendingPaymentsCount()) ?? 0   // ★ el dinero cuenta aquí
        pendingCount = actions + payments
    }

    // MARK: - Derivaciones (reflejo de lo registrado; el estado real lo deriva el server)

    /// Estado provisional a partir de lo que MARCÓ el driver (no decide negocio).
    static func provisionalStatus(_ a: PendingAction) -> DeliveryStatus {
        if a.orderReason != nil { return .noEntregado }
        if let r = a.rejectedItems, !r.isEmpty { return .entregadoParcial }
        return .entregado
    }

    /// Qué mostrar para un pedido: si hay un `deliver` en cola → provisional + pendiente; si no,
    /// el estado del servidor (ya plegado); si no, nada registrado.
    static func display(order: DriverOrder, pending: PendingAction?) -> DeliveryDisplay {
        if let pending {
            return DeliveryDisplay(status: provisionalStatus(pending), isPending: true)
        }
        return DeliveryDisplay(status: order.deliveryStatus, isPending: false)
    }

    /// Retornados LOCALES derivados de la cola: los ítems rechazados de las entregas parciales
    /// y, en un "no se entregó", todas las líneas del pedido (nada se recibió → todo vuelve).
    static func localReturnedItems(orders: [DriverOrder], stops: [DriverStop],
                                   pendingDelivers: [PendingAction]) -> [ReturnedItem] {
        let orderByUUID = Dictionary(orders.map { ($0.orderUUID.lowercased(), $0) },
                                     uniquingKeysWith: { a, _ in a })
        let clientByCode = Dictionary(stops.map { ($0.clientCode.lowercased(), $0.clientName) },
                                      uniquingKeysWith: { a, _ in a })
        var result: [ReturnedItem] = []
        for a in pendingDelivers {
            guard let uuid = a.orderUUID?.lowercased(), let order = orderByUUID[uuid] else { continue }
            let client = clientByCode[order.clientCode.lowercased()] ?? ""
            if let items = a.rejectedItems, !items.isEmpty {
                for it in items {
                    result.append(ReturnedItem(itemCode: it.itemCode,
                                               itemName: it.itemName ?? it.itemCode,
                                               quantity: it.quantity, reason: it.reason,
                                               orderNumber: order.orderNumber, clientName: client))
                }
            } else if a.orderReason != nil {
                for line in order.lines {
                    result.append(ReturnedItem(itemCode: line.itemCode, itemName: line.itemName,
                                               quantity: line.quantity, reason: nil,
                                               orderNumber: order.orderNumber, clientName: client))
                }
            }
        }
        return result
    }

    /// Resumen LOCAL para "Terminar ruta" sin red. Distingue registrado (en cola) de confirmado.
    static func localSummary(orders: [DriverOrder], stops: [DriverStop],
                             pendingDelivers: [PendingAction]) -> LocalRouteSummary {
        let pendingByOrder = Dictionary(pendingDelivers.compactMap { a in
            a.orderUUID.map { ($0.lowercased(), a) }
        }, uniquingKeysWith: { a, _ in a })
        var s = LocalRouteSummary()
        for order in orders {
            let d = display(order: order, pending: pendingByOrder[order.orderUUID.lowercased()])
            switch d.status {
            case .entregado: s.deliveredCount += 1
            case .entregadoParcial: s.partialCount += 1
            case .noEntregado: s.notDeliveredCount += 1
            case .pendiente, .none: s.pendingCount += 1
            }
            if d.isPending { s.unsyncedDelivers += 1 }
        }
        s.returnedItems = localReturnedItems(orders: orders, stops: stops,
                                             pendingDelivers: pendingDelivers)
        return s
    }
}
