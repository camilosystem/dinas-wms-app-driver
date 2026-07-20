import SwiftUI

/// "Retornados": lo que el cliente no recibió y vuelve en el camión, acumulado de toda la ruta.
/// Se deriva de lo registrado (offline), y se reconcilia con el servidor al cerrar.
struct ReturnsView: View {
    @EnvironmentObject private var dispatch: DispatchService
    @State private var items: [ReturnedItem] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nada retornado",
                    message: "Aquí se acumula lo que no se entregó y vuelve en el camión.",
                    systemImage: "arrow.uturn.left")
            } else {
                List {
                    Section {
                        Text("Total: \(Fmt.qty(items.reduce(0) { $0 + $1.quantity })) unidades en \(items.count) líneas")
                            .font(.callout.weight(.medium))
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.itemName).font(.body.weight(.medium))
                                Spacer()
                                Text("\(Fmt.qty(item.quantity)) uds").foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text("Pedido \(item.orderNumber)")
                                if !item.clientName.isEmpty { Text("· \(item.clientName)") }
                                if let reason = item.reason { Text("· \(reason.label)").foregroundStyle(.orange) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Retornados")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { reload() }
        .onReceive(dispatch.$pendingCount) { _ in reload() }
    }

    private func reload() {
        // Preferir el consolidado del servidor si ya cerró; si no, derivar de lo registrado.
        if let server = dispatch.serverSummary, !server.returnedItems.isEmpty {
            items = server.returnedItems
            return
        }
        let orders = (try? dispatch.repo.allOrders()) ?? []
        let stops = (try? dispatch.repo.stops()) ?? []
        let pending = (try? dispatch.repo.pendingDelivers()) ?? []
        items = DispatchService.localReturnedItems(orders: orders, stops: stops, pendingDelivers: pending)
    }
}
