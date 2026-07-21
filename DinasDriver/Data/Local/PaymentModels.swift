import Foundation
import GRDB

// Modelos del PAGO en ruta (★ v0.16.0, Bloque 4C). Un pago es DINERO: registro INMUTABLE (no se
// edita ni se borra; si hubo error se ANULA dejando el rastro) y máxima robustez de la cola —
// un pago encolado que se pierda es dinero sin registro.

enum PaymentType: String, Codable, CaseIterable, Identifiable {
    case cash = "CASH"
    case cheque = "CHEQUE"

    var id: String { rawValue }
    var label: String { self == .cash ? "Efectivo" : "Cheque" }
}

/// Un pago recogido en ruta (tabla `payments`). Es el REGISTRO LOCAL DURABLE y la fuente de la
/// caja: se guarda al instante y nunca se pierde (persiste en el archivo del driver). El envío
/// se sincroniza aparte (`createSynced`/`voidSynced`); el `payment_uuid` (generado al crear) hace
/// el POST idempotente. La foto del cheque vive en disco (`photoPath`), se borra tras sincronizar.
struct Payment: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var paymentUUID: String
    var truckID: String
    var clientCode: String
    var clientName: String
    var amount: Double
    var paymentType: PaymentType
    var checkNumber: String?
    var note: String?
    var photoPath: String?
    var occurredAt: Date
    var createdAt: Date
    var isVoided: Bool
    var voidReason: String?
    var voidedAt: Date?
    /// El POST de creación llegó al servidor.
    var createSynced: Bool
    /// La anulación (si `isVoided`) llegó al servidor.
    var voidSynced: Bool

    var id: String { paymentUUID }
    static let databaseTableName = "payments"

    /// ¿Tiene algo sin sincronizar? (crear, o anular). El indicador de pendientes lo usa —
    /// un pago sin enviar es dinero sin registro.
    var needsSync: Bool { !createSynced || (isVoided && !voidSynced) }

    enum CodingKeys: String, CodingKey {
        case paymentUUID = "payment_uuid"
        case truckID = "truck_id"
        case clientCode = "client_code"
        case clientName = "client_name"
        case amount
        case paymentType = "payment_type"
        case checkNumber = "check_number"
        case note
        case photoPath = "photo_path"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
        case isVoided = "is_voided"
        case voidReason = "void_reason"
        case voidedAt = "voided_at"
        case createSynced = "create_synced"
        case voidSynced = "void_synced"
    }
}

/// La caja del driver: totales separados. Los ANULADOS no suman.
struct PaymentTotals: Equatable {
    var cash: Double = 0
    var cheque: Double = 0
    var count: Int = 0          // pagos válidos (sin anulados)
    var voidedCount: Int = 0

    var grand: Double { cash + cheque }
}
