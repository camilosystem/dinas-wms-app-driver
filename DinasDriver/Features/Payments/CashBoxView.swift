import SwiftUI

/// "Mi caja" (★ v0.16.0): lo que el driver lleva recogido, separado CASH/CHEQUE, con la lista de
/// pagos. Los ANULADOS se ven marcados y NO suman. Anular (con motivo obligatorio) está disponible
/// SIEMPRE, incluso con la ruta cerrada. Un pago sin sincronizar se señala — es dinero.
struct CashBoxView: View {
    @EnvironmentObject private var dispatch: DispatchService

    @State private var payments: [Payment] = []
    @State private var totals = PaymentTotals()
    @State private var voidTarget: Payment?

    var body: some View {
        List {
            Section("Total de tu caja") {
                totalRow("Efectivo", totals.cash, .green)
                totalRow("Cheque", totals.cheque, .blue)
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(Fmt.money(totals.grand)).font(.headline)
                }
                Text("\(totals.count) pago(s)"
                     + (totals.voidedCount > 0 ? " · \(totals.voidedCount) anulado(s)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pagos") {
                if payments.isEmpty {
                    Text("Aún no has recogido pagos.").foregroundStyle(.secondary)
                }
                ForEach(payments) { payment in
                    // Anular VISIBLE (botón en la fila) + también por swipe. El motivo es
                    // obligatorio (lo pide la hoja).
                    PaymentRow(payment: payment,
                               onVoid: payment.isVoided ? nil : { voidTarget = payment })
                        .swipeActions {
                            if !payment.isVoided {
                                Button("Anular", role: .destructive) { voidTarget = payment }
                            }
                        }
                }
            }
        }
        .navigationTitle("Mi caja")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { reload() }
        .onReceive(dispatch.$pendingCount) { _ in reload() }
        .sheet(item: $voidTarget) { payment in
            VoidReasonSheet(payment: payment) { reason in
                dispatch.voidPayment(paymentUUID: payment.paymentUUID, reason: reason)
                reload()
            }
        }
    }

    private func totalRow(_ label: String, _ amount: Double, _ color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Fmt.money(amount)).foregroundStyle(color)
        }
    }

    private func reload() {
        payments = (try? dispatch.repo.payments()) ?? []
        totals = (try? dispatch.repo.cajaTotals()) ?? PaymentTotals()
    }
}

private struct PaymentRow: View {
    let payment: Payment
    /// Si no es nil, el pago se puede anular (no anulado aún) → botón visible.
    var onVoid: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(payment.clientName.isEmpty ? payment.clientCode : payment.clientName)
                        .font(.body.weight(.medium))
                    if payment.isVoided {
                        Text("ANULADO").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.red.opacity(0.15)).foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                Text(payment.paymentType.label
                     + (payment.checkNumber.map { " · N.º \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if payment.isVoided, let reason = payment.voidReason {
                    Text("Motivo: \(reason)").font(.caption2).foregroundStyle(.red)
                }
                if let reason = payment.rejectedReason {
                    // ★ RECHAZADO por el servidor: NO está registrado. Es dinero que no llegó — el
                    // driver tiene que verlo antes de cerrar el día, con las palabras del servidor.
                    Label("Rechazado: \(reason)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                } else if payment.needsSync {
                    Label("Pendiente de sincronizar", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(Fmt.money(payment.amount))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(payment.isVoided ? .secondary : .primary)
                    .strikethrough(payment.isVoided)
                if let onVoid {
                    Button(role: .destructive, action: onVoid) {
                        Label("Anular", systemImage: "xmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)   // el toque va al botón, no a la fila
                    .tint(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Hoja para anular: MOTIVO obligatorio, y deja claro que el pago NO desaparece.
private struct VoidReasonSheet: View {
    let payment: Payment
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
                        Text("Anular pago de \(Fmt.money(payment.amount))")
                            .frame(maxWidth: .infinity)
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
