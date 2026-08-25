import XCTest
@testable import DinasDriver

/// Dr2 (★ v0.80.0/v0.81.0): custodia del dinero. Las tres decisiones que el bloque protege, cada
/// una con el sabotaje que la ataca:
///  1. "Mi caja" NO se filtra por camión activo.
///  2. Declarar es una DECLARACIÓN, no una entrega confirmada (el texto lo dice).
///  3. El tiempo relativo NO recorta un futuro a cero (★ v0.81.0).
/// Más: el conteo de "deshacer" no se tapa, y los 409 se leen con su significado.
final class CustodyTests: XCTestCase {

    private func payment(_ uuid: String, truck: String?, amount: Double,
                         handedOver: Date? = nil, undoneCount: Int = 0,
                         deposit: String? = nil, voided: Bool = false) -> RemotePayment {
        RemotePayment(paymentUUID: uuid, truckID: truck, clientCode: "C\(uuid)", amount: amount,
                      occurredAt: Date(timeIntervalSince1970: 1000),
                      recordedAt: Date(timeIntervalSince1970: 1000),
                      handedOverAt: handedOver, handoverUndoneCount: undoneCount,
                      isVoided: voided, depositReference: deposit)
    }

    // 1 ─ SABOTAJE que importa: "Mi caja" muestra TODO lo no declarado, aunque sea de otra ruta
    //     (una cerrada). Es su caja, no la caja de una ruta. Si alguien filtra por el camión activo,
    //     el pago de la ruta cerrada desaparece y este test se pone rojo.
    func test_miCaja_noSeFiltraPorCamionActivo() {
        let cash = DriverCash(totalAmount: 280, payments: [
            payment("live", truck: "TRUCK-VIVO", amount: 30),
            payment("old",  truck: "TRUCK-CERRADO", amount: 250),   // de una ruta ya cerrada
        ])
        let shown = Custody.cashPayments(cash, activeTruckID: "TRUCK-VIVO")
        XCTAssertEqual(shown.count, 2, "la caja es del driver, no del camión: se ven las dos rutas")
        XCTAssertTrue(shown.contains { $0.paymentUUID == "old" },
                      "un pago sin declarar de una ruta CERRADA sigue siendo suyo y debe verse")
    }

    // 2 ─ El texto de la pantalla dice que DECLARA, y niega el acuse de recibo. Si alguien lo cambia
    //     por un lenguaje de "entrega confirmada" (sin 'declar' o sin negar la confirmación), rojo.
    func test_copyDeclaracion_diceDeclararYNiegaAcuse() {
        XCTAssertTrue(CustodyCopy.esLenguajeDeDeclaracion(CustodyCopy.declareDisclaimer),
                      "el aviso debe decir que DECLARA y que nadie lo confirma del otro lado")
        XCTAssertTrue(CustodyCopy.declareButton.lowercased().contains("declar"),
                      "el botón dice 'Declarar', no 'Entregar' a secas")
        // Un texto de entrega confirmada NO pasa la guardia.
        XCTAssertFalse(CustodyCopy.esLenguajeDeDeclaracion("Entrega confirmada por bodega"))
    }

    // 3 ─ SABOTAJE del recorte: un futuro (reloj adelantado) NO se colapsa a "ahora"/"hace 0".
    //     Taparlo cambiaría un dato sospechoso por uno plausible (★ v0.81.0).
    func test_tiempoRelativo_noRecortaUnFuturo() {
        let now = Date(timeIntervalSince1970: 100_000)
        // Futuro de 40 s (occurred_at por delante de ahora): se dice, no se oculta.
        let future = RelativeCustodyTime.text(now.addingTimeInterval(40), now: now)
        XCTAssertTrue(future.hasPrefix("en "), "un futuro se dice 'en …', no se recorta: \(future)")
        XCTAssertNotEqual(future, "ahora mismo")
        XCTAssertFalse(future.contains("hace"), "un futuro NO es 'hace …': \(future)")
        // Pasado normal.
        XCTAssertEqual(RelativeCustodyTime.text(now.addingTimeInterval(-40), now: now), "hace 40 s")
        // El caso de 19 horas antes (la refutación real por el otro lado): no asume reciente.
        XCTAssertEqual(RelativeCustodyTime.text(now.addingTimeInterval(-19*3600), now: now), "hace 19 h")
    }

    // 4 ─ Deshacer no se tapa: el conteo llega y se conserva al decodificar (la oficina ve la
    //     secuencia). Y los estados de custodia se derivan bien.
    func test_remotePayment_conservaConteoYEstados() throws {
        let json = """
        {"payment_uuid":"p1","client_code":"C1","client_name":"Tienda","amount":30.0,
         "payment_type":"CASH","invoice_doc_nums":["9021"],
         "occurred_at":"2026-08-24T03:50:00Z","recorded_at":"2026-08-24T22:48:01.7Z",
         "handed_over_at":null,"handover_undone_at":"2026-08-24T23:00:00Z",
         "handover_undone_count":5,"is_voided":false,"deposit_reference":null}
        """.data(using: .utf8)!
        let p = try JSONCoding.decoder.decode(RemotePayment.self, from: json)
        XCTAssertEqual(p.handoverUndoneCount, 5, "el conteo de deshacer no se tapa")
        XCTAssertFalse(p.isHandedOver, "handed_over_at null → no declarado (volvió a la caja)")
        XCTAssertFalse(p.isInDeposit)
    }

    // 5 ─ Los 409 se leen con su significado, no como un error genérico.
    func test_handoverOutcome_mapea409() {
        // Declarar un anulado → 409 = anulado.
        XCTAssertEqual(HandoverOutcome.from(APIError.server(status: 409, message: "El pago está anulado"),
                                            isUndo: false), .anulado)
        // Deshacer algo ya depositado → 409 = enDeposito.
        XCTAssertEqual(HandoverOutcome.from(APIError.server(status: 409, message: "El pago ya está en un depósito"),
                                            isUndo: true), .enDeposito)
        // Deshacer algo no declarado → 409 = noDeclarado.
        XCTAssertEqual(HandoverOutcome.from(APIError.server(status: 409, message: "no estaba declarado como entregado"),
                                            isUndo: true), .noDeclarado)
        // Sin red = sinRed (declarar es una acción en línea).
        XCTAssertEqual(HandoverOutcome.from(URLError(.notConnectedToInternet), isUndo: false), .sinRed)
    }

    // 6 ─ El servicio: declarar/deshacer refrescan la caja y traducen los 409.
    @MainActor
    func test_servicio_declararYDeshacer_traducen409() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubDispatchAPI()
        let s = DispatchService(database: db, api: api, now: { Date(timeIntervalSince1970: 1000) })

        api.myCash = DriverCash(totalAmount: 30, payments: [payment("p1", truck: "T", amount: 30)])
        await s.loadMyCash()
        XCTAssertEqual(s.cash?.payments.count, 1, "loadMyCash puebla la caja")

        // Declarar un anulado → anulado.
        api.handoverError = .server(status: 409, message: "El pago está anulado")
        let d = await s.declareHandover(paymentUUID: "p1")
        XCTAssertEqual(d, .anulado)

        // Deshacer algo ya depositado → enDeposito.
        api.handoverError = .server(status: 409, message: "El pago ya está en un depósito")
        let u = await s.undoHandover(paymentUUID: "p1")
        XCTAssertEqual(u, .enDeposito)
    }
}
