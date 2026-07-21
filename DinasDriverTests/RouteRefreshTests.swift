import XCTest
import GRDB
@testable import DinasDriver

/// Traer una ruta nueva tras cerrar una (★ fix "atrapado con la ruta vieja"): botón "Actualizar
/// ruta" siempre disponible, logout limpia el snapshot (conserva cola/pagos), 404 claro, y una
/// ruta nueva NO descarta la cola pendiente de la anterior.
@MainActor
final class RouteRefreshTests: XCTestCase {

    private func route(truckID: String) throws -> RouteDownload {
        let json = Data("""
        {"truck_id":"\(truckID)","truck_name":"Camión \(truckID)","status":"EN_RUTA",
         "downloaded_at":"2026-07-21T08:00:00Z","started_at":null,
         "total_stops":1,"total_orders":1,"pending_orders":1,
         "stops":[{"stop_number":1,"client_code":"C1","client_name":"Tienda Uno",
                   "orders":[{"order_uuid":"O1","order_number":"N-1","lines":[]}]}],
         "item_catalog":[]}
        """.utf8)
        return try JSONCoding.decoder.decode(RouteDownload.self, from: json)
    }

    private func makeService(_ api: StubDispatchAPI) throws -> DispatchService {
        DispatchService(database: try AppDatabase.makeInMemory(), api: api,
                        now: { Date(timeIntervalSince1970: 1000) })
    }

    // MARK: - Ruta cerrada → actualizar trae la nueva

    func test_rutaCerrada_actualizarTraeLaNueva() async throws {
        let api = StubDispatchAPI()
        let s = try makeService(api)
        try s.repo.saveRoute(try route(truckID: "T1"))
        try s.repo.markFinishedLocally()
        XCTAssertTrue(s.localRouteIsClosed, "la ruta local quedó cerrada")

        // El admin asignó un camión nuevo.
        api.route = try route(truckID: "T2")
        await s.downloadRoute()

        XCTAssertEqual(try s.repo.routeHeader()?.truckID, "T2", "trae la ruta nueva")
        XCTAssertFalse(s.localRouteIsClosed, "la nueva no está cerrada")
        XCTAssertEqual(s.downloadState, .downloaded)
    }

    func test_checkForNewRouteIfClosed_soloActuaSiEstaCerrada() async throws {
        let api = StubDispatchAPI()
        let s = try makeService(api)
        try s.repo.saveRoute(try route(truckID: "T1"))   // activa, no cerrada
        api.route = try route(truckID: "T2")
        await s.checkForNewRouteIfClosed()
        XCTAssertEqual(try s.repo.routeHeader()?.truckID, "T1", "ruta ACTIVA: no la reemplaza sola")

        try s.repo.markFinishedLocally()
        await s.checkForNewRouteIfClosed()
        XCTAssertEqual(try s.repo.routeHeader()?.truckID, "T2", "ruta CERRADA: sí busca la nueva")
    }

    // MARK: - Sin camión asignado → 404 claro

    func test_rutaCerrada_y404_muestraNoTienesRuta() async throws {
        let api = StubDispatchAPI()   // route nil → 404
        let s = try makeService(api)
        try s.repo.saveRoute(try route(truckID: "T1"))
        try s.repo.markFinishedLocally()
        await s.downloadRoute()
        XCTAssertEqual(s.downloadState, .noRouteAssigned, "cerrada + 404 → no tienes ruta asignada")
    }

    // MARK: - Logout limpia el snapshot, conserva cola/pagos

    func test_clearRoute_limpiaSnapshot_conservaColaYPagos() async throws {
        let api = StubDispatchAPI()
        let s = try makeService(api)
        try s.repo.saveRoute(try route(truckID: "T1"))
        // Trabajo sin sincronizar: una entrega en cola y un pago (dinero).
        try s.repo.enqueueDeliver(truckID: "T1", orderUUID: "O1", orderReason: .negocioCerrado,
                                  rejectedItems: nil, note: nil, occurredAt: Date(timeIntervalSince1970: 0))
        _ = s.registerPayment(truckID: "T1", clientCode: "C1", clientName: "Tienda", amount: 100,
                              type: .cash, checkNumber: nil, note: nil, photoPath: nil)

        s.clearRoute()

        XCTAssertFalse(try s.repo.hasRoute(), "el snapshot de ruta se limpió")
        XCTAssertEqual(s.downloadState, .notDownloaded, "el siguiente login empieza limpio")
        XCTAssertEqual(try s.repo.pendingActions().count, 1, "la cola NO se descarta")
        XCTAssertEqual(try s.repo.payments().count, 1, "★ los pagos NO se pierden (es dinero)")
    }

    // MARK: - Ruta nueva no descarta la cola anterior

    func test_rutaNueva_noDescartaLaColaPendiente() async throws {
        let api = StubDispatchAPI()
        let s = try makeService(api)
        try s.repo.saveRoute(try route(truckID: "T1"))
        try s.repo.enqueueDeliver(truckID: "T1", orderUUID: "O1", orderReason: .pedidoCancelado,
                                  rejectedItems: nil, note: nil, occurredAt: Date(timeIntervalSince1970: 0))
        _ = s.registerPayment(truckID: "T1", clientCode: "C1", clientName: "Tienda", amount: 50,
                              type: .cash, checkNumber: nil, note: nil, photoPath: nil)

        api.route = try route(truckID: "T2")
        await s.downloadRoute()

        XCTAssertEqual(try s.repo.routeHeader()?.truckID, "T2")
        XCTAssertEqual(try s.repo.pendingActions().count, 1, "la entrega anterior sigue en cola")
        XCTAssertEqual(try s.repo.payments().count, 1, "el pago anterior sigue registrado")
    }
}
