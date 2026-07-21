import Foundation

// DTOs de red de PAGOS (★ v0.16.0), según contracts/openapi.yaml.

/// Cuerpo de `POST /dispatch/payments`. `payment_uuid` lo GENERA la app al crear → idempotente:
/// el reintento manda el mismo y el servidor no duplica el dinero. CHEQUE exige `check_number`
/// y `photo_base64`; CASH no lleva ninguno.
struct SubmitPaymentRequest: Encodable {
    let paymentUUID: String
    let clientCode: String
    let amount: Double
    let paymentType: PaymentType
    let checkNumber: String?
    let photoBase64: String?
    let note: String?
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case paymentUUID = "payment_uuid"
        case clientCode = "client_code"
        case amount
        case paymentType = "payment_type"
        case checkNumber = "check_number"
        case photoBase64 = "photo_base64"
        case note
        case occurredAt = "occurred_at"
    }
}

/// Cuerpo de `POST /dispatch/payments/{uuid}/void`. Motivo OBLIGATORIO.
struct VoidPaymentRequest: Encodable {
    let reason: String
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case reason
        case occurredAt = "occurred_at"
    }
}

/// Respuesta de crear/anular (schema `Payment`). Solo se usa el id (confirmación); la fuente de
/// la caja es el registro LOCAL.
struct PaymentAck: Decodable {
    let paymentUUID: String

    enum CodingKeys: String, CodingKey { case paymentUUID = "payment_uuid" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paymentUUID = try c.decodeIfPresent(String.self, forKey: .paymentUUID) ?? ""
    }

    init(paymentUUID: String) { self.paymentUUID = paymentUUID }
}
