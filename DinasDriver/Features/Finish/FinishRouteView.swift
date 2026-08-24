import SwiftUI

/// "Terminar ruta": muestra el resumen y cierra la jornada. Offline, el resumen se deriva de lo
/// registrado (y distingue lo REGISTRADO-en-cola de lo confirmado); al sincronizar se reconcilia
/// con el `RouteSummary` del servidor.
struct FinishRouteView: View {
    @EnvironmentObject private var dispatch: DispatchService
    @State private var local = LocalRouteSummary()
    @State private var finished = false

    var body: some View {
        List {
            if let server = dispatch.serverSummary {
                serverSummarySection(server)
            } else {
                localSummarySection
                if !finished {
                    Section {
                        Button {
                            if let truckID = try? dispatch.repo.routeHeader()?.truckID {
                                dispatch.finishRoute(truckID: truckID)
                                finished = true
                            }
                        } label: {
                            Label("Terminar ruta", systemImage: "flag.checkered")
                                .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    } footer: {
                        Text("Los pedidos sin registrar quedan pendientes; la oficina los cierra si hace falta.")
                    }
                } else {
                    Section {
                        Label("Ruta cerrada. Se confirmará con la oficina al reconectar.",
                              systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Terminar ruta")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { reload() }
        .onReceive(dispatch.$pendingCount) { _ in reload() }
    }

    private var localSummarySection: some View {
        Section("Resumen") {
            countRow("Entregados", local.deliveredCount, .green)
            countRow("Parciales", local.partialCount, .orange)
            countRow("No entregados", local.notDeliveredCount, .red)
            countRow("Sin registrar", local.pendingCount, .secondary)
            if local.unsyncedDelivers > 0 {
                Label("\(local.unsyncedDelivers) registrados sin enviar todavía — es lo registrado, no lo confirmado por la oficina.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            Label("\(Fmt.qty(local.returnedItems.reduce(0) { $0 + $1.quantity })) unidades retornadas",
                  systemImage: "arrow.uturn.left")
                .font(.callout)
        }
    }

    private func serverSummarySection(_ s: RouteSummary) -> some View {
        Section("Ruta cerrada") {
            Label("Todo cuadra con la oficina", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            RouteSummaryView(summary: s)   // mismo render que el detalle del historial
        }
    }

    private func countRow(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").font(.headline).foregroundStyle(color)
        }
    }

    private func reload() {
        let orders = (try? dispatch.repo.allOrders()) ?? []
        let stops = (try? dispatch.repo.stops()) ?? []
        let pending = (try? dispatch.repo.pendingDelivers()) ?? []
        local = DispatchService.localSummary(orders: orders, stops: stops, pendingDelivers: pending)
    }
}
