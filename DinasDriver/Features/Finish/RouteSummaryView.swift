import SwiftUI

/// Render del `RouteSummary` — el MISMO schema que devuelven `POST /dispatch/finish-route` (cierre) y
/// `GET /dispatch/routes/{truck_id}` (historial). Se dibuja en UN SOLO lugar para que la pantalla del
/// cierre y la del detalle muestren EXACTAMENTE lo mismo; no hay modelo ni vista paralela.
struct RouteSummaryView: View {
    let summary: RouteSummary

    var body: some View {
        Group {
            countRow("Entregados", summary.deliveredCount, .green)
            countRow("Parciales", summary.partialCount, .orange)
            countRow("No entregados", summary.notDeliveredCount, .red)
            countRow("Sin registrar", summary.pendingCount, .secondary)
            Label("\(Fmt.qty(summary.returnedItems.reduce(0) { $0 + $1.quantity })) unidades retornadas",
                  systemImage: "arrow.uturn.left").font(.callout)
        }
    }

    private func countRow(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack { Text(label); Spacer(); Text("\(count)").font(.headline).foregroundStyle(color) }
    }
}
