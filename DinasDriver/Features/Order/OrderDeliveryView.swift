import SwiftUI

/// "Pedido": confirmar la entrega. Lo normal (entregar todo) es UN TOQUE. Si hay novedad, se
/// marca por ítem; o salida rápida "no se entregó" con motivo de pedido. Los dos caminos son
/// EXCLUYENTES: nunca se manda `rejected_items` y `order_reason` juntos.
struct OrderDeliveryView: View {
    @EnvironmentObject private var dispatch: DispatchService
    @Environment(\.dismiss) private var dismiss
    let orderUUID: String

    @State private var order: DriverOrder?
    @State private var mode: Mode = .idle
    @State private var rejections: [String: LineRejection] = [:]   // item_code → (qty, motivo)
    @State private var orderReason: OrderRejectionReason?

    enum Mode: Equatable { case idle, novedad, noEntrega }

    var body: some View {
        Group {
            if let order {
                content(order)
            } else {
                ContentUnavailableViewCompat(title: "Pedido no encontrado", message: "", systemImage: "questionmark")
            }
        }
        .navigationTitle(order.map { "Pedido \($0.orderNumber)" } ?? "Pedido")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { order = try? dispatch.repo.order(uuid: orderUUID) }
    }

    @ViewBuilder
    private func content(_ order: DriverOrder) -> some View {
        List {
            if order.isIncompleteDelivery {
                Section {
                    Label("Este pedido vino INCOMPLETO del picking. Faltó producto — avísale al cliente antes de que reclame.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                }
            }

            if !order.palletLabels.isEmpty {
                Section("Viene en") {
                    Text(order.palletLabels.joined(separator: " · "))
                        .font(.callout.weight(.medium))
                }
            }

            Section(mode == .novedad ? "Marca lo que NO se entregó" : "Ítems") {
                ForEach(order.lines) { line in
                    LineRow(line: line, mode: mode,
                            rejection: Binding(
                                get: { rejections[line.itemCode] ?? LineRejection() },
                                set: { rejections[line.itemCode] = $0 }))
                }
            }

            actions(order)
        }
    }

    @ViewBuilder
    private func actions(_ order: DriverOrder) -> some View {
        switch mode {
        case .idle:
            Section {
                Button {
                    register(order, orderReason: nil, rejected: nil)
                } label: {
                    Label("Entregado completo", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
            Section {
                Button { mode = .novedad } label: {
                    Label("Registrar novedad por ítem", systemImage: "square.and.pencil")
                }
                Button(role: .destructive) { mode = .noEntrega } label: {
                    Label("No se entregó (negocio cerrado)", systemImage: "xmark.circle")
                }
            }

        case .novedad:
            Section {
                Button {
                    register(order, orderReason: nil, rejected: builtRejections(order))
                } label: {
                    Label("Confirmar entrega con novedades", systemImage: "checkmark")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!novedadValida)
                Button("Cancelar") { mode = .idle; rejections = [:] }
            } footer: {
                Text("Marca cuántas unidades NO recibió el cliente y el motivo. Lo no entregado vuelve en el camión.")
            }

        case .noEntrega:
            Section("Motivo") {
                ForEach(OrderRejectionReason.allCases) { reason in
                    Button {
                        orderReason = reason
                    } label: {
                        HStack {
                            Text(reason.label)
                            Spacer()
                            if orderReason == reason { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section {
                Button(role: .destructive) {
                    register(order, orderReason: orderReason, rejected: nil)
                } label: {
                    Label("Confirmar: no se entregó", systemImage: "xmark.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(orderReason == nil)
                Button("Cancelar") { mode = .idle; orderReason = nil }
            }
        }
    }

    // MARK: - Lógica de UI

    /// Ítems marcados como no entregados (qty>0 y con motivo).
    private func builtRejections(_ order: DriverOrder) -> [RejectedItemInput] {
        order.lines.compactMap { line in
            guard let r = rejections[line.itemCode], r.quantity > 0, let reason = r.reason else { return nil }
            return RejectedItemInput(itemCode: line.itemCode, itemName: line.itemName,
                                     quantity: r.quantity, reason: reason)
        }
    }

    private var novedadValida: Bool {
        // Al menos un ítem marcado, y todos los marcados con motivo.
        let marked = rejections.values.filter { $0.quantity > 0 }
        return !marked.isEmpty && marked.allSatisfy { $0.reason != nil }
    }

    /// Registra la entrega (encola optimista) y vuelve. NUNCA manda ambos: el modo lo garantiza.
    private func register(_ order: DriverOrder, orderReason: OrderRejectionReason?,
                          rejected: [RejectedItemInput]?) {
        dispatch.deliver(truckID: order.truckID, orderUUID: order.orderUUID,
                         orderReason: orderReason,
                         rejectedItems: (rejected?.isEmpty == false) ? rejected : nil)
        dismiss()
    }
}

/// Estado local de una línea al marcar novedad.
struct LineRejection: Equatable {
    var quantity: Double = 0
    var reason: ItemRejectionReason?
}

/// Fila de una línea del pedido. En modo novedad muestra el control de "no entregadas" + motivo.
private struct LineRow: View {
    let line: DriverOrderLine
    let mode: OrderDeliveryView.Mode
    @Binding var rejection: LineRejection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(line.itemName).font(.body.weight(.medium))
                Spacer()
                Text("\(Fmt.qty(line.quantity)) uds").font(.callout).foregroundStyle(.secondary)
            }
            if mode == .novedad {
                Stepper(value: Binding(get: { rejection.quantity },
                                       set: { rejection.quantity = min(max(0, $0), line.quantity) }),
                        in: 0...line.quantity, step: 1) {
                    Text(rejection.quantity > 0
                         ? "No entregadas: \(Fmt.qty(rejection.quantity))"
                         : "Entregado completo")
                        .font(.subheadline)
                        .foregroundStyle(rejection.quantity > 0 ? .orange : .secondary)
                }
                if rejection.quantity > 0 {
                    Picker("Motivo", selection: $rejection.reason) {
                        Text("Elige motivo").tag(ItemRejectionReason?.none)
                        ForEach(ItemRejectionReason.allCases) { r in
                            Text(r.label).tag(ItemRejectionReason?.some(r))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
