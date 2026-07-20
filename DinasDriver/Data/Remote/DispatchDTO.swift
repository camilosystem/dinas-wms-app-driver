import Foundation

// DTOs de red del DESPACHO (★ v0.14.0), según contracts/openapi.yaml. La descarga
// (DriverRoute) viene anidada (paradas → pedidos → líneas) y el repositorio la descompone en
// las tablas locales. Decodificación TOLERANTE: opcionales con decodeIfPresent; los enums se
// mapean desde String → un valor desconocido no revienta el sync.

// MARK: - Descarga (GET /dispatch/my-route, POST /dispatch/start-route)

/// La ruta completa que baja el driver (schema `DriverRoute`).
struct RouteDownload: Decodable {
    let truckID: String
    let truckName: String?
    let status: TruckStatus
    let downloadedAt: Date?
    let startedAt: Date?
    let totalStops: Int
    let totalOrders: Int
    let pendingOrders: Int
    let stops: [Stop]

    enum CodingKeys: String, CodingKey {
        case truckID = "truck_id"
        case truckName = "truck_name"
        case status
        case downloadedAt = "downloaded_at"
        case startedAt = "started_at"
        case totalStops = "total_stops"
        case totalOrders = "total_orders"
        case pendingOrders = "pending_orders"
        case stops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        truckID = try c.decode(String.self, forKey: .truckID)
        truckName = try c.decodeIfPresent(String.self, forKey: .truckName)
        status = try c.decodeIfPresent(TruckStatus.self, forKey: .status) ?? .otro
        downloadedAt = try c.decodeIfPresent(Date.self, forKey: .downloadedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        totalStops = try c.decodeIfPresent(Int.self, forKey: .totalStops) ?? 0
        totalOrders = try c.decodeIfPresent(Int.self, forKey: .totalOrders) ?? 0
        pendingOrders = try c.decodeIfPresent(Int.self, forKey: .pendingOrders) ?? 0
        stops = try c.decodeIfPresent([Stop].self, forKey: .stops) ?? []
    }

    struct Stop: Decodable {
        let stopNumber: Int
        let clientCode: String
        let clientName: String
        let address: String?
        let city: String?
        let zipCode: String?
        let phone: String?
        let orders: [Order]

        enum CodingKeys: String, CodingKey {
            case stopNumber = "stop_number"
            case clientCode = "client_code"
            case clientName = "client_name"
            case address, city
            case zipCode = "zip_code"
            case phone, orders
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stopNumber = try c.decodeIfPresent(Int.self, forKey: .stopNumber) ?? 0
            clientCode = try c.decode(String.self, forKey: .clientCode)
            clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? clientCode
            address = try c.decodeIfPresent(String.self, forKey: .address)
            city = try c.decodeIfPresent(String.self, forKey: .city)
            zipCode = try c.decodeIfPresent(String.self, forKey: .zipCode)
            phone = try c.decodeIfPresent(String.self, forKey: .phone)
            orders = try c.decodeIfPresent([Order].self, forKey: .orders) ?? []
        }
    }

    struct Order: Decodable {
        let orderUUID: String
        let orderNumber: String
        let totalAmount: Double
        let totalUnits: Double
        let palletLabels: [String]
        let isIncompleteDelivery: Bool
        let deliveryStatus: DeliveryStatus?
        let lines: [DriverOrderLine]

        enum CodingKeys: String, CodingKey {
            case orderUUID = "order_uuid"
            case orderNumber = "order_number"
            case totalAmount = "total_amount"
            case totalUnits = "total_units"
            case palletLabels = "pallet_labels"
            case isIncompleteDelivery = "is_incomplete_delivery"
            case deliveryStatus = "delivery_status"
            case lines
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            orderUUID = try c.decode(String.self, forKey: .orderUUID)
            orderNumber = try c.decodeIfPresent(String.self, forKey: .orderNumber) ?? ""
            totalAmount = try c.decodeIfPresent(Double.self, forKey: .totalAmount) ?? 0
            totalUnits = try c.decodeIfPresent(Double.self, forKey: .totalUnits) ?? 0
            palletLabels = try c.decodeIfPresent([String].self, forKey: .palletLabels) ?? []
            isIncompleteDelivery = try c.decodeIfPresent(Bool.self, forKey: .isIncompleteDelivery) ?? false
            deliveryStatus = (try c.decodeIfPresent(String.self, forKey: .deliveryStatus))
                .flatMap(DeliveryStatus.init(rawValue:))
            lines = try c.decodeIfPresent([DriverOrderLine].self, forKey: .lines) ?? []
        }
    }
}

// MARK: - Registrar entrega (POST /dispatch/orders/{uuid}/deliver)

/// Cuerpo del deliver. O `order_reason` (no se entregó nada), o `rejected_items` (novedades),
/// o ninguno (entregó todo). Mandar ambos → 400 (la UI lo impide). `occurred_at` SIEMPRE.
struct DeliverRequest: Encodable {
    let orderReason: OrderRejectionReason?
    let rejectedItems: [Line]?
    let note: String?
    let occurredAt: Date

    struct Line: Encodable {
        let itemCode: String
        let quantity: Double
        let reason: ItemRejectionReason

        enum CodingKeys: String, CodingKey {
            case itemCode = "item_code"
            case quantity, reason
        }
    }

    enum CodingKeys: String, CodingKey {
        case orderReason = "order_reason"
        case rejectedItems = "rejected_items"
        case note
        case occurredAt = "occurred_at"
    }
}

/// Resultado derivado por el servidor (schema `DeliveryRecord`). Se pliega al snapshot.
struct DeliveryRecord: Decodable {
    let orderUUID: String
    let status: DeliveryStatus?

    enum CodingKeys: String, CodingKey {
        case orderUUID = "order_uuid"
        case status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderUUID = try c.decode(String.self, forKey: .orderUUID)
        status = (try c.decodeIfPresent(String.self, forKey: .status))
            .flatMap(DeliveryStatus.init(rawValue:))
    }

    init(orderUUID: String, status: DeliveryStatus?) {
        self.orderUUID = orderUUID; self.status = status
    }
}

// MARK: - Terminar ruta (POST /dispatch/finish-route)

/// Resumen al cerrar la ruta (schema `RouteSummary`), con los retornados.
struct RouteSummary: Decodable, Equatable {
    let truckID: String
    let truckName: String?
    let startedAt: Date?
    let finishedAt: Date?
    let totalOrders: Int
    let deliveredCount: Int
    let partialCount: Int
    let notDeliveredCount: Int
    let pendingCount: Int
    let returnedItems: [ReturnedItem]

    enum CodingKeys: String, CodingKey {
        case truckID = "truck_id"
        case truckName = "truck_name"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case totalOrders = "total_orders"
        case deliveredCount = "delivered_count"
        case partialCount = "partial_count"
        case notDeliveredCount = "not_delivered_count"
        case pendingCount = "pending_count"
        case returnedItems = "returned_items"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        truckID = try c.decodeIfPresent(String.self, forKey: .truckID) ?? ""
        truckName = try c.decodeIfPresent(String.self, forKey: .truckName)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        totalOrders = try c.decodeIfPresent(Int.self, forKey: .totalOrders) ?? 0
        deliveredCount = try c.decodeIfPresent(Int.self, forKey: .deliveredCount) ?? 0
        partialCount = try c.decodeIfPresent(Int.self, forKey: .partialCount) ?? 0
        notDeliveredCount = try c.decodeIfPresent(Int.self, forKey: .notDeliveredCount) ?? 0
        pendingCount = try c.decodeIfPresent(Int.self, forKey: .pendingCount) ?? 0
        returnedItems = try c.decodeIfPresent([ReturnedItem].self, forKey: .returnedItems) ?? []
    }

    init(truckID: String, truckName: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil,
         totalOrders: Int = 0, deliveredCount: Int = 0, partialCount: Int = 0,
         notDeliveredCount: Int = 0, pendingCount: Int = 0, returnedItems: [ReturnedItem] = []) {
        self.truckID = truckID; self.truckName = truckName; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.totalOrders = totalOrders
        self.deliveredCount = deliveredCount; self.partialCount = partialCount
        self.notDeliveredCount = notDeliveredCount; self.pendingCount = pendingCount
        self.returnedItems = returnedItems
    }
}

/// Un ítem que vuelve en el camión (schema `ReturnedItem`). Sirve para el resumen del servidor
/// y también para la lista LOCAL de retornados derivada de lo registrado.
struct ReturnedItem: Decodable, Equatable, Identifiable {
    let itemCode: String
    let itemName: String
    let quantity: Double
    let reason: ItemRejectionReason?
    let orderNumber: String
    let clientName: String

    var id: String { "\(orderNumber)#\(itemCode)#\(reason?.rawValue ?? "")" }

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
        case quantity, reason
        case orderNumber = "order_number"
        case clientName = "client_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemCode = try c.decode(String.self, forKey: .itemCode)
        itemName = try c.decodeIfPresent(String.self, forKey: .itemName) ?? itemCode
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        reason = (try c.decodeIfPresent(String.self, forKey: .reason))
            .flatMap(ItemRejectionReason.init(rawValue:))
        orderNumber = try c.decodeIfPresent(String.self, forKey: .orderNumber) ?? ""
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? ""
    }

    /// Constructor LOCAL (para derivar retornados de la cola, sin red).
    init(itemCode: String, itemName: String, quantity: Double, reason: ItemRejectionReason?,
         orderNumber: String, clientName: String) {
        self.itemCode = itemCode; self.itemName = itemName; self.quantity = quantity
        self.reason = reason; self.orderNumber = orderNumber; self.clientName = clientName
    }
}
