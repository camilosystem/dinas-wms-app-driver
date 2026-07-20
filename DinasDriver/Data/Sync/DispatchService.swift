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

    init(database: AppDatabase, api: DispatchAPI,
         now: @escaping () -> Date = Date.init,
         onUnauthorized: @escaping () -> Void = {}) {
        self.repo = DriverRepository(database: database, now: now)
        self.api = api
        self.now = now
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
        }
    }

    private func refreshPending() {
        pendingCount = (try? repo.pendingCount()) ?? 0
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
