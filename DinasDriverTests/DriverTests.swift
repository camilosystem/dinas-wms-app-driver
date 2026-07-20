import XCTest
import GRDB
@testable import DinasDriver

/// Despacho (★ v0.14.0): descarga offline, cola optimista con `occurred_at` verbatim, replay
/// idempotente, novedades/salida rápida excluyentes, reorden local device-only, retornados y cierre.
@MainActor
final class DriverTests: XCTestCase {

    // MARK: - Fixtures

    /// Ruta con 2 paradas: C1 (pedido O1, 2 líneas, incompleto) y C2 (pedido O2, 1 línea).
    private func makeRoute(started: Bool = false) throws -> RouteDownload {
        let startedField = started ? "\"2026-07-20T08:30:00Z\"" : "null"
        let json = Data("""
        {"truck_id":"TRK-1","truck_name":"Camión 1","status":"ASIGNADO_DRIVER",
         "downloaded_at":"2026-07-20T08:00:00Z","started_at":\(startedField),
         "total_stops":2,"total_orders":2,"pending_orders":2,
         "stops":[
           {"stop_number":1,"client_code":"C1","client_name":"Tienda Uno","address":"Calle 1",
            "city":"Queens","zip_code":"11101","phone":"555-1",
            "orders":[{"order_uuid":"O1","order_number":"N-1","total_amount":100.0,"total_units":5,
                       "pallet_labels":["Q-Reg-1"],"is_incomplete_delivery":true,
                       "lines":[{"item_code":"A","item_name":"Item A","quantity":3},
                                {"item_code":"B","item_name":"Item B","quantity":2}]}]},
           {"stop_number":2,"client_code":"C2","client_name":"Tienda Dos","address":"Calle 2",
            "city":"Queens","zip_code":"11102","phone":null,
            "orders":[{"order_uuid":"O2","order_number":"N-2","total_amount":50.0,"total_units":2,
                       "pallet_labels":[],"is_incomplete_delivery":false,
                       "lines":[{"item_code":"C","item_name":"Item C","quantity":2}]}]}
         ]}
        """.utf8)
        return try JSONCoding.decoder.decode(RouteDownload.self, from: json)
    }

    private func makeService(_ db: AppDatabase, api: StubDispatchAPI,
                             now: @escaping () -> Date = { Date(timeIntervalSince1970: 1000) }) -> DispatchService {
        DispatchService(database: db, api: api, now: now)
    }

    // MARK: - Login DRIVER

    func test_login_aceptaDriver_rechazaOtroRol() async {
        let hasher = PBKDF2Hasher(iterations: 1_000)
        func auth(role: String) -> AuthSession {
            let api = StubDriverAuthAPI(role: role)
            return AuthSession(api: api, store: InMemorySessionStore(), hasher: hasher,
                               requiredRole: "DRIVER", now: { Date(timeIntervalSince1970: 100) })
        }
        let ok = auth(role: "DRIVER")
        await ok.login(username: "driver1", password: "x", isOnline: true)
        XCTAssertEqual(ok.state, .signedIn, "un DRIVER entra")

        let bad = auth(role: "BODEGUERO")
        await bad.login(username: "b", password: "x", isOnline: true)
        XCTAssertNotEqual(bad.state, .signedIn, "otro rol NO entra")
        XCTAssertEqual(bad.loginFailure, .wrongRole, "otro rol se rechaza")
    }

    // MARK: - Descarga / estados

    func test_sinRutaDescargada_estadoNotDownloaded() throws {
        let db = try AppDatabase.makeInMemory()
        let service = makeService(db, api: StubDispatchAPI())
        XCTAssertEqual(service.downloadState, .notDownloaded, "sin snapshot → aviso de descarga")
    }

    func test_sinCamionAsignado_estado404() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI()   // route nil → 404
        let service = makeService(db, api: api)
        await service.downloadRoute()
        XCTAssertEqual(service.downloadState, .noRouteAssigned, "404 → no tienes ruta asignada")
    }

    func test_descarga_guardaTodoYFuncionaOffline() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI()
        api.route = try makeRoute()
        let service = makeService(db, api: api)
        await service.downloadRoute()
        XCTAssertEqual(service.downloadState, .downloaded)

        // "Offline": todo se lee de la base, sin red.
        api.offline = true
        let stops = try service.repo.stops()
        XCTAssertEqual(stops.map(\.clientCode), ["C1", "C2"], "paradas en orden del admin")
        let o1 = try service.repo.orders(forClient: "C1")
        XCTAssertEqual(o1.first?.orderUUID, "O1")
        XCTAssertEqual(o1.first?.lines.count, 2, "líneas persistidas")
        XCTAssertTrue(o1.first?.isIncompleteDelivery ?? false, "el flag de picking incompleto viaja")
        XCTAssertEqual(o1.first?.palletLabels, ["Q-Reg-1"], "pallet_labels persistidos")
    }

    // MARK: - Iniciar ruta

    func test_iniciarRuta_marcaLocalYEncola() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = makeService(db, api: api)
        await service.downloadRoute()

        service.startRoute(truckID: "TRK-1")
        XCTAssertNotNil(try service.repo.routeHeader()?.startedAt, "marca local optimista")

        await service.syncPending()
        XCTAssertEqual(api.startRouteCalls, 1, "se envió start-route")
        XCTAssertEqual(try service.repo.pendingCount(), 0)
    }

    // MARK: - Entregas (los 3 casos + exclusión)

    func test_confirmarCompleto_provisionalYSincroniza() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute(); api.offline = true
        let service = makeService(db, api: api)
        await service.downloadRoute()   // offline pero ya venía cacheada... re-descarga: la guardamos online antes
        // Aseguramos snapshot:
        api.offline = false; await service.downloadRoute(); api.offline = true

        service.deliver(truckID: "TRK-1", orderUUID: "O1")   // entregado completo
        let pend = try XCTUnwrap(try service.repo.pendingDelivers().first)
        let display = DispatchService.display(order: try XCTUnwrap(service.repo.order(uuid: "O1")), pending: pend)
        XCTAssertEqual(display.status, .entregado)
        XCTAssertTrue(display.isPending, "registrado, aún sin confirmar")

        api.offline = false
        await service.syncPending()
        let req = try XCTUnwrap(api.deliverCalls.first)
        XCTAssertNil(req.request.orderReason)
        XCTAssertNil(req.request.rejectedItems)
        XCTAssertEqual(try service.repo.order(uuid: "O1")?.deliveryStatus, .entregado, "estado del server plegado")
    }

    func test_itemNoEntregado_conCantidadYMotivo() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = makeService(db, api: api)
        await service.downloadRoute()

        service.deliver(truckID: "TRK-1", orderUUID: "O1",
                        rejectedItems: [RejectedItemInput(itemCode: "A", itemName: "Item A",
                                                          quantity: 1, reason: .danado)])
        await service.syncPending()
        let req = try XCTUnwrap(api.deliverCalls.first)
        XCTAssertNil(req.request.orderReason)
        XCTAssertEqual(req.request.rejectedItems?.count, 1)
        XCTAssertEqual(req.request.rejectedItems?.first?.itemCode, "A")
        XCTAssertEqual(req.request.rejectedItems?.first?.quantity, 1)
        XCTAssertEqual(req.request.rejectedItems?.first?.reason, .danado)
        XCTAssertEqual(try service.repo.order(uuid: "O1")?.deliveryStatus, .entregadoParcial)
    }

    func test_salidaRapida_noSeEntrego_conMotivoDePedido() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = makeService(db, api: api)
        await service.downloadRoute()

        service.deliver(truckID: "TRK-1", orderUUID: "O2", orderReason: .negocioCerrado)
        await service.syncPending()
        let req = try XCTUnwrap(api.deliverCalls.first)
        XCTAssertEqual(req.request.orderReason, .negocioCerrado)
        XCTAssertNil(req.request.rejectedItems, "salida rápida no manda ítems")
        XCTAssertEqual(try service.repo.order(uuid: "O2")?.deliveryStatus, .noEntregado)
    }

    func test_nuncaSeMandanAmbos_motivoYItems() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = makeService(db, api: api)
        await service.downloadRoute()

        // Los tres caminos de la UI, cada uno excluyente:
        service.deliver(truckID: "TRK-1", orderUUID: "O1")                                   // completo
        service.deliver(truckID: "TRK-1", orderUUID: "O2", orderReason: .pedidoCancelado)     // no entregó
        await service.syncPending()
        for call in api.deliverCalls {
            let both = call.request.orderReason != nil && (call.request.rejectedItems?.isEmpty == false)
            XCTAssertFalse(both, "jamás order_reason y rejected_items juntos")
        }
    }

    // MARK: - Reorden local (device-only)

    func test_reordenar_noBloquea_noMandaNada_persiste() throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI()
        let service = makeService(db, api: api)
        // Semilla del snapshot (sync).
        try service.repo.saveRoute(try makeRoute())

        try service.repo.saveLocalOrder(truckID: "TRK-1", clientCodes: ["C2", "C1"])
        XCTAssertEqual(try service.repo.stops().map(\.clientCode), ["C2", "C1"], "reordena la vista")
        XCTAssertEqual(try service.repo.pendingCount(), 0, "reordenar NO encola nada")
        XCTAssertTrue(api.deliverCalls.isEmpty)
        XCTAssertEqual(api.startRouteCalls, 0, "no se manda nada al servidor")

        // Sobrevive a un repo nuevo (persistente entre reinicios).
        let repo2 = DriverRepository(database: db)
        XCTAssertEqual(try repo2.stops().map(\.clientCode), ["C2", "C1"])
    }

    // MARK: - Offline: encola y sincroniza sin duplicar

    func test_offline_encola_ySincronizaSinDuplicar() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = makeService(db, api: api)
        try service.repo.saveRoute(api.route!)

        // Sin red: encola.
        try service.repo.enqueueDeliver(truckID: "TRK-1", orderUUID: "O1", orderReason: nil,
                                        rejectedItems: nil, note: nil, occurredAt: Date(timeIntervalSince1970: 500))
        api.offline = true
        await service.syncPending()
        XCTAssertEqual(try service.repo.pendingCount(), 1, "sin red, queda pendiente")
        XCTAssertTrue(api.deliverCalls.isEmpty)

        // Vuelve la red: se envía UNA vez.
        api.offline = false
        await service.syncPending()
        XCTAssertEqual(api.deliverCalls.count, 1)
        XCTAssertEqual(try service.repo.pendingCount(), 0)

        // Reintento: no duplica.
        await service.syncPending()
        XCTAssertEqual(api.deliverCalls.count, 1, "el replay no duplica")
    }

    func test_occurredAt_viajaLaHoraDelRegistro_noLaDeSync() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        var clock = Date(timeIntervalSince1970: 1_000)
        let service = DispatchService(database: db, api: api, now: { clock })
        try service.repo.saveRoute(api.route!)

        let registro = Date(timeIntervalSince1970: 2_000)   // hora REAL en la calle
        try service.repo.enqueueDeliver(truckID: "TRK-1", orderUUID: "O1", orderReason: nil,
                                        rejectedItems: nil, note: nil, occurredAt: registro)
        clock = Date(timeIntervalSince1970: 9_999)          // sincroniza mucho después
        await service.syncPending()
        XCTAssertEqual(api.deliverCalls.first?.request.occurredAt, registro,
                       "occurred_at = hora del registro, no la de sincronización")
    }

    // MARK: - Retornados

    func test_retornados_acumulaLoNoEntregado() throws {
        let db = try AppDatabase.makeInMemory()
        let service = makeService(db, api: StubDispatchAPI())
        try service.repo.saveRoute(try makeRoute())
        // O1: parcial (rechaza 1 de A). O2: no se entregó (todo el pedido vuelve).
        try service.repo.enqueueDeliver(truckID: "TRK-1", orderUUID: "O1", orderReason: nil,
                                        rejectedItems: [RejectedItemInput(itemCode: "A", itemName: "Item A",
                                                                          quantity: 1, reason: .short)],
                                        note: nil, occurredAt: Date(timeIntervalSince1970: 0))
        try service.repo.enqueueDeliver(truckID: "TRK-1", orderUUID: "O2", orderReason: .negocioCerrado,
                                        rejectedItems: nil, note: nil, occurredAt: Date(timeIntervalSince1970: 0))

        let returned = DispatchService.localReturnedItems(
            orders: try service.repo.allOrders(), stops: try service.repo.stops(),
            pendingDelivers: try service.repo.pendingDelivers())
        // A (1 de O1) + C (2 de O2, todo el pedido).
        XCTAssertEqual(returned.count, 2)
        XCTAssertEqual(returned.first(where: { $0.itemCode == "A" })?.quantity, 1)
        XCTAssertEqual(returned.first(where: { $0.itemCode == "C" })?.quantity, 2)
    }

    // MARK: - Terminar ruta

    func test_terminarRuta_muestraResumen() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        api.summary = RouteSummary(truckID: "TRK-1", totalOrders: 2, deliveredCount: 1,
                                   notDeliveredCount: 1)
        let service = makeService(db, api: api)
        try service.repo.saveRoute(api.route!)

        // Registro local: O1 entregado, O2 no entregado.
        service.deliver(truckID: "TRK-1", orderUUID: "O1")
        service.deliver(truckID: "TRK-1", orderUUID: "O2", orderReason: .pedidoCancelado)
        let localSummary = DispatchService.localSummary(
            orders: try service.repo.allOrders(), stops: try service.repo.stops(),
            pendingDelivers: try service.repo.pendingDelivers())
        XCTAssertEqual(localSummary.deliveredCount, 1)
        XCTAssertEqual(localSummary.notDeliveredCount, 1)

        service.finishRoute(truckID: "TRK-1")
        await service.syncPending()
        XCTAssertEqual(api.finishCalls, 1)
        XCTAssertEqual(service.serverSummary?.deliveredCount, 1, "el resumen del server llegó")
    }
}

/// Stub de auth mínimo para el test de rol.
private struct StubDriverAuthAPI: AuthAPI, @unchecked Sendable {
    let role: String
    func login(username: String, password: String) async throws -> LoginResponse {
        LoginResponse(token: "T", role: role, salespersonCode: nil, displayName: "D")
    }
}
