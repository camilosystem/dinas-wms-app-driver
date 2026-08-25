import Foundation

// DTOs de CUSTODIA del dinero (Dr2, ★ v0.80.0), según contracts/openapi.yaml.
//
// "Mi caja" es server-autoritativa a propósito: cruza rutas y jornadas y sabe qué está declarado
// entregado (`handed_over_at`), cosa que la base local no puede saber (la marca la pone el
// servidor). El servidor ya NO filtra por camión activo — un pago viejo sin declarar de una ruta
// cerrada sigue siendo del driver. La app NO debe volver a filtrarlo (ver Custody.swift).

/// Un pago tal como lo devuelve el servidor (schema `Payment` del contrato). Es la vista de
/// SERVIDOR del pago, distinta del registro local `Payment` (GRDB): esta trae el estado de
/// custodia (`handed_over_at`, `handover_undone_*`) y de depósito que solo el servidor conoce.
struct RemotePayment: Decodable, Identifiable, Equatable {
    let paymentUUID: String
    let truckID: String?
    let truckName: String?
    let clientCode: String
    let clientName: String
    let amount: Double
    let paymentType: PaymentType
    let checkNumber: String?
    let invoiceDocNums: [String]
    /// Cuándo se recibió el dinero (hora real de la visita, la AFIRMA el dispositivo, regla 📱).
    let occurredAt: Date
    /// Cuándo llegó al servidor. El delta con `occurredAt` NO tiene signo ni tamaño garantizados
    /// (★ v0.81.0): puede ser un futuro de segundos (reloj adelantado) o de horas/días en el pasado.
    let recordedAt: Date
    /// No nulo = el driver YA declaró que lo entregó en bodega. Es una DECLARACIÓN suya, no un acuse
    /// de recibo: nadie en bodega lo confirma.
    let handedOverAt: Date?
    /// Última vez que deshizo una declaración (si la hubo). Se dice para que no se lea como una
    /// segunda entrega.
    let handoverUndoneAt: Date?
    /// Cuántas veces deshizo. Un 1 es un error de dedo; un 5 es otra cosa. La oficina ve la
    /// SECUENCIA, no solo el estado final — por eso no se puede tapar.
    let handoverUndoneCount: Int
    let isVoided: Bool
    /// Referencia del depósito en que la oficina ya lo metió (si lo hizo). No nulo = no se puede
    /// deshacer la entrega (409).
    let depositReference: String?

    var id: String { paymentUUID }

    /// ¿Ya está declarado entregado? (y no anulado).
    var isHandedOver: Bool { handedOverAt != nil && !isVoided }
    /// ¿Está en un depósito de la oficina? → deshacer la entrega devolvería 409.
    var isInDeposit: Bool { depositReference != nil }

    enum CodingKeys: String, CodingKey {
        case paymentUUID = "payment_uuid"
        case truckID = "truck_id"
        case truckName = "truck_name"
        case clientCode = "client_code"
        case clientName = "client_name"
        case amount
        case paymentType = "payment_type"
        case checkNumber = "check_number"
        case invoiceDocNums = "invoice_doc_nums"
        case occurredAt = "occurred_at"
        case recordedAt = "recorded_at"
        case handedOverAt = "handed_over_at"
        case handoverUndoneAt = "handover_undone_at"
        case handoverUndoneCount = "handover_undone_count"
        case isVoided = "is_voided"
        case depositReference = "deposit_reference"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paymentUUID = try c.decode(String.self, forKey: .paymentUUID)
        truckID = try c.decodeIfPresent(String.self, forKey: .truckID)
        truckName = try c.decodeIfPresent(String.self, forKey: .truckName)
        clientCode = try c.decode(String.self, forKey: .clientCode)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? ""
        amount = try c.decode(Double.self, forKey: .amount)
        paymentType = try c.decode(PaymentType.self, forKey: .paymentType)
        checkNumber = try c.decodeIfPresent(String.self, forKey: .checkNumber)
        invoiceDocNums = try c.decodeIfPresent([String].self, forKey: .invoiceDocNums) ?? []
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        handedOverAt = try c.decodeIfPresent(Date.self, forKey: .handedOverAt)
        handoverUndoneAt = try c.decodeIfPresent(Date.self, forKey: .handoverUndoneAt)
        // Un conteo ausente ES cero de verdad (nunca deshizo): default honesto, no enmascara.
        handoverUndoneCount = try c.decodeIfPresent(Int.self, forKey: .handoverUndoneCount) ?? 0
        isVoided = try c.decodeIfPresent(Bool.self, forKey: .isVoided) ?? false
        depositReference = try c.decodeIfPresent(String.self, forKey: .depositReference)
    }

    /// Solo para tests/fixtures.
    init(paymentUUID: String, truckID: String? = nil, truckName: String? = nil,
         clientCode: String, clientName: String = "", amount: Double,
         paymentType: PaymentType = .cash, checkNumber: String? = nil,
         invoiceDocNums: [String] = [], occurredAt: Date, recordedAt: Date,
         handedOverAt: Date? = nil, handoverUndoneAt: Date? = nil, handoverUndoneCount: Int = 0,
         isVoided: Bool = false, depositReference: String? = nil) {
        self.paymentUUID = paymentUUID; self.truckID = truckID; self.truckName = truckName
        self.clientCode = clientCode; self.clientName = clientName; self.amount = amount
        self.paymentType = paymentType; self.checkNumber = checkNumber
        self.invoiceDocNums = invoiceDocNums; self.occurredAt = occurredAt; self.recordedAt = recordedAt
        self.handedOverAt = handedOverAt; self.handoverUndoneAt = handoverUndoneAt
        self.handoverUndoneCount = handoverUndoneCount; self.isVoided = isVoided
        self.depositReference = depositReference
    }
}

/// `GET /dispatch/my-cash` (Dr2). Lo que el driver tiene SIN declarar entregado, con su total.
/// No trae anulados (no hay dinero detrás) ni declarados (esos ya no los lleva encima). Cero es un
/// estado legítimo y frecuente: significa que declaró todo, no que falte información.
struct DriverCash: Decodable, Equatable {
    let totalAmount: Double
    let payments: [RemotePayment]

    enum CodingKeys: String, CodingKey {
        case totalAmount = "total_amount"
        case payments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalAmount = try c.decodeIfPresent(Double.self, forKey: .totalAmount) ?? 0
        payments = try c.decodeIfPresent([RemotePayment].self, forKey: .payments) ?? []
    }

    init(totalAmount: Double, payments: [RemotePayment]) {
        self.totalAmount = totalAmount; self.payments = payments
    }
}
