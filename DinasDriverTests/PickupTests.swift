import XCTest
import GRDB
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import DinasDriver

/// Recogidas (★ v0.45.0): una solicitud de crédito convertida en parada de recogida. Estos tests
/// son NEGATIVOS a propósito — cada uno se puede romper con un sabotaje concreto y ponerse rojo.
@MainActor
final class PickupTests: XCTestCase {

    private let visitTime = Date(timeIntervalSince1970: 5000)

    /// Ruta con UNA parada de PURA RECOGIDA: `orders: []` y un pickup. Es el caso que desaparece si
    /// la vista/almacén filtra paradas por lista de pedidos vacía.
    private func makePickupOnlyRoute() throws -> RouteDownload {
        let json = Data("""
        {"truck_id":"TRK-1","truck_name":"Camión 1","status":"EN_RUTA",
         "total_stops":1,"total_orders":0,"pending_orders":0,
         "stops":[{"stop_number":1,"client_code":"C9","client_name":"Solo Recogida SA",
                   "orders":[],
                   "pickups":[{"request_uuid":"REQ-1","reason":"DAMAGED",
                               "pickup_note":"Preguntar por Marta en caja",
                               "pickup_status":"EN_CAMION",
                               "expected_items":[{"item_code":"CANOA-01","item_name":"Canoa Mango","quantity":10}]}]}],
         "item_catalog":[{"item_code":"CANOA-01","item_name":"Canoa Mango"}]}
        """.utf8)
        return try JSONCoding.decoder.decode(RouteDownload.self, from: json)
    }

    private func makeService(_ db: AppDatabase, _ api: StubDispatchAPI) -> DispatchService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pickup-tests-\(UUID().uuidString)")
        return DispatchService(database: db, api: api, now: { self.visitTime },
                               photos: PhotoStore(folder: dir))
    }

    // 1 ─ La parada de pura recogida APARECE en la ruta (el test que se pone rojo al filtrar).
    func test_paradaDePuraRecogida_apareceEnLaRuta() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = DriverRepository(database: db)
        try repo.saveRoute(try makePickupOnlyRoute())

        let stops = try repo.stops()
        XCTAssertEqual(stops.map(\.clientCode), ["C9"],
                       "una parada con orders:[] NO puede desaparecer: es donde hay que ir a buscar")
        XCTAssertTrue((try repo.orders(forClient: "C9")).isEmpty)
        XCTAssertEqual(try repo.pickups(forClient: "C9").map(\.requestUUID), ["REQ-1"])
    }

    // 2 ─ Registrar la recogida viaja `pickup_for_request_uuid`, NO `credit_request_uuid`.
    func test_registrarRecogida_viajaPickupForRequestUUID() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makePickupOnlyRoute()
        let service = makeService(db, api)
        try service.repo.saveRoute(api.route!)
        let path = try service.photos.saveResized(from: try tinyJPEG())

        service.registerReturn(
            kind: .pickup(requestUUID: "REQ-1"), truckID: "TRK-1", clientCode: "C9",
            items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Mango",
                                           quantity: 7, reason: .danado)],   // entregó 7, no 10 — normal
            note: nil, clientReference: nil, photoPath: path)
        await service.syncPending()

        let sent = try XCTUnwrap(api.returnCalls.last)
        XCTAssertEqual(sent.pickupForRequestUUID, "REQ-1",
                       "la recogida DEBE viajar con pickup_for_request_uuid (el enlace opuesto a credit_request_uuid)")
    }

    // 3 ─ `not-collected` es idempotente (un solo pendiente) y usa `occurred_at` de la VISITA.
    func test_notCollected_idempotente_yOccurredAtDeLaVisita() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makePickupOnlyRoute()
        let service = makeService(db, api)
        try service.repo.saveRoute(api.route!)
        api.offline = true   // se registra sin señal

        service.registerPickupNotCollected(truckID: "TRK-1", requestUUID: "REQ-1",
                                            reason: .negocioCerrado, note: "cerrado")
        service.registerPickupNotCollected(truckID: "TRK-1", requestUUID: "REQ-1",
                                            reason: .nadaQueRecoger, note: "corrijo")   // reenvío
        let pend = try service.repo.pendingActions().filter { $0.kind == .pickupNotCollected }
        XCTAssertEqual(pend.count, 1, "idempotente por request_uuid: el reenvío reemplaza, no acumula")

        api.offline = false
        await service.syncPending()
        let sent = try XCTUnwrap(api.notCollectedCalls.last)
        XCTAssertEqual(sent.request.occurredAt, visitTime, "occurred_at = hora de la visita, no de la sync")
        XCTAssertEqual(sent.request.reason, .nadaQueRecoger)
    }

    // 4 ─ `expected_items` VACÍO se conserva (solicitud por monto): "no se sabe", NO "nada".
    func test_expectedItemsVacio_seConserva_noSeDescartaLaRecogida() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = DriverRepository(database: db)
        let json = Data("""
        {"truck_id":"TRK-1","status":"EN_RUTA","total_stops":1,"total_orders":0,"pending_orders":0,
         "stops":[{"stop_number":1,"client_code":"C9","client_name":"X",
                   "orders":[],"pickups":[{"request_uuid":"REQ-2","pickup_status":"EN_CAMION",
                                           "expected_items":[]}]}]}
        """.utf8)
        try repo.saveRoute(try JSONCoding.decoder.decode(RouteDownload.self, from: json))

        let pickup = try XCTUnwrap(try repo.pickups(forClient: "C9").first)
        XCTAssertTrue(pickup.expectedItems.isEmpty, "vacío se conserva: significa 'no se sabe qué recoger'")
    }

    // 5 ─ Doble registración offline: tras encolar, la recogida ya NO se ofrece (marca local).
    func test_recogidaRegistradaLocalmente_yaNoSeOfrece() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makePickupOnlyRoute()
        let service = makeService(db, api)
        try service.repo.saveRoute(api.route!)
        api.offline = true   // sin señal: el pickup_status descargado sigue EN_CAMION

        XCTAssertFalse(try service.repo.pickupRegisteredLocally(requestUUID: "REQ-1"),
                       "antes de registrar, se ofrece")
        let path = try service.photos.saveResized(from: try tinyJPEG())
        service.registerReturn(kind: .pickup(requestUUID: "REQ-1"), truckID: "TRK-1", clientCode: "C9",
                               items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Mango",
                                                              quantity: 3, reason: .danado)],
                               note: nil, clientReference: nil, photoPath: path)

        XCTAssertTrue(try service.repo.pickupRegisteredLocally(requestUUID: "REQ-1"),
                      "encolada sin señal: la marca LOCAL evita registrarla dos veces")
    }

    /// JPEG de prueba para la foto obligatoria (con algo de detalle; el contenido no importa acá).
    private func tinyJPEG() throws -> Data {
        let w = 800, h = 600
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: w, by: 16) {
            ctx.setFillColor(CGColor(red: Double(x % 255) / 255, green: 0.3, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: h))
        }
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
