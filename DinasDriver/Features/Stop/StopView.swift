import SwiftUI

/// "Parada": el cliente, su dirección (solo texto, sin navegación) y sus pedidos. Cada pedido
/// lleva al detalle para confirmar la entrega.
struct StopView: View {
    @EnvironmentObject private var dispatch: DispatchService
    let stop: DriverStop
    @State private var orders: [DriverOrder] = []
    @State private var pendingByOrder: [String: PendingAction] = [:]
    /// Entregas RECHAZADAS por el servidor, por pedido → se muestran en su orden con el motivo.
    @State private var failedByOrder: [String: PendingAction] = [:]
    /// Retornos espontáneos rechazados de este cliente.
    @State private var failedReturns: [PendingAction] = []
    @State private var pickups: [DriverPickup] = []
    /// Estado local por recogida (pendiente / resuelta / rechazada / a ofrecer).
    @State private var pickupStates: [String: PickupUIState] = [:]

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
                if orders.isEmpty {
                    // ★ v0.45.0 — NO se oculta la sección: una lista vacía y una sección ausente se
                    // ven igual (¿no cargó, o no hay?). El texto lo afirma.
                    Label(pickups.isEmpty ? "Sin pedidos para entregar."
                                          : "Sin pedidos para entregar, solo recogida.",
                          systemImage: "tray")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(orders) { order in
                        NavigationLink {
                            OrderDeliveryView(orderUUID: order.orderUUID)
                        } label: {
                            OrderRow(order: order,
                                     display: DispatchService.display(order: order,
                                                                      pending: pendingByOrder[order.orderUUID.lowercased()]),
                                     failedReason: failedByOrder[order.orderUUID]?.errorMessage)
                        }
                    }
                }
            }

            if !failedReturns.isEmpty {
                Section("Retornos rechazados") {
                    ForEach(failedReturns) { r in
                        Label("El registro no llegó: \(r.errorMessage ?? "el servidor lo rechazó").",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }

            if !pickups.isEmpty {
                Section("Recogida") {
                    ForEach(pickups) { pickup in
                        PickupRow(pickup: pickup, clientName: stop.clientName,
                                  state: pickupStates[pickup.requestUUID] ?? .offer)
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
        failedByOrder = [:]
        for o in orders {
            if let f = try? dispatch.repo.failedDeliverAction(orderUUID: o.orderUUID) {
                failedByOrder[o.orderUUID] = f
            }
        }
        failedReturns = (try? dispatch.repo.failedReturns(clientCode: stop.clientCode)) ?? []
        pickups = (try? dispatch.repo.pickups(forClient: stop.clientCode)) ?? []
        pickupStates = Dictionary(uniqueKeysWithValues: pickups.map { ($0.requestUUID, state(for: $0)) })
    }

    /// Precedencia: pendiente (encolada) > resuelta (server o reflejo local) > rechazada > ofrecer.
    /// Un rechazo permanente NO deja la recogida pendiente: se re-ofrece Y se muestra por qué.
    private func state(for pickup: DriverPickup) -> PickupUIState {
        if (try? dispatch.repo.pickupRegisteredLocally(requestUUID: pickup.requestUUID)) == true {
            return .pending
        }
        if pickup.isResolvedByServer { return .resolved }
        if let action = try? dispatch.repo.failedPickupAction(requestUUID: pickup.requestUUID) {
            return .failed(action.errorMessage ?? "El servidor rechazó el registro.")
        }
        return .offer
    }
}

/// Estado local de una recogida en la parada.
enum PickupUIState: Equatable {
    case offer          // hay que registrarla
    case pending        // encolada, esperando red (marca local anti-doble-registro)
    case resolved       // ya cerrada (server o reflejo local del éxito)
    case failed(String) // el servidor la RECHAZÓ de forma permanente — se re-ofrece + se dice por qué
}

/// Fila de una recogida: la instrucción de la oficina, lo esperado (referencia) y las dos salidas
/// —registrarla o declarar que no se pudo—, salvo que ya se haya registrado localmente.
private struct PickupRow: View {
    let pickup: DriverPickup
    let clientName: String
    let state: PickupUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recoger mercancía", systemImage: "shippingbox.and.arrow.backward")
                .font(.body.weight(.semibold))
            if let note = pickup.pickupNote, !note.isEmpty {
                Text(note).font(.callout)
            }
            if pickup.expectedItems.isEmpty {
                Text("La solicitud no detalla ítems: pregunta en el local qué y cuánto hay que llevarse.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Referencia (puede diferir de lo que entreguen):")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(pickup.expectedItems) { item in
                        Text("· \(item.itemName ?? item.itemCode) — \(Fmt.qty(item.quantity))")
                            .font(.caption)
                    }
                }
            }

            switch state {
            case .pending:
                Label("Registrada. Se sincroniza sola.", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
            case .resolved:
                Label("Recogida cerrada.", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
            case .failed(let reason):
                // El registro se perdió: el driver TIENE que verlo antes de bajarse del camión.
                VStack(alignment: .leading, spacing: 4) {
                    Label("El registro no llegó. Hay que rehacerlo.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.bold)).foregroundStyle(.red)
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
                actions   // se re-ofrece
            case .offer:
                actions
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actions: some View {
        NavigationLink {
            ReturnFlowView(mode: .pickup(pickup, clientName: clientName))
        } label: {
            Label("Registrar recogida", systemImage: "camera.fill")
        }
        NavigationLink {
            PickupNotCollectedView(pickup: pickup)
        } label: {
            Label("No se pudo recoger", systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        }
    }
}

/// Fila de un pedido en la parada: número, unidades y su estado de entrega (reflejo).
struct OrderRow: View {
    let order: DriverOrder
    let display: DeliveryDisplay
    /// Si el servidor RECHAZÓ el registro de entrega: motivo (con sus palabras). El registro no
    /// llegó — el driver lo ve en la orden y la vuelve a registrar.
    var failedReason: String? = nil

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
                if let failedReason {
                    Label("El registro no llegó: \(failedReason)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold)).foregroundStyle(.red)
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
