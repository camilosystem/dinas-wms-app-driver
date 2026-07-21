import XCTest
import GRDB
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import DinasDriver

/// Pagos en ruta (★ v0.16.0, Bloque 4C): CASH vs CHEQUE, payment_uuid idempotente generado al
/// crear, caja separada, anular que deja el rastro y no suma, offline sin duplicar.
@MainActor
final class PaymentsTests: XCTestCase {

    private func makeJPEG(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: width, by: 16) {
            ctx.setFillColor(CGColor(red: Double(x % 255) / 255, green: 0.3, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: height))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func tempPhotoStore() -> PhotoStore {
        PhotoStore(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("pay-test-\(UUID().uuidString)", isDirectory: true))
    }

    private func service(offline: Bool = false, photos: PhotoStore? = nil,
                         at: TimeInterval = 1000) -> (DispatchService, StubDispatchAPI) {
        let db = try! AppDatabase.makeInMemory()
        let api = StubDispatchAPI(); api.offline = offline
        let s = DispatchService(database: db, api: api, now: { Date(timeIntervalSince1970: at) },
                                photos: photos ?? tempPhotoStore())
        return (s, api)
    }

    // MARK: - CASH: sin foto ni número

    func test_cash_sinFotoNiNumero_generaUUID_ySincroniza() async throws {
        let (s, api) = service(offline: true)
        let uuid = s.registerPayment(truckID: "T1", clientCode: "C1", clientName: "Tienda Uno",
                                     amount: 100, type: .cash, checkNumber: nil, note: nil, photoPath: nil)
        // Registro local durable, sin foto ni número, con el uuid generado al crear.
        let p = try XCTUnwrap(try s.repo.payment(uuid: uuid))
        XCTAssertEqual(p.paymentType, .cash)
        XCTAssertNil(p.checkNumber); XCTAssertNil(p.photoPath)
        XCTAssertFalse(p.createSynced)
        XCTAssertEqual(try s.repo.pendingPaymentsCount(), 1, "un pago sin enviar cuenta")

        api.offline = false
        await s.syncPending()
        XCTAssertEqual(api.paymentCalls.count, 1)
        let req = try XCTUnwrap(api.paymentCalls.first)
        XCTAssertEqual(req.paymentUUID, uuid, "manda el uuid generado al crear")
        XCTAssertNil(req.checkNumber); XCTAssertNil(req.photoBase64, "CASH sin foto ni número")
        XCTAssertEqual(req.occurredAt, Date(timeIntervalSince1970: 1000), "occurred_at = hora real")
        XCTAssertTrue(try s.repo.payment(uuid: uuid)!.createSynced)
        XCTAssertEqual(try s.repo.pendingPaymentsCount(), 0)

        // Reintento: no duplica (createSynced ya está).
        await s.syncPending()
        XCTAssertEqual(api.paymentCalls.count, 1, "el reintento no duplica el dinero")
    }

    // MARK: - CHEQUE: exige número y foto; la foto se borra tras sync

    func test_cheque_conNumeroYFoto_sincroniza_yBorraLaFoto() async throws {
        let photos = tempPhotoStore()
        let (s, api) = service(offline: true, photos: photos)
        let path = try photos.saveResized(from: makeJPEG(width: 1600, height: 1200))
        let uuid = s.registerPayment(truckID: "T1", clientCode: "C1", clientName: "Tienda Uno",
                                     amount: 250, type: .cheque, checkNumber: "CHK-77", note: nil,
                                     photoPath: path)
        let p = try XCTUnwrap(try s.repo.payment(uuid: uuid))
        XCTAssertEqual(p.paymentType, .cheque)
        XCTAssertEqual(p.checkNumber, "CHK-77")
        XCTAssertEqual(p.photoPath, path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        api.offline = false
        await s.syncPending()
        let req = try XCTUnwrap(api.paymentCalls.first)
        XCTAssertEqual(req.checkNumber, "CHK-77")
        XCTAssertFalse(req.photoBase64?.isEmpty ?? true, "el cheque viaja con foto en base64")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "★ la foto se borra tras sincronizar")
    }

    // MARK: - Caja: separa CASH de CHEQUE

    func test_totalSeparaCashDeCheque() throws {
        let photos = tempPhotoStore()
        let (s, _) = service(photos: photos)
        s.registerPayment(truckID: "T1", clientCode: "C1", clientName: "A", amount: 100,
                          type: .cash, checkNumber: nil, note: nil, photoPath: nil)
        s.registerPayment(truckID: "T1", clientCode: "C2", clientName: "B", amount: 50,
                          type: .cash, checkNumber: nil, note: nil, photoPath: nil)
        let path = try photos.saveResized(from: makeJPEG(width: 800, height: 600))
        s.registerPayment(truckID: "T1", clientCode: "C3", clientName: "C", amount: 200,
                          type: .cheque, checkNumber: "CHK-1", note: nil, photoPath: path)

        let t = try s.repo.cajaTotals()
        XCTAssertEqual(t.cash, 150)
        XCTAssertEqual(t.cheque, 200)
        XCTAssertEqual(t.grand, 350)
        XCTAssertEqual(t.count, 3)
    }

    // MARK: - Anular: exige motivo, sigue visible marcado, no suma, y sincroniza

    func test_anular_dejaRastro_noSuma_ySincroniza() async throws {
        let (s, api) = service()
        let uuid = s.registerPayment(truckID: "T1", clientCode: "C1", clientName: "Tienda", amount: 100,
                                     type: .cash, checkNumber: nil, note: nil, photoPath: nil)
        XCTAssertEqual(try s.repo.cajaTotals().cash, 100)

        s.voidPayment(paymentUUID: uuid, reason: "monto equivocado")

        let p = try XCTUnwrap(try s.repo.payment(uuid: uuid))
        XCTAssertTrue(p.isVoided)
        XCTAssertEqual(p.voidReason, "monto equivocado", "el motivo queda registrado")
        XCTAssertTrue(try s.repo.payments().contains { $0.paymentUUID == uuid },
                      "el pago NO desaparece: sigue visible marcado")
        XCTAssertEqual(try s.repo.cajaTotals().cash, 0, "un anulado NO suma")
        XCTAssertEqual(try s.repo.cajaTotals().voidedCount, 1)

        await s.syncPending()
        XCTAssertEqual(api.voidCalls.count, 1)
        XCTAssertEqual(api.voidCalls.first?.uuid, uuid)
        XCTAssertEqual(api.voidCalls.first?.request.reason, "monto equivocado")
    }
}
