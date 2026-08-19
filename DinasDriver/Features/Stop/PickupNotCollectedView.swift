import SwiftUI

/// "No se pudo recoger" (★ v0.45.0). La contraparte de registrar la recogida: sin esto, una
/// recogida que no se pudo hacer y una que nadie miró se ven idénticas desde la oficina (las dos
/// EN_CAMION para siempre). Motivo obligatorio + nota opcional; se encola y se muestra hecho al
/// instante. `occurred_at` = hora de la visita (lo pone el servicio).
struct PickupNotCollectedView: View {
    @EnvironmentObject private var dispatch: DispatchService
    let pickup: DriverPickup

    @State private var reason: PickupNotCollectedReason = .nadaQueRecoger
    @State private var note = ""
    @State private var saved = false

    var body: some View {
        Form {
            if saved {
                Section {
                    Label("Registrado. Se sincroniza sola.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Section("Motivo") {
                    Picker("Motivo", selection: $reason) {
                        ForEach(PickupNotCollectedReason.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Nota (opcional)") {
                    TextField("Detalle para la oficina", text: $note, axis: .vertical)
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Label("Guardar", systemImage: "tray.and.arrow.down.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("No se pudo recoger")
        .navigationBarTitleDisplayModeInlineCompat()
    }

    private func save() {
        guard let truckID = try? dispatch.repo.routeHeader()?.truckID else { return }
        dispatch.registerPickupNotCollected(truckID: truckID, requestUUID: pickup.requestUUID,
                                             reason: reason, note: note.isEmpty ? nil : note)
        saved = true
    }
}
