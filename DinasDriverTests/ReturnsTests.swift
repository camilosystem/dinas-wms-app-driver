import XCTest
import GRDB
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import DinasDriver

/// Retorno de producto (★ v0.15.0, Bloque 4B): catálogo offline, foto redimensionada guardada en
/// disco (la cola guarda la RUTA), replay idempotente que borra la foto al sincronizar.
@MainActor
final class ReturnsTests: XCTestCase {

    /// Ruta con 1 parada (C1) + catálogo de 3 ítems para buscar.
    private func makeRoute() throws -> RouteDownload {
        let json = Data("""
        {"truck_id":"TRK-1","truck_name":"Camión 1","status":"EN_RUTA",
         "downloaded_at":"2026-07-20T08:00:00Z","started_at":"2026-07-20T08:30:00Z",
         "total_stops":1,"total_orders":1,"pending_orders":1,
         "stops":[{"stop_number":1,"client_code":"C1","client_name":"Tienda Uno",
                   "orders":[{"order_uuid":"O1","order_number":"N-1","lines":[]}]}],
         "item_catalog":[
           {"item_code":"CANOA-01","item_name":"Canoa Frozen Mango Pulp"},
           {"item_code":"CANOA-02","item_name":"Canoa Frozen Lulo Pulp"},
           {"item_code":"AREPA-99","item_name":"Arepa Tradicional 10u"}]}
        """.utf8)
        return try JSONCoding.decoder.decode(RouteDownload.self, from: json)
    }

    /// Genera un JPEG "grande" de prueba (con algo de detalle para que no comprima a nada).
    private func makeJPEG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: width, by: 16) {
            ctx.setFillColor(CGColor(red: Double(x % 255) / 255, green: 0.3, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: height))
        }
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func pixelWidth(_ data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int else { return 0 }
        return w
    }

    private func tempPhotoStore() -> PhotoStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("returns-test-\(UUID().uuidString)", isDirectory: true)
        return PhotoStore(folder: dir)
    }

    // MARK: - Catálogo

    func test_buscaCatalogo_porCodigoYPorNombre() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = DriverRepository(database: db)
        try repo.saveRoute(try makeRoute())

        XCTAssertEqual(try repo.searchCatalog("CANOA").count, 2, "por código (prefijo CANOA)")
        XCTAssertEqual(try repo.searchCatalog("Lulo").first?.itemCode, "CANOA-02", "por nombre")
        XCTAssertEqual(try repo.searchCatalog("AREPA-99").first?.itemName, "Arepa Tradicional 10u")
        XCTAssertTrue(try repo.searchCatalog("no-existe-xyz").isEmpty)
    }

    func test_clienteSoloDeSuRuta() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = DriverRepository(database: db)
        try repo.saveRoute(try makeRoute())
        XCTAssertTrue(try repo.isClientOnRoute("C1"), "cliente de su ruta")
        XCTAssertFalse(try repo.isClientOnRoute("C-OTRO"), "cliente que NO es de su ruta")
    }

    // MARK: - Foto

    func test_fotoSeRedimensiona_aTamanoDeEvidencia() throws {
        let big = makeJPEG(width: 3000, height: 2000)
        let resized = try XCTUnwrap(PhotoStore.resizedJPEG(from: big))
        XCTAssertLessThanOrEqual(pixelWidth(resized), 1024, "lado mayor ≤ 1024px")
        XCTAssertLessThan(resized.count, 300_000, "pesa menos de 300KB")
        XCTAssertLessThan(resized.count, big.count, "más liviana que la original")
    }

    // MARK: - Offline: encola, sincroniza sin duplicar, borra la foto

    func test_offline_encola_sincronizaSinDuplicar_yBorraLaFoto() async throws {
        let db = try AppDatabase.makeInMemory()
        let photos = tempPhotoStore()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = DispatchService(database: db, api: api, now: { Date(timeIntervalSince1970: 1000) },
                                      photos: photos)
        try service.repo.saveRoute(api.route!)

        // Foto en disco (redimensionada). La cola guarda la RUTA, no los bytes.
        let path = try photos.saveResized(from: makeJPEG(width: 2000, height: 1500))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let registro = Date(timeIntervalSince1970: 5000)   // hora de la visita
        try service.repo.enqueueReturn(
            truckID: "TRK-1", returnUUID: "RET-FIXED", clientCode: "C1",
            items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Frozen Mango Pulp",
                                           quantity: 3, reason: .danado),
                    ProductReturnItemInput(itemCode: "AREPA-99", itemName: "Arepa Tradicional 10u",
                                           quantity: 2, reason: .expirado)],
            note: "caja golpeada", clientReference: "F-123", photoPath: path, occurredAt: registro)

        // Sin red: queda pendiente, no se envía, la foto SIGUE en el teléfono.
        api.offline = true
        await service.syncPending()
        XCTAssertEqual(try service.repo.pendingCount(), 1)
        XCTAssertTrue(api.returnCalls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Vuelve la red: se envía UNA vez, con occurred_at verbatim y la foto en base64.
        api.offline = false
        await service.syncPending()
        XCTAssertEqual(api.returnCalls.count, 1)
        let req = try XCTUnwrap(api.returnCalls.first)
        XCTAssertEqual(req.clientCode, "C1")
        XCTAssertEqual(req.items.count, 2, "varios ítems en un retorno")
        XCTAssertEqual(req.occurredAt, registro, "occurred_at = hora de la visita, no la de sync")
        XCTAssertEqual(req.returnUUID, "RET-FIXED", "manda el return_uuid guardado en la cola")
        XCTAssertEqual(req.photoBase64?.isEmpty, false, "con foto, viaja en base64")
        XCTAssertEqual(req.clientReference, "F-123")
        XCTAssertEqual(try service.repo.pendingCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "★ la foto se borra del teléfono tras sincronizar")

        // Reintento: no duplica.
        await service.syncPending()
        XCTAssertEqual(api.returnCalls.count, 1, "el replay no duplica el retorno")
    }

    // MARK: - Dr3 (★ v0.68.0): retorno SIN foto, de punta a punta y sin conexión

    /// El escenario real de Dr3: driver sin foto es casi siempre driver sin señal. El retorno sin
    /// foto se encola, SOBREVIVE offline, y sube cuando vuelve la señal — OMITIENDO la clave
    /// `photo_base64` (la ausencia de un hecho no es un valor; el server deriva `has_photo`).
    /// SABOTAJE: si algún borde vuelve a exigir la foto, la subida sin foto se cae → returnCalls
    /// queda vacío y esto se pone rojo.
    func test_offline_sinFoto_encola_sobrevive_ySubeOmitiendoLaClave() async throws {
        let db = try AppDatabase.makeInMemory()
        let photos = tempPhotoStore()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = DispatchService(database: db, api: api, now: { Date(timeIntervalSince1970: 2000) },
                                      photos: photos)
        try service.repo.saveRoute(api.route!)

        // Registrar SIN foto (photoPath: nil) — acto deliberado del driver.
        try service.repo.enqueueReturn(
            truckID: "TRK-1", returnUUID: "RET-SINFOTO", clientCode: "C1",
            items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Frozen Mango Pulp",
                                           quantity: 1, reason: .danado)],
            note: nil, clientReference: nil, photoPath: nil, occurredAt: Date(timeIntervalSince1970: 6000))

        // Sin señal: sobrevive encolado, no se envía.
        api.offline = true
        await service.syncPending()
        XCTAssertEqual(try service.repo.pendingCount(), 1, "sobrevive encolado sin señal")
        XCTAssertTrue(api.returnCalls.isEmpty)

        // Vuelve la señal: sube UNA vez, SIN foto.
        api.offline = false
        await service.syncPending()
        XCTAssertEqual(api.returnCalls.count, 1)
        let req = try XCTUnwrap(api.returnCalls.first)
        XCTAssertNil(req.photoBase64, "sin foto → base64 nil")
        // La clave se OMITE en el JSON (no viaja como null): es lo que el contrato v0.68.0 fijó.
        let json = String(decoding: try JSONCoding.encoder.encode(req), as: UTF8.self)
        XCTAssertFalse(json.contains("photo_base64"), "la clave se omite; la ausencia no es un valor")
        XCTAssertEqual(try service.repo.pendingCount(), 0, "entró: ya no está en la cola")
    }

    /// Foto ROTA ≠ sin foto. Un retorno que SÍ tiene foto (photoPath != nil) pero cuyo archivo no
    /// está / no se puede leer NO se degrada a "sin foto": falla RUIDOSAMENTE (queda .failed), no se
    /// sube como si el driver hubiera elegido no sacarla. Si los dos terminaran igual, el driver
    /// perdería una evidencia que sí tomó y nadie se enteraría.
    /// SABOTAJE: si el borde de subida convierte el archivo ausente en "sin foto", returnCalls
    /// tendría 1 (con base64 nil) y failedActionsCount 0 → esto se pone rojo.
    func test_fotoPerdida_noSeDegradaASinFoto_fallaRuidosamente() async throws {
        let db = try AppDatabase.makeInMemory()
        let photos = tempPhotoStore()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let service = DispatchService(database: db, api: api, photos: photos)
        try service.repo.saveRoute(api.route!)

        // photoPath apunta a un archivo que NO existe (se perdió al guardar/subir).
        let lost = photos.folder.appendingPathComponent("no-existe-\(UUID().uuidString).jpg").path
        try service.repo.enqueueReturn(
            truckID: "TRK-1", returnUUID: "RET-PERDIDA", clientCode: "C1",
            items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Frozen Mango Pulp",
                                           quantity: 1, reason: .danado)],
            note: nil, clientReference: nil, photoPath: lost, occurredAt: Date(timeIntervalSince1970: 6000))

        api.offline = false
        await service.syncPending()

        XCTAssertTrue(api.returnCalls.isEmpty, "NO se sube: una foto perdida no se manda como 'sin foto'")
        XCTAssertEqual(try service.repo.failedActionsCount(), 1, "falla ruidosamente (.failed), no en silencio")
    }

    /// El `return_uuid` se genera al CREAR (registerReturn) y se guarda en la cola — NO al enviar.
    /// Así el reintento (que reconstruye el request desde la cola) manda el MISMO uuid. Que el
    /// uuid enviado sea el guardado y no duplique lo cubre `test_offline_...` (con "RET-FIXED").
    func test_returnUUID_seGeneraAlCrear_ySeGuardaEnLaCola() throws {
        let db = try AppDatabase.makeInMemory()
        let photos = tempPhotoStore()
        let api = StubDispatchAPI(); api.route = try makeRoute()
        api.offline = true
        let service = DispatchService(database: db, api: api, photos: photos)
        try service.repo.saveRoute(api.route!)
        let path = try photos.saveResized(from: makeJPEG(width: 1600, height: 1200))

        let uuid = service.registerReturn(
            kind: .spontaneous, truckID: "TRK-1", clientCode: "C1",
            items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Frozen Mango Pulp",
                                           quantity: 1, reason: .danado)],
            note: nil, clientReference: nil, photoPath: path)

        XCTAssertFalse(uuid.isEmpty)
        let pending = try XCTUnwrap(try service.repo.pendingActions().first)
        XCTAssertEqual(pending.kind, .productReturn)
        XCTAssertEqual(pending.returnUUID, uuid,
                       "el uuid se generó al crear y quedó en la cola (mismo en cada reintento)")
    }
}
