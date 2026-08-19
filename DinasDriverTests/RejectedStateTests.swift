import XCTest
import GRDB
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import DinasDriver

/// Estado visible unificado de los registros RECHAZADOS (entregas, retornos, pagos): el detalle
/// vive en cada acción, y una señal AGREGADA en la pantalla principal para que el driver los note
/// sin recorrer parada por parada.
@MainActor
final class RejectedStateTests: XCTestCase {

    private func makeRoute() throws -> RouteDownload {
        let json = Data("""
        {"truck_id":"TRK-1","status":"EN_RUTA","total_stops":1,"total_orders":1,"pending_orders":1,
         "stops":[{"stop_number":1,"client_code":"C1","client_name":"Tienda Uno",
                   "orders":[{"order_uuid":"O1","order_number":"N-1","lines":[]}]}],
         "item_catalog":[{"item_code":"CANOA-01","item_name":"Canoa Mango"}]}
        """.utf8)
        return try JSONCoding.decoder.decode(RouteDownload.self, from: json)
    }

    private func makeService(_ api: StubDispatchAPI) throws -> DispatchService {
        let db = try AppDatabase.makeInMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rej-\(UUID().uuidString)")
        let s = DispatchService(database: db, api: api, now: { Date(timeIntervalSince1970: 1000) },
                                photos: PhotoStore(folder: dir))
        try s.repo.saveRoute(api.route!)
        return s
    }

    /// Encola una entrega, un retorno espontáneo y un pago, y los deja RECHAZADOS por el servidor.
    private func enqueueThreeAndReject(_ s: DispatchService, _ api: StubDispatchAPI) async throws {
        api.offline = true
        s.deliver(truckID: "TRK-1", orderUUID: "O1")
        let path = try s.photos.saveResized(from: tinyJPEG())
        s.registerReturn(kind: .spontaneous, truckID: "TRK-1", clientCode: "C1",
                         items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Mango",
                                                        quantity: 2, reason: .danado)],
                         note: nil, clientReference: nil, photoPath: path)
        s.registerPayment(truckID: "TRK-1", clientCode: "C1", clientName: "Tienda Uno", amount: 100,
                          type: .cash, checkNumber: nil, note: nil, photoPath: nil)
        // El servidor rechaza todo de forma permanente.
        api.offline = false
        api.permanentError = .server(status: 400, message: "rechazado por la oficina")
        await s.syncPending()
    }

    // Señal AGREGADA: cuenta los tres, y cada uno se ve en su lugar. (Sabotaje: no contar → rojo.)
    func test_senalAgregada_cuentaLosTres_yCadaUnoSeVeEnSuLugar() async throws {
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let s = try makeService(api)
        try await enqueueThreeAndReject(s, api)

        XCTAssertEqual(s.rejectedCount, 3, "la señal agregada suma entrega + retorno + pago rechazados")
        // Estado donde vive cada acción:
        XCTAssertEqual(try s.repo.failedDeliverAction(orderUUID: "O1")?.errorMessage, "rechazado por la oficina")
        XCTAssertEqual(try s.repo.failedReturns(clientCode: "C1").count, 1)
        XCTAssertTrue(try XCTUnwrap(s.repo.payments().first).isRejected)
    }

    // PAR NEGATIVO: un fallo de RED no marca nada como rechazado ni prende la señal.
    func test_falloDeRed_noPrendeLaSenal_niMarcaRechazos() async throws {
        let api = StubDispatchAPI(); api.route = try makeRoute()
        let s = try makeService(api)
        api.offline = true            // sin señal en todo momento
        s.deliver(truckID: "TRK-1", orderUUID: "O1")
        let path = try s.photos.saveResized(from: tinyJPEG())
        s.registerReturn(kind: .spontaneous, truckID: "TRK-1", clientCode: "C1",
                         items: [ProductReturnItemInput(itemCode: "CANOA-01", itemName: "Canoa Mango",
                                                        quantity: 2, reason: .danado)],
                         note: nil, clientReference: nil, photoPath: path)
        s.registerPayment(truckID: "TRK-1", clientCode: "C1", clientName: "T", amount: 100,
                          type: .cash, checkNumber: nil, note: nil, photoPath: nil)
        await s.syncPending()   // sigue offline → transitorio

        XCTAssertEqual(s.rejectedCount, 0, "sin señal no es rechazo: nada se marca, la señal no prende")
        XCTAssertNil(try s.repo.failedDeliverAction(orderUUID: "O1"))
        XCTAssertTrue(try s.repo.failedReturns(clientCode: "C1").isEmpty)
        XCTAssertFalse(try XCTUnwrap(s.repo.payments().first).isRejected)
        XCTAssertGreaterThan(s.pendingCount, 0, "siguen pendientes, esperando red")
    }

    private func tinyJPEG() -> Data {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: w, by: 16) {
            ctx.setFillColor(CGColor(red: Double(x % 255) / 255, green: 0.3, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: h))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
