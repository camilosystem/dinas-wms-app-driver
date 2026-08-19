import Foundation
import GRDB

// Modelos LOCALES (GRDB) del DESPACHO (★ v0.14.0). El mismo tipo sirve para el JSON del
// contrato y para persistir cuando las CodingKeys coinciden; lo que no viene por-fila del
// servidor (truck_id en hijos) es LOCAL y se rellena al guardar el snapshot. Offline-first:
// la ruta se descarga entera y se trabaja desde aquí; lo que registra el driver va a la cola.

// MARK: - Enums del contrato (tolerantes)

/// Ciclo de vida del camión (subconjunto que le importa al driver).
enum TruckStatus: String, Codable {
    case alistado = "ALISTADO"
    case asignadoDriver = "ASIGNADO_DRIVER"
    case enRuta = "EN_RUTA"
    case rutaCerrada = "RUTA_CERRADA"
    case otro = "OTRO"   // cualquier otro estado del ciclo (no operable por el driver)

    /// Decodificación TOLERANTE: un estado que la app no conoce no revienta el sync.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TruckStatus(rawValue: raw) ?? .otro
    }
}

/// Resultado de la entrega de un pedido (lo DERIVA el middleware; la app solo lo muestra).
enum DeliveryStatus: String, Codable {
    case pendiente = "PENDIENTE"
    case entregado = "ENTREGADO"
    case entregadoParcial = "ENTREGADO_PARCIAL"
    case noEntregado = "NO_ENTREGADO"
}

/// Por qué NO se entregó el pedido completo (salida rápida). Solo aplica a NO_ENTREGADO.
enum OrderRejectionReason: String, Codable, CaseIterable, Identifiable {
    case negocioCerrado = "NEGOCIO_CERRADO"
    case pedidoCancelado = "PEDIDO_CANCELADO"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .negocioCerrado: return "Negocio cerrado"
        case .pedidoCancelado: return "Pedido cancelado"
        }
    }
}

/// Por qué el cliente rechazó un ítem al recibir.
enum ItemRejectionReason: String, Codable, CaseIterable, Identifiable {
    case noLoQuiere = "NO_LO_QUIERE"
    case danado = "DANADO"
    case short = "SHORT"
    case noOrdenado = "NO_ORDENADO"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .noLoQuiere: return "No lo quiere"
        case .danado: return "Dañado"
        case .short: return "Faltó mercancía"
        case .noOrdenado: return "No lo ordenó"
        }
    }
}

/// Por qué el cliente DEVUELVE producto de facturas anteriores (★ v0.15.0, retorno). Distinto
/// de `ItemRejectionReason` (que es lo que se rechaza al recibir la entrega de hoy).
enum ProductReturnReason: String, Codable, CaseIterable, Identifiable {
    case danado = "DANADO"
    case expirado = "EXPIRADO"
    case noLoQuiere = "NO_LO_QUIERE"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .danado: return "Dañado"
        case .expirado: return "Expirado"
        case .noLoQuiere: return "No lo quiere"
        }
    }
}

// MARK: - Catálogo (para buscar al registrar un retorno, offline)

/// Un ítem vendible del catálogo (★ v0.15.0). Baja con la ruta (`DriverRoute.item_catalog`,
/// ~540 ítems) para que el driver busque por código o nombre al registrar un retorno — que es
/// de facturas anteriores, así que el ítem puede no estar en el camión de hoy.
struct CatalogItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var itemCode: String
    var itemName: String

    var id: String { itemCode }
    static let databaseTableName = "catalog_items"

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
    }
}

/// Un ítem de un retorno, tal como lo arma el driver. Se guarda en la cola y viaja al servidor.
struct ProductReturnItemInput: Codable, Equatable, Identifiable {
    var itemCode: String
    var itemName: String
    var quantity: Double
    var reason: ProductReturnReason

    var id: String { itemCode }

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
        case quantity, reason
    }
}

// MARK: - Snapshot de la ruta (GRDB, descompuesto de DriverRoute)

/// Cabecera de la ruta descargada (tabla `route`, una sola fila). `downloaded_at` marca que
/// el driver YA descargó y puede trabajar offline; su ausencia dispara el aviso.
struct RouteHeader: Codable, FetchableRecord, PersistableRecord, Equatable {
    var truckID: String
    var truckName: String?
    var status: TruckStatus
    var downloadedAt: Date
    var startedAt: Date?
    var totalStops: Int
    var totalOrders: Int
    var pendingOrders: Int

    static let databaseTableName = "route"

    enum CodingKeys: String, CodingKey {
        case truckID = "truck_id"
        case truckName = "truck_name"
        case status
        case downloadedAt = "downloaded_at"
        case startedAt = "started_at"
        case totalStops = "total_stops"
        case totalOrders = "total_orders"
        case pendingOrders = "pending_orders"
    }
}

/// Una parada de la ruta (tabla `driver_stops`). `stop_number` es el orden del ADMIN; el
/// reordenamiento del driver vive aparte en `local_stop_order` (device-only).
struct DriverStop: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var truckID: String
    var stopNumber: Int
    var clientCode: String
    var clientName: String
    var address: String?
    var city: String?
    var zipCode: String?
    var phone: String?

    var id: String { "\(truckID)#\(clientCode)" }
    static let databaseTableName = "driver_stops"

    enum CodingKeys: String, CodingKey {
        case truckID = "truck_id"
        case stopNumber = "stop_number"
        case clientCode = "client_code"
        case clientName = "client_name"
        case address, city
        case zipCode = "zip_code"
        case phone
    }
}

/// Una línea de un pedido (para confirmar ítem por ítem). Se guarda como JSON dentro del pedido.
struct DriverOrderLine: Codable, Equatable, Identifiable {
    var itemCode: String
    var itemName: String
    var quantity: Double

    var id: String { itemCode }

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
        case quantity
    }
}

/// Un pedido a entregar (tabla `driver_orders`). `lines`/`pallet_labels` → JSON. `deliveryStatus`
/// lo fija el servidor (se pliega al sincronizar el deliver); el estado provisional/pendiente se
/// deriva de la cola. `client_code` liga con su parada.
struct DriverOrder: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var orderUUID: String
    var truckID: String
    var clientCode: String
    var orderNumber: String
    var totalAmount: Double
    var totalUnits: Double
    var palletLabels: [String]
    var isIncompleteDelivery: Bool
    var deliveryStatus: DeliveryStatus?
    var lines: [DriverOrderLine]

    var id: String { orderUUID }
    static let databaseTableName = "driver_orders"

    enum CodingKeys: String, CodingKey {
        case orderUUID = "order_uuid"
        case truckID = "truck_id"
        case clientCode = "client_code"
        case orderNumber = "order_number"
        case totalAmount = "total_amount"
        case totalUnits = "total_units"
        case palletLabels = "pallet_labels"
        case isIncompleteDelivery = "is_incomplete_delivery"
        case deliveryStatus = "delivery_status"
        case lines
    }
}

extension DriverOrder {
    // Campos opcionales/locales tolerantes: un pedido con menos datos no rompe la descarga.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderUUID = try c.decode(String.self, forKey: .orderUUID)
        truckID = try c.decodeIfPresent(String.self, forKey: .truckID) ?? ""
        clientCode = try c.decodeIfPresent(String.self, forKey: .clientCode) ?? ""
        orderNumber = try c.decodeIfPresent(String.self, forKey: .orderNumber) ?? ""
        totalAmount = try c.decodeIfPresent(Double.self, forKey: .totalAmount) ?? 0
        totalUnits = try c.decodeIfPresent(Double.self, forKey: .totalUnits) ?? 0
        palletLabels = try c.decodeIfPresent([String].self, forKey: .palletLabels) ?? []
        isIncompleteDelivery = try c.decodeIfPresent(Bool.self, forKey: .isIncompleteDelivery) ?? false
        // Enum tolerante: un valor desconocido → nil (no revienta el sync).
        deliveryStatus = (try? c.decodeIfPresent(String.self, forKey: .deliveryStatus))
            .flatMap { $0 }.flatMap(DeliveryStatus.init(rawValue:))
        lines = try c.decodeIfPresent([DriverOrderLine].self, forKey: .lines) ?? []
    }
}

/// Preferencia LOCAL de orden de paradas del driver (tabla `local_stop_order`). Device-only:
/// NUNCA se manda al servidor; sobrevive reinicios.
struct LocalStopOrder: Codable, FetchableRecord, PersistableRecord, Equatable {
    var truckID: String
    var clientCode: String
    var localIndex: Int

    static let databaseTableName = "local_stop_order"

    enum CodingKeys: String, CodingKey {
        case truckID = "truck_id"
        case clientCode = "client_code"
        case localIndex = "local_index"
    }
}

// MARK: - Cola offline

enum PendingActionKind: String, Codable {
    case startRoute = "START_ROUTE"      // iniciar la ruta (singleton por camión)
    case deliver = "DELIVER"             // registrar la entrega de un pedido (idempotente por pedido)
    case finishRoute = "FINISH_ROUTE"    // cerrar la ruta (singleton por camión)
    case productReturn = "PRODUCT_RETURN" // ★ v0.15.0 — retorno de producto (con foto en disco)
    case pickupNotCollected = "PICKUP_NOT_COLLECTED" // ★ v0.45.0 — recogida que no se pudo hacer
}

enum PendingActionStatus: String, Codable {
    case pending = "PENDING"   // esperando red
    case failed = "FAILED"     // error PERMANENTE (400): requiere atención; no se reintenta
}

/// Acción pendiente de sincronizar (offline-first). Se aplica OPTIMISTA al estado local y se
/// reenvía cuando hay red. Idempotencia: `deliver` por `order_uuid`; `start`/`finish` por camión.
/// ★ `occurredAt` = la hora REAL en que el driver registró en la calle; viaja verbatim en el
/// replay (no la hora de sincronización).
struct PendingAction: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var truckID: String
    var kind: PendingActionKind
    var orderUUID: String?
    /// Salida rápida "no se entregó" (excluyente con `rejectedItems`).
    var orderReason: OrderRejectionReason?
    /// Ítems no entregados con su motivo (excluyente con `orderReason`). JSON.
    var rejectedItems: [RejectedItemInput]?
    var note: String?
    var occurredAt: Date
    var createdAt: Date
    var status: PendingActionStatus
    var errorMessage: String?
    // ★ v0.15.0 — RETORNO de producto. `photoPath` es la RUTA al JPEG en disco (no los bytes);
    // se borra al sincronizar. `returnItems` son los ítems devueltos; `clientReference` la
    // referencia opcional del cliente (factura/remisión).
    var clientCode: String? = nil
    var returnItems: [ProductReturnItemInput]? = nil
    var clientReference: String? = nil
    var photoPath: String? = nil
    /// ★ UUID del retorno, generado al CREARLO. Estable entre reintentos → el POST es
    /// idempotente y no duplica.
    var returnUUID: String? = nil
    /// ★ v0.45.0 — Si esta acción es la RECOGIDA de una solicitud: la solicitud que mandó a buscar
    /// la mercancía. En un PRODUCT_RETURN viaja como `pickup_for_request_uuid` (NO `credit_request_uuid`,
    /// que es el enlace opuesto); en un PICKUP_NOT_COLLECTED es el `request_uuid` de la ruta. También
    /// es la marca LOCAL anti-doble-registro: si hay una acción pendiente con este valor, ya se registró.
    var pickupForRequestUUID: String? = nil
    /// ★ v0.45.0 — Motivo de un PICKUP_NOT_COLLECTED.
    var pickupNotCollectedReason: PickupNotCollectedReason? = nil

    static let databaseTableName = "pending_actions"

    enum CodingKeys: String, CodingKey {
        case id
        case truckID = "truck_id"
        case kind
        case orderUUID = "order_uuid"
        case orderReason = "order_reason"
        case rejectedItems = "rejected_items"
        case note
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
        case status
        case errorMessage = "error_message"
        case clientCode = "client_code"
        case returnItems = "return_items"
        case clientReference = "client_reference"
        case photoPath = "photo_path"
        case returnUUID = "return_uuid"
        case pickupForRequestUUID = "pickup_for_request_uuid"
        case pickupNotCollectedReason = "pickup_not_collected_reason"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Un ítem rechazado, tal como lo marca el driver (cuerpo del deliver). Se guarda en la cola y
/// viaja al servidor. `quantity` = cuántas unidades NO se entregaron.
struct RejectedItemInput: Codable, Equatable, Identifiable {
    var itemCode: String
    var itemName: String?
    var quantity: Double
    var reason: ItemRejectionReason

    var id: String { itemCode }

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
        case quantity, reason
    }
}
