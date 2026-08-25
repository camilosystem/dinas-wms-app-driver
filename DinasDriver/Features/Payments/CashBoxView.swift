import SwiftUI

/// "Mi caja" (Dr2, ★ v0.80.0): el dinero que el driver TODAVÍA tiene sin declarar entregado.
///
/// Es SERVER-AUTORITATIVA a propósito: `GET /dispatch/my-cash` cruza rutas y jornadas y sabe qué
/// está declarado. **No se filtra por camión activo** — un pago viejo sin declarar de una ruta
/// cerrada sigue siendo del driver (ver `Custody.cashPayments`). Declarar es una DECLARACIÓN del
/// driver, no un acuse de bodega: nadie del otro lado confirma. Deshacer se permite y no se puede
/// tapar (suma al conteo, con hora).
///
/// Red de seguridad: los pagos LOCALES sin sincronizar o RECHAZADOS no están en la caja del
/// servidor (no llegaron), pero son dinero — se muestran aparte para que no queden invisibles.
struct CashBoxView: View {
    @EnvironmentObject private var dispatch: DispatchService

    @State private var declareTarget: RemotePayment?
    @State private var voidTarget: RemotePayment?
    @State private var outcomeAlert: OutcomeAlert?
    /// Tras declarar bien, se ofrece deshacer un rato (el error de dedo se corrige en el acto).
    @State private var justDeclared: RemotePayment?
    @State private var localAtRisk: [Payment] = []

    var body: some View {
        List {
            if let cash = dispatch.cash {
                cashSection(cash)
            } else if dispatch.isLoadingCash {
                Section { HStack { ProgressView(); Text("Trayendo tu caja…").foregroundStyle(.secondary) } }
            }

            if let err = dispatch.cashError, dispatch.cash == nil {
                Section {
                    Label(err, systemImage: "wifi.slash").foregroundStyle(.orange)
                    Text("Tu caja se consulta al servidor; necesita señal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !localAtRisk.isEmpty {
                atRiskSection
            }
        }
        .navigationTitle("Mi caja")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(dispatch.$pendingCount) { _ in localAtRisk = riskyLocalPayments() }
        .sheet(item: $declareTarget) { p in
            DeclareHandoverSheet(payment: p) { await declare(p) }
        }
        .sheet(item: $voidTarget) { p in
            VoidReasonSheet(clientName: p.clientName.isEmpty ? p.clientCode : p.clientName,
                            amount: p.amount) { reason in
                dispatch.voidPayment(paymentUUID: p.paymentUUID, reason: reason)
                Task { await reload() }
            }
        }
        .alert(item: $outcomeAlert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("Entendido")))
        }
    }

    // MARK: - Secciones

    @ViewBuilder
    private func cashSection(_ cash: DriverCash) -> some View {
        // activeTruckID va nil a propósito: "Mi caja" NO se filtra por camión (ver Custody).
        let payments = Custody.cashPayments(cash, activeTruckID: nil)
        Section {
            HStack {
                Text("Sin declarar").font(.headline)
                Spacer()
                Text(Fmt.money(cash.totalAmount)).font(.headline)
            }
            Text(payments.isEmpty
                 ? "Declaraste todo. No llevas dinero sin declarar."
                 : "\(payments.count) pago(s) que todavía llevas encima.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Tu caja") }

        if let jd = justDeclared {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Declarado entregado", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout.weight(.semibold))
                    Text(CustodyCopy.undoDisclaimer).font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) { Task { await undo(jd) } } label: {
                        Label(CustodyCopy.undoButton, systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        if !payments.isEmpty {
            Section("Pagos sin declarar") {
                ForEach(payments) { p in
                    UndeclaredRow(payment: p, now: Date(),
                                  onDeclare: { declareTarget = p })
                        .swipeActions {
                            Button("Anular", role: .destructive) { voidTarget = p }
                        }
                }
            }
        }
    }

    private var atRiskSection: some View {
        Section {
            ForEach(localAtRisk) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.clientName.isEmpty ? p.clientCode : p.clientName)
                        .font(.body.weight(.medium))
                    if let reason = p.rejectedReason {
                        Label("Rechazado: \(reason)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    } else {
                        Label("Pendiente de sincronizar", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text(Fmt.money(p.amount)).font(.callout.weight(.semibold))
                }
            }
        } header: {
            Text("Dinero que no llegó al servidor")
        } footer: {
            Text("Estos pagos aún no están en tu caja del servidor. No los puedes declarar hasta que sincronicen.")
        }
    }

    // MARK: - Acciones

    private func reload() async {
        await dispatch.loadMyCash()
        localAtRisk = riskyLocalPayments()
    }

    private func riskyLocalPayments() -> [Payment] {
        ((try? dispatch.repo.payments()) ?? []).filter { $0.needsSync || $0.isRejected }
    }

    private func declare(_ p: RemotePayment) async {
        let outcome = await dispatch.declareHandover(paymentUUID: p.paymentUUID)
        switch outcome {
        case let .ok(updated):
            justDeclared = updated
        case .anulado:
            outcomeAlert = .init(title: "No se pudo declarar",
                                 message: "Este pago está anulado: no hay dinero que declarar.")
        case .sinRed:
            outcomeAlert = .init(title: "Sin conexión",
                                 message: "Declarar necesita señal. Conéctate e inténtalo de nuevo.")
        case let .error(msg):
            outcomeAlert = .init(title: "No se pudo declarar", message: msg ?? "Inténtalo de nuevo.")
        case .enDeposito, .noDeclarado:
            outcomeAlert = .init(title: "No se pudo declarar", message: "Inténtalo de nuevo.")
        }
        localAtRisk = riskyLocalPayments()
    }

    private func undo(_ p: RemotePayment) async {
        let outcome = await dispatch.undoHandover(paymentUUID: p.paymentUUID)
        switch outcome {
        case .ok:
            justDeclared = nil
        case .enDeposito:
            outcomeAlert = .init(title: "Ya no puedes deshacerlo",
                                 message: "La oficina ya lo metió en un depósito. Ya no es tu caja: para corregirlo, llama a la oficina.")
            justDeclared = nil
        case .noDeclarado:
            outcomeAlert = .init(title: "Nada que deshacer",
                                 message: "Este pago no estaba declarado como entregado.")
            justDeclared = nil
        case .sinRed:
            outcomeAlert = .init(title: "Sin conexión", message: "Deshacer necesita señal.")
        case let .error(msg):
            outcomeAlert = .init(title: "No se pudo deshacer", message: msg ?? "Inténtalo de nuevo.")
        case .anulado:
            justDeclared = nil
        }
    }
}

private struct OutcomeAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Fila de un pago sin declarar. Muestra `occurred_at` en absoluto y también en relativo — este
/// último con `RelativeCustodyTime`, que NO recorta un futuro (★ v0.81.0).
private struct UndeclaredRow: View {
    let payment: RemotePayment
    let now: Date
    let onDeclare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(payment.clientName.isEmpty ? payment.clientCode : payment.clientName)
                    .font(.body.weight(.medium))
                Spacer()
                Text(Fmt.money(payment.amount)).font(.callout.weight(.semibold))
            }
            Text(payment.paymentType.label
                 + (payment.checkNumber.map { " · N.º \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            // occurred_at: absoluto + relativo honesto (puede ser un futuro por reloj adelantado).
            Text("Cobrado \(RelativeCustodyTime.text(payment.occurredAt, now: now)) · \(Fmt.dateTime(payment.occurredAt))")
                .font(.caption2).foregroundStyle(.secondary)
            if !payment.invoiceDocNums.isEmpty {
                Text("Facturas: \(payment.invoiceDocNums.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if payment.handoverUndoneCount > 0 {
                // No se tapa: la oficina ve la secuencia, no solo el estado.
                Label("Deshecho \(payment.handoverUndoneCount) vez(veces)", systemImage: "arrow.uturn.backward")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Button(action: onDeclare) {
                Label(CustodyCopy.declareButton, systemImage: "hand.raised")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// Hoja de DECLARACIÓN. El texto deja claro que el driver DECLARA, no que bodega confirme.
private struct DeclareHandoverSheet: View {
    let payment: RemotePayment
    let onConfirm: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Declaras, no entregas", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    Text(CustodyCopy.declareDisclaimer)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Pago") {
                    LabeledContent("Cliente", value: payment.clientName.isEmpty ? payment.clientCode : payment.clientName)
                    LabeledContent("Monto", value: Fmt.money(payment.amount))
                }
                Section {
                    Button {
                        busy = true
                        Task { await onConfirm(); busy = false; dismiss() }
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(CustodyCopy.declareButton).frame(maxWidth: .infinity) }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("Declarar entrega")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(busy) }
            }
        }
    }
}

/// Hoja para anular: MOTIVO obligatorio, y deja claro que el pago NO desaparece.
private struct VoidReasonSheet: View {
    let clientName: String
    let amount: Double
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("El pago NO desaparece: queda registrado como ANULADO, con tu motivo. El rastro importa.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Motivo (obligatorio)") {
                    TextField("Por qué se anula", text: $reason, axis: .vertical)
                }
                Section {
                    Button(role: .destructive) {
                        onConfirm(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    } label: {
                        Text("Anular pago de \(Fmt.money(amount))").frame(maxWidth: .infinity)
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Anular pago")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
        }
    }
}
