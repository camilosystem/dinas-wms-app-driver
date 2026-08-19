import Foundation
import GRDB

/// Qué clase de registro es un `POST /dispatch/returns`. OBLIGATORIO al registrar: sin valor por
/// defecto, para que el compilador force la decisión. Un `pickup_for_request_uuid: String?` que
/// alguien olvida pasar produce una devolución espontánea válida que PERDIÓ el vínculo con la
/// solicitud, y la recogida se queda EN_CAMION para siempre sin que nada falle.
enum ReturnKind: Equatable {
    case spontaneous
    case pickup(requestUUID: String)

    var pickupForRequestUUID: String? {
        if case let .pickup(id) = self { return id }
        return nil
    }
}

/// ★ v0.45.0 — Una RECOGIDA en una parada, como la ve el driver: una solicitud de crédito que se
/// convirtió en "ir a buscar mercancía" en vez de entregar. Viaja en la descarga de la ruta
/// (`DriverStop.pickups`) y se basta sola sin conexión.
///
/// Se registra con `POST /dispatch/returns` mandando `pickup_for_request_uuid` (cantidades reales
/// + foto obligatoria, igual que una devolución espontánea). Si no se puede, se declara con
/// `POST /dispatch/pickups/{request_uuid}/not-collected`.
struct DriverPickup: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var requestUUID: String          // PK — la solicitud de crédito que mandó a buscar la mercancía
    var truckID: String
    var clientCode: String           // liga con su parada
    /// Motivo de la solicitud (`CreditRequestReason`). Se guarda como texto: es solo para mostrar,
    /// y un valor nuevo del servidor no debe tumbar la descarga (enum tolerante por diseño).
    var reason: String?
    /// Instrucción de la oficina: dónde está la mercancía, con quién preguntar. La ve el driver.
    var pickupNote: String?
    /// `PickupStatus` (MARCADA/EN_CAMION/RECOGIDA/NO_RECOGIDA). Texto por tolerancia.
    var pickupStatus: String
    /// Lo que la solicitud dice que hay que buscar. REFERENCIA, no validación: el driver registra
    /// lo que el cliente efectivamente entrega. VACÍO significa "no se sabe qué ni cuánto"
    /// (solicitud por monto), NO "nada que recoger".
    var expectedItems: [DriverPickupItem]

    var id: String { requestUUID }
    static let databaseTableName = "driver_pickups"

    /// El servidor ya la cerró (recogida hecha o declarada como no hecha). Para saber, offline, si
    /// todavía hay algo que ofrecer. La marca LOCAL (encolada sin señal) vive en `pending_actions`.
    var isResolvedByServer: Bool { pickupStatus == "RECOGIDA" || pickupStatus == "NO_RECOGIDA" }

    enum CodingKeys: String, CodingKey {
        case requestUUID = "request_uuid"
        case truckID = "truck_id"
        case clientCode = "client_code"
        case reason
        case pickupNote = "pickup_note"
        case pickupStatus = "pickup_status"
        case expectedItems = "expected_items"
    }
}

/// Un ítem esperado de una recogida (`PickupExpectedItem`). Ayuda para buscar, no lista a cuadrar.
struct DriverPickupItem: Codable, Equatable, Identifiable {
    var itemCode: String
    var itemName: String?
    var quantity: Double

    var id: String { itemCode }

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
        case quantity
    }
}

/// ★ v0.45.0 — Por qué el driver NO pudo hacer una recogida. La produce el driver (saliente), así
/// que un enum fijo con `allCases` para el selector está bien.
enum PickupNotCollectedReason: String, Codable, CaseIterable, Identifiable {
    case nadaQueRecoger = "NADA_QUE_RECOGER"
    case negocioCerrado = "NEGOCIO_CERRADO"
    case clienteNoLaEntrega = "CLIENTE_NO_LA_ENTREGA"
    case sinEspacioEnCamion = "SIN_ESPACIO_EN_CAMION"

    var id: String { rawValue }

    /// Español neutro, sin voseo.
    var label: String {
        switch self {
        case .nadaQueRecoger: return "No había nada que recoger"
        case .negocioCerrado: return "Negocio cerrado"
        case .clienteNoLaEntrega: return "El cliente no la entrega"
        case .sinEspacioEnCamion: return "Sin espacio en el camión"
        }
    }
}
