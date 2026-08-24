import SwiftUI
import AVFoundation

/// "Recoger pago" (★ v0.16.0). Cliente (de sus paradas) → monto → tipo. Si es CHEQUE: número +
/// foto OBLIGATORIA (misma tubería que el retorno). Offline: se guarda al instante como registro
/// durable y sincroniza sola; el `payment_uuid` se genera al crear. `occurred_at` = hora real.
struct CollectPaymentView: View {
    @EnvironmentObject private var dispatch: DispatchService
    @Environment(\.dismiss) private var dismiss

    @State private var stops: [DriverStop] = []
    @State private var clientCode: String?
    @State private var amountText = ""
    @State private var type: PaymentType = .cash
    @State private var checkNumber = ""
    @State private var note = ""
    /// Facturas que el cliente dice pagar (Dr1). Estructurado, opcional; se anotan, no se imputan.
    @State private var invoices: [String] = []

    @State private var photoPath: String?
    @State private var showCamera = false
    @State private var showCameraDenied = false
    @State private var saved = false

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }
    private var clientName: String {
        stops.first { $0.clientCode == clientCode }?.clientName ?? ""
    }
    private var canSave: Bool {
        guard clientCode != nil, let amount, amount > 0 else { return false }
        if type == .cheque {
            return !checkNumber.trimmingCharacters(in: .whitespaces).isEmpty && photoPath != nil
        }
        return true   // CASH: sin foto ni número
    }

    var body: some View {
        Form {
            if saved {
                Section {
                    Label("Pago registrado. Se sincroniza sola.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Section("Cliente") {
                    Picker("Cliente", selection: $clientCode) {
                        Text("Elige un cliente").tag(String?.none)
                        ForEach(stops) { Text($0.clientName).tag(String?.some($0.clientCode)) }
                    }
                }
                Section("Pago") {
                    HStack {
                        Text("Monto")
                        Spacer()
                        TextField("0.00", text: $amountText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    Picker("Tipo", selection: $type) {
                        ForEach(PaymentType.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if type == .cheque {
                    chequeSection
                }
                Section("Opcional") {
                    TextField("Nota", text: $note, axis: .vertical)
                }
                invoicesSection
                Section {
                    Button {
                        save()
                    } label: {
                        Label("Guardar pago", systemImage: "dollarsign.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
            }
        }
        .navigationTitle("Recoger pago")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { stops = (try? dispatch.repo.stops()) ?? [] }
        #if canImport(UIKit)
        .sheet(isPresented: $showCamera) {
            ImageCaptureView { data in photoPath = try? dispatch.savePhoto(data) }
                .ignoresSafeArea()
        }
        #endif
        .alert("Cámara sin permiso", isPresented: $showCameraDenied) {
            #if canImport(UIKit)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Habilita la cámara en Ajustes para tomar la foto del cheque.")
        }
    }

    /// Facturas que el cliente dice pagar (Dr1). Lista estructurada (no texto libre), OPCIONAL. Sin
    /// autocompletar desde las facturas del cliente y sin marcar nada en verde: se ANOTAN, no se
    /// imputan — el servidor no las verifica. La pantalla no debe sugerir lo contrario.
    private var invoicesSection: some View {
        Section {
            ForEach(invoices.indices, id: \.self) { i in
                HStack {
                    TextField("N.º de factura", text: $invoices[i])
                        #if os(iOS)
                        .autocorrectionDisabled()
                        #endif
                    Button(role: .destructive) { invoices.remove(at: i) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button { invoices.append("") } label: {
                Label("Agregar factura", systemImage: "plus.circle")
            }
        } header: {
            Text("Facturas que el cliente dice pagar (opcional)")
        } footer: {
            Text("Se anotan tal como las dice el cliente. No se verifican contra el sistema ni se imputan a su cuenta.")
        }
    }

    private var chequeSection: some View {
        Section("Cheque") {
            TextField("Número de cheque", text: $checkNumber)
                .autocorrectionDisabled()
            if let photoPath, let image = loadThumb(photoPath) {
                image.resizable().scaledToFill()
                    .frame(height: 160).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button { self.photoPath = nil; requestPhoto() } label: {
                    Label("Tomar otra", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                Button { requestPhoto() } label: {
                    Label("Foto del cheque (obligatoria)", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func save() {
        guard let clientCode, let amount,
              let truckID = try? dispatch.repo.routeHeader()?.truckID else { return }
        dispatch.registerPayment(truckID: truckID, clientCode: clientCode, clientName: clientName,
                                 amount: amount, type: type,
                                 checkNumber: type == .cheque ? checkNumber : nil,
                                 note: note.isEmpty ? nil : note,
                                 invoiceDocNums: invoices
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty },
                                 photoPath: type == .cheque ? photoPath : nil)
        saved = true
    }

    private func requestPhoto() {
        #if canImport(UIKit)
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { showCamera = true; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in granted ? (showCamera = true) : (showCameraDenied = true) }
            }
        default: showCameraDenied = true
        }
        #endif
    }

    #if canImport(UIKit)
    private func loadThumb(_ path: String) -> Image? {
        UIImage(contentsOfFile: path).map { Image(uiImage: $0) }
    }
    #else
    private func loadThumb(_ path: String) -> Image? { nil }
    #endif
}
