import XCTest
@testable import DinasDriver

@MainActor
final class RouteHistoryTests: XCTestCase {

    // La lista decodifica ClosedRouteEntry: route_date presente vs null (cerró sin iniciar), y el
    // respaldo de nombre cuando truck_name es null.
    func test_lista_decodifica_routeDateYRespaldoDeNombre() throws {
        let json = Data(#"""
        {"page":1,"page_size":25,"total":2,"routes":[
          {"truck_id":"T-1","truck_name":"ALLENTOWN","route_date":"2026-08-23","started_at":"2026-08-23T13:00:00Z","finished_at":"2026-08-24T00:20:00Z","total_orders":4,"delivered_count":3,"not_delivered_count":1},
          {"truck_id":"T-2","truck_name":null,"route_date":null,"started_at":null,"finished_at":"2026-08-24T02:00:00Z","total_orders":0,"delivered_count":0,"not_delivered_count":0}
        ]}
        """#.utf8)
        let page = try JSONCoding.decoder.decode(ClosedRoutesPage.self, from: json)
        XCTAssertEqual(page.routes.count, 2)
        XCTAssertEqual(page.routes[0].id, "T-1", "la identidad es truck_id")
        XCTAssertNotNil(page.routes[0].routeDate)
        XCTAssertEqual(page.routes[0].displayName, "ALLENTOWN")
        // Segunda: cerró sin iniciar → route_date null (dato en sí), y nombre null → respaldo.
        XCTAssertNil(page.routes[1].routeDate)
        XCTAssertEqual(RouteHistoryView.dayLabel(page.routes[1].routeDate), "Sin iniciar")
        XCTAssertEqual(page.routes[1].displayName, "Camión T-2")
    }

    // El detalle devuelve el MISMO RouteSummary que el cierre (un solo schema, no un modelo paralelo).
    func test_detalle_devuelveElMismoRouteSummary() async throws {
        let api = StubDispatchAPI()
        api.routeDetail = RouteSummary(truckID: "T-1", truckName: "ALLENTOWN", startedAt: nil,
                                       finishedAt: nil, totalOrders: 4, deliveredCount: 3, partialCount: 0,
                                       notDeliveredCount: 1, pendingCount: 0, returnedItems: [])
        let db = try AppDatabase.makeInMemory()
        let s = DispatchService(database: db, api: api)
        let summary = try await s.routeDetail(truckID: "T-1")
        XCTAssertEqual(summary.deliveredCount, 3)
        XCTAssertEqual(summary.notDeliveredCount, 1)
        XCTAssertEqual(summary.truckID, "T-1")
    }
}
