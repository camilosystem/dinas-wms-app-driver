import Foundation
import GRDB

/// Persistencia local del DESPACHO (★ v0.14.0). Offline-first: la descarga (`RouteDownload`)
/// se descompone y guarda como snapshot; lo que registra el driver va a la cola
/// (`pending_actions`) y se aplica OPTIMISTA. `truck_id`/`order_uuid` vienen del servidor
/// (.NET → GUID minúsculas) → las comparaciones usan NOCASE.
struct DriverRepository {
    let database: AppDatabase
    var now: () -> Date = Date.init

    // MARK: - Snapshot de la ruta

    /// Guarda la descarga: REEMPLAZA el snapshot (paradas + pedidos) y actualiza la cabecera.
    /// CONSERVA `pending_actions` (lo no sincronizado) y el reorden local del mismo camión.
    func saveRoute(_ download: RouteDownload) throws {
        try database.dbQueue.write { db in
            try DriverOrder.deleteAll(db)
            try DriverStop.deleteAll(db)
            try DriverPickup.deleteAll(db)
            try RouteHeader.deleteAll(db)
            // El reorden local es del camión: si cambió de camión, ya no aplica.
            try LocalStopOrder
                .filter(Column("truck_id").collating(.nocase) != download.truckID).deleteAll(db)

            let header = RouteHeader(
                truckID: download.truckID, truckName: download.truckName, status: download.status,
                downloadedAt: download.downloadedAt ?? now(), startedAt: download.startedAt,
                totalStops: download.totalStops, totalOrders: download.totalOrders,
                pendingOrders: download.pendingOrders)
            try header.insert(db)

            for stop in download.stops {
                try DriverStop(truckID: download.truckID, stopNumber: stop.stopNumber,
                               clientCode: stop.clientCode, clientName: stop.clientName,
                               address: stop.address, city: stop.city, zipCode: stop.zipCode,
                               phone: stop.phone).insert(db)
                for o in stop.orders {
                    try DriverOrder(orderUUID: o.orderUUID, truckID: download.truckID,
                                    clientCode: stop.clientCode, orderNumber: o.orderNumber,
                                    totalAmount: o.totalAmount, totalUnits: o.totalUnits,
                                    palletLabels: o.palletLabels,
                                    isIncompleteDelivery: o.isIncompleteDelivery,
                                    deliveryStatus: o.deliveryStatus, lines: o.lines).insert(db)
                }
                // ★ v0.45.0 — recogidas de la parada. Una parada de pura recogida tiene orders vacío
                // y estas filas: se guardan igual para que la parada no quede "sin nada que hacer".
                for p in stop.pickups {
                    try DriverPickup(requestUUID: p.requestUUID, truckID: download.truckID,
                                     clientCode: stop.clientCode, reason: p.reason,
                                     pickupNote: p.pickupNote, pickupStatus: p.pickupStatus,
                                     expectedItems: p.expectedItems).insert(db)
                }
            }

            // ★ v0.15.0 — catálogo para buscar al registrar un retorno (offline).
            try CatalogItem.deleteAll(db)
            for item in download.itemCatalog { try item.insert(db) }
        }
    }

    /// Busca en el catálogo por código o nombre (offline). Vacío → primeros por nombre.
    func searchCatalog(_ query: String, limit: Int = 40) throws -> [CatalogItem] {
        try database.dbQueue.read { db in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                return try CatalogItem.order(Column("item_name")).limit(limit).fetchAll(db)
            }
            let like = "%\(q)%"
            return try CatalogItem
                .filter(Column("item_code").like(like) || Column("item_name").like(like))
                .order(Column("item_name")).limit(limit).fetchAll(db)
        }
    }

    /// ¿Es `clientCode` una parada de la ruta descargada? (el retorno solo a clientes de su ruta).
    func isClientOnRoute(_ clientCode: String) throws -> Bool {
        try database.dbQueue.read { db in
            try DriverStop.filter(Column("client_code").collating(.nocase) == clientCode).fetchCount(db) > 0
        }
    }

    func hasRoute() throws -> Bool {
        try database.dbQueue.read { try RouteHeader.fetchCount($0) > 0 }
    }

    func routeHeader() throws -> RouteHeader? {
        try database.dbQueue.read { try RouteHeader.fetchOne($0) }
    }

    /// ¿La ruta local está CERRADA (RUTA_CERRADA)? → conviene buscar una nueva.
    func routeIsClosed() throws -> Bool {
        try database.dbQueue.read { try RouteHeader.fetchOne($0)?.status == .rutaCerrada }
    }

    /// Borra el SNAPSHOT de ruta (cabecera, paradas, pedidos, catálogo, reorden local) para
    /// arrancar limpio (logout). ★ CONSERVA `pending_actions` y `payments`: nunca se descarta
    /// trabajo sin sincronizar — sobre todo el dinero.
    func clearRouteSnapshot() throws {
        try database.dbQueue.write { db in
            try DriverOrder.deleteAll(db)
            try DriverStop.deleteAll(db)
            try CatalogItem.deleteAll(db)
            try LocalStopOrder.deleteAll(db)
            try RouteHeader.deleteAll(db)
        }
    }

    /// Marca localmente que la ruta se inició (optimista; el `start` real va en la cola).
    func markStartedLocally() throws {
        try database.dbQueue.write { db in
            guard var header = try RouteHeader.fetchOne(db) else { return }
            if header.startedAt == nil { header.startedAt = now() }
            header.status = .enRuta
            try header.update(db)
        }
    }

    /// Marca la ruta CERRADA localmente (optimista al terminar) → la app sabe que debe buscar una
    /// nueva y ofrece "Actualizar ruta".
    func markFinishedLocally() throws {
        try database.dbQueue.write { db in
            guard var header = try RouteHeader.fetchOne(db) else { return }
            header.status = .rutaCerrada
            try header.update(db)
        }
    }

    /// Paradas en el ORDEN a mostrar: el reorden LOCAL del driver si existe, si no el del admin.
    func stops() throws -> [DriverStop] {
        try database.dbQueue.read { db in
            let stops = try DriverStop.fetchAll(db)
            let local = try LocalStopOrder.fetchAll(db)
            let index = Dictionary(local.map { ($0.clientCode.lowercased(), $0.localIndex) },
                                   uniquingKeysWith: { a, _ in a })
            return stops.sorted { a, b in
                let ia = index[a.clientCode.lowercased()]
                let ib = index[b.clientCode.lowercased()]
                switch (ia, ib) {
                case let (x?, y?): return x < y
                case (nil, nil): return a.stopNumber < b.stopNumber
                case (_?, nil): return true      // los reordenados van primero, en su orden
                case (nil, _?): return false
                }
            }
        }
    }

    func orders(forClient clientCode: String) throws -> [DriverOrder] {
        try database.dbQueue.read { db in
            try DriverOrder.filter(Column("client_code").collating(.nocase) == clientCode)
                .order(Column("order_number")).fetchAll(db)
        }
    }

    func order(uuid: String) throws -> DriverOrder? {
        try database.dbQueue.read { db in
            try DriverOrder.filter(Column("order_uuid").collating(.nocase) == uuid).fetchOne(db)
        }
    }

    /// Recogidas de una parada (★ v0.45.0).
    func pickups(forClient clientCode: String) throws -> [DriverPickup] {
        try database.dbQueue.read { db in
            try DriverPickup.filter(Column("client_code").collating(.nocase) == clientCode)
                .fetchAll(db)
        }
    }

    /// Todas las recogidas de la ruta (para contar por cliente en la lista).
    func allPickups() throws -> [DriverPickup] {
        try database.dbQueue.read { db in try DriverPickup.fetchAll(db) }
    }

    /// ¿Esta recogida está encolada y aún ESPERANDO (pending), sin esperar al servidor? Sin esto,
    /// offline el `pickup_status` descargado sigue diciendo EN_CAMION y el driver registraría dos
    /// veces. Cuenta solo PENDING: una acción RECHAZADA (`.failed`) NO cuenta → la marca se libera y
    /// la recogida se vuelve a ofrecer (ver `failedPickupAction` para mostrar el porqué).
    func pickupRegisteredLocally(requestUUID: String) throws -> Bool {
        try database.dbQueue.read { db in
            try PendingAction
                .filter(Column("pickup_for_request_uuid").collating(.nocase) == requestUUID
                        && Column("status") == PendingActionStatus.pending.rawValue)
                .fetchCount(db) > 0
        }
    }

    /// La última acción de esta recogida que el servidor RECHAZÓ de forma permanente (`.failed`). Su
    /// `errorMessage` es lo que el driver tiene que ver: el registro no llegó y por qué. `nil` si no
    /// hay rechazo (nunca se intentó, o está pendiente, o se resolvió).
    func failedPickupAction(requestUUID: String) throws -> PendingAction? {
        try database.dbQueue.read { db in
            try PendingAction
                .filter(Column("pickup_for_request_uuid").collating(.nocase) == requestUUID
                        && Column("status") == PendingActionStatus.failed.rawValue)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    /// Refleja localmente que la recogida se resolvió al sincronizar OK (RECOGIDA / NO_RECOGIDA),
    /// para NO re-ofrecerla entre el éxito y el próximo refresco de ruta (el `pickup_status`
    /// descargado sigue EN_CAMION hasta entonces). Optimista, igual que el reflejo del `deliver`.
    func markPickupResolvedLocally(requestUUID: String, status: String) throws {
        try database.dbQueue.write { db in
            guard var p = try DriverPickup.fetchOne(db, key: requestUUID) else { return }
            p.pickupStatus = status
            try p.update(db)
        }
    }

    func allOrders() throws -> [DriverOrder] {
        try database.dbQueue.read { try DriverOrder.order(Column("order_number")).fetchAll($0) }
    }

    // MARK: - Reorden local (device-only)

    /// Guarda el orden local de paradas (por client_code). NUNCA se sincroniza.
    func saveLocalOrder(truckID: String, clientCodes: [String]) throws {
        try database.dbQueue.write { db in
            try LocalStopOrder.filter(Column("truck_id").collating(.nocase) == truckID).deleteAll(db)
            for (i, code) in clientCodes.enumerated() {
                try LocalStopOrder(truckID: truckID, clientCode: code, localIndex: i).insert(db)
            }
        }
    }

    // MARK: - Cola (offline)

    /// Encola el inicio de ruta (idempotente por camión: reemplaza el pendiente previo).
    func enqueueStartRoute(truckID: String) throws {
        try enqueueSingleton(truckID: truckID, kind: .startRoute)
    }

    /// Encola el cierre de ruta (idempotente por camión).
    func enqueueFinishRoute(truckID: String) throws {
        try enqueueSingleton(truckID: truckID, kind: .finishRoute)
    }

    /// Encola un RETORNO de producto. `photoPath` = ruta al JPEG en disco (la foto NO va a la
    /// BD). `occurredAt` = hora real de la visita (verbatim al replay). Cada retorno es una
    /// acción distinta (no se deduplica: el servidor asigna un return_id por POST).
    func enqueueReturn(truckID: String, returnUUID: String, clientCode: String,
                       items: [ProductReturnItemInput], note: String?, clientReference: String?,
                       photoPath: String, occurredAt: Date,
                       pickupForRequestUUID: String? = nil) throws {
        try database.dbQueue.write { db in
            var a = PendingAction(id: nil, truckID: truckID, kind: .productReturn, orderUUID: nil,
                                  orderReason: nil, rejectedItems: nil, note: note,
                                  occurredAt: occurredAt, createdAt: now(), status: .pending,
                                  errorMessage: nil, clientCode: clientCode, returnItems: items,
                                  clientReference: clientReference, photoPath: photoPath,
                                  returnUUID: returnUUID, pickupForRequestUUID: pickupForRequestUUID)
            try a.insert(db)
        }
    }

    /// Encola "no se pudo recoger" (★ v0.45.0). Idempotente por `request_uuid`: reemplaza el
    /// pendiente previo, igual que el endpoint (reenviar actualiza motivo/nota). `occurredAt` = hora
    /// real de la visita.
    func enqueuePickupNotCollected(truckID: String, requestUUID: String,
                                   reason: PickupNotCollectedReason, note: String?,
                                   occurredAt: Date) throws {
        try database.dbQueue.write { db in
            try PendingAction
                .filter(Column("kind") == PendingActionKind.pickupNotCollected.rawValue
                        && Column("pickup_for_request_uuid").collating(.nocase) == requestUUID
                        && Column("status") == PendingActionStatus.pending.rawValue)
                .deleteAll(db)
            var a = PendingAction(id: nil, truckID: truckID, kind: .pickupNotCollected, orderUUID: nil,
                                  orderReason: nil, rejectedItems: nil, note: note,
                                  occurredAt: occurredAt, createdAt: now(), status: .pending,
                                  errorMessage: nil,
                                  pickupForRequestUUID: requestUUID,
                                  pickupNotCollectedReason: reason)
            try a.insert(db)
        }
    }

    private func enqueueSingleton(truckID: String, kind: PendingActionKind) throws {
        try database.dbQueue.write { db in
            try PendingAction
                .filter(Column("truck_id").collating(.nocase) == truckID
                        && Column("kind") == kind.rawValue
                        && Column("status") == PendingActionStatus.pending.rawValue)
                .deleteAll(db)
            var a = PendingAction(id: nil, truckID: truckID, kind: kind, orderUUID: nil,
                                  orderReason: nil, rejectedItems: nil, note: nil,
                                  occurredAt: now(), createdAt: now(), status: .pending,
                                  errorMessage: nil)
            try a.insert(db)
        }
    }

    /// Encola la entrega de un pedido. Idempotente por `order_uuid`: reemplaza el pendiente
    /// previo (la última marca manda). `occurredAt` = hora REAL de la calle (verbatim al replay).
    func enqueueDeliver(truckID: String, orderUUID: String,
                        orderReason: OrderRejectionReason?, rejectedItems: [RejectedItemInput]?,
                        note: String?, occurredAt: Date) throws {
        try database.dbQueue.write { db in
            try PendingAction
                .filter(Column("truck_id").collating(.nocase) == truckID
                        && Column("kind") == PendingActionKind.deliver.rawValue
                        && Column("order_uuid").collating(.nocase) == orderUUID
                        && Column("status") == PendingActionStatus.pending.rawValue)
                .deleteAll(db)
            var a = PendingAction(id: nil, truckID: truckID, kind: .deliver, orderUUID: orderUUID,
                                  orderReason: orderReason, rejectedItems: rejectedItems, note: note,
                                  occurredAt: occurredAt, createdAt: now(), status: .pending,
                                  errorMessage: nil)
            try a.insert(db)
        }
    }

    /// Pliega el resultado del servidor (DeliveryRecord) en el snapshot al sincronizar.
    func applyDeliveryRecord(_ record: DeliveryRecord) throws {
        try database.dbQueue.write { db in
            guard var order = try DriverOrder
                .filter(Column("order_uuid").collating(.nocase) == record.orderUUID)
                .fetchOne(db) else { return }
            order.deliveryStatus = record.status
            try order.update(db)
        }
    }

    func pendingActions() throws -> [PendingAction] {
        try database.dbQueue.read { db in
            try PendingAction.filter(Column("status") == PendingActionStatus.pending.rawValue)
                .order(Column("created_at")).fetchAll(db)
        }
    }

    /// Solo los `deliver` pendientes (para el overlay provisional y los retornados).
    func pendingDelivers() throws -> [PendingAction] {
        try database.dbQueue.read { db in
            try PendingAction
                .filter(Column("kind") == PendingActionKind.deliver.rawValue
                        && Column("status") == PendingActionStatus.pending.rawValue)
                .fetchAll(db)
        }
    }

    func pendingCount() throws -> Int {
        try database.dbQueue.read { db in
            try PendingAction.filter(Column("status") == PendingActionStatus.pending.rawValue).fetchCount(db)
        }
    }

    func deleteAction(id: Int64) throws {
        _ = try database.dbQueue.write { try PendingAction.deleteOne($0, key: id) }
    }

    func markActionFailed(id: Int64, error: String) throws {
        try database.dbQueue.write { db in
            guard var a = try PendingAction.fetchOne(db, key: id) else { return }
            a.status = .failed
            a.errorMessage = error
            try a.update(db)
        }
    }

    // MARK: - Pagos (★ v0.16.0). Registro LOCAL DURABLE = fuente de la caja.

    /// Guarda el pago al instante (no se pierde). El envío se sincroniza aparte.
    func insertPayment(_ payment: Payment) throws {
        try database.dbQueue.write { try payment.insert($0) }
    }

    /// Anula LOCALMENTE (deja el rastro; nada se borra). El void real se sincroniza aparte.
    func voidPaymentLocally(paymentUUID: String, reason: String, at: Date) throws {
        try database.dbQueue.write { db in
            guard var p = try Payment
                .filter(Column("payment_uuid").collating(.nocase) == paymentUUID).fetchOne(db) else { return }
            p.isVoided = true
            p.voidReason = reason
            p.voidedAt = at
            p.voidSynced = false
            try p.update(db)
        }
    }

    /// Todos los pagos de la caja (recientes primero), anulados incluidos (marcados).
    func payments() throws -> [Payment] {
        try database.dbQueue.read { try Payment.order(Column("created_at").desc).fetchAll($0) }
    }

    func payment(uuid: String) throws -> Payment? {
        try database.dbQueue.read { db in
            try Payment.filter(Column("payment_uuid").collating(.nocase) == uuid).fetchOne(db)
        }
    }

    /// Pagos con algo sin sincronizar (crear o anular).
    func paymentsNeedingSync() throws -> [Payment] {
        try database.dbQueue.read { db in
            try Payment.filter(Column("create_synced") == false
                               || (Column("is_voided") == true && Column("void_synced") == false))
                .order(Column("created_at")).fetchAll(db)
        }
    }

    func markPaymentCreateSynced(paymentUUID: String) throws {
        try database.dbQueue.write { db in
            guard var p = try Payment
                .filter(Column("payment_uuid").collating(.nocase) == paymentUUID).fetchOne(db) else { return }
            p.createSynced = true
            try p.update(db)
        }
    }

    func markPaymentVoidSynced(paymentUUID: String) throws {
        try database.dbQueue.write { db in
            guard var p = try Payment
                .filter(Column("payment_uuid").collating(.nocase) == paymentUUID).fetchOne(db) else { return }
            p.voidSynced = true
            try p.update(db)
        }
    }

    /// Totales de la caja: separados CASH/CHEQUE; los ANULADOS no suman.
    func cajaTotals() throws -> PaymentTotals {
        try database.dbQueue.read { db in
            let all = try Payment.fetchAll(db)
            var t = PaymentTotals()
            for p in all where !p.isVoided {
                if p.paymentType == .cash { t.cash += p.amount } else { t.cheque += p.amount }
                t.count += 1
            }
            t.voidedCount = all.filter(\.isVoided).count
            return t
        }
    }

    /// Cuántos pagos están sin sincronizar (para el indicador — dinero sin registro es grave).
    func pendingPaymentsCount() throws -> Int {
        try database.dbQueue.read { db in
            try Payment.filter(Column("create_synced") == false
                               || (Column("is_voided") == true && Column("void_synced") == false))
                .fetchCount(db)
        }
    }
}
