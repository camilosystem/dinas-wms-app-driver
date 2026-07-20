import SwiftUI

/// "Parada": el cliente, su dirección (solo texto, sin navegación) y sus pedidos. Cada pedido
/// lleva al detalle para confirmar la entrega.
struct StopView: View {
    @EnvironmentObject private var dispatch: DispatchService
    let stop: DriverStop
    @State private var orders: [DriverOrder] = []
    @State private var pendingByOrder: [String: PendingAction] = [:]

    var body: some View {
        List {
            Section("Cliente") {
                Text(stop.clientName).font(.headline)
                if let address = stop.address, !address.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(address).textSelection(.enabled)
                            if let city = stop.city, !city.isEmpty {
                                Text([city, stop.zipCode].compactMap { $0 }.joined(separator: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let phone = stop.phone, !phone.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "phone").foregroundStyle(.secondary)
                        Text(phone).textSelection(.enabled)
                    }
                }
            }

            Section("Pedidos") {
                ForEach(orders) { order in
                    NavigationLink {
                        OrderDeliveryView(orderUUID: order.orderUUID)
                    } label: {
                        OrderRow(order: order,
                                 display: DispatchService.display(order: order,
                                                                  pending: pendingByOrder[order.orderUUID.lowercased()]))
                    }
                }
            }
        }
        .navigationTitle("Parada \(stop.stopNumber)")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { reload() }
        .onReceive(dispatch.$pendingCount) { _ in reload() }
    }

    private func reload() {
        orders = (try? dispatch.repo.orders(forClient: stop.clientCode)) ?? []
        let pending = (try? dispatch.repo.pendingDelivers()) ?? []
        pendingByOrder = Dictionary(pending.compactMap { a in a.orderUUID.map { ($0.lowercased(), a) } },
                                    uniquingKeysWith: { a, _ in a })
    }
}

/// Fila de un pedido en la parada: número, unidades y su estado de entrega (reflejo).
struct OrderRow: View {
    let order: DriverOrder
    let display: DeliveryDisplay

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pedido \(order.orderNumber)").font(.body.weight(.medium))
                Text("\(Fmt.qty(order.totalUnits)) uds · \(Fmt.money(order.totalAmount))")
                    .font(.caption).foregroundStyle(.secondary)
                if order.isIncompleteDelivery {
                    Label("Vino incompleto del picking", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Spacer()
            DeliveryBadge(display: display)
        }
        .padding(.vertical, 2)
    }
}

/// Insignia del resultado de entrega. `isPending` = registrado, aún sin confirmar (se resalta).
struct DeliveryBadge: View {
    let display: DeliveryDisplay

    var body: some View {
        if let status = display.status {
            VStack(alignment: .trailing, spacing: 2) {
                Label(label(status), systemImage: icon(status))
                    .font(.caption.weight(.semibold)).foregroundStyle(color(status))
                    .labelStyle(.titleAndIcon)
                if display.isPending {
                    Text("sin enviar").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func label(_ s: DeliveryStatus) -> String {
        switch s {
        case .pendiente: return "En ruta"
        case .entregado: return "Entregado"
        case .entregadoParcial: return "Parcial"
        case .noEntregado: return "No entregado"
        }
    }
    private func icon(_ s: DeliveryStatus) -> String {
        switch s {
        case .pendiente: return "clock"
        case .entregado: return "checkmark.circle.fill"
        case .entregadoParcial: return "exclamationmark.triangle.fill"
        case .noEntregado: return "xmark.circle.fill"
        }
    }
    private func color(_ s: DeliveryStatus) -> Color {
        switch s {
        case .pendiente: return .blue
        case .entregado: return .green
        case .entregadoParcial: return .orange
        case .noEntregado: return .red
        }
    }
}
