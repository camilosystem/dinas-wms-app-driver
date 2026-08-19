import SwiftUI
import AVFoundation

/// "Retorno de producto" (★ v0.15.0). Flujo simple: elegir cliente de su ruta → agregar ítems
/// (buscar en el catálogo, cantidad, motivo) → tomar la foto (OBLIGATORIA) → guardar. Offline
/// como todo: se encola, se muestra hecho, sincroniza sola. `occurred_at` = hora de la visita.
/// Para qué se abre el flujo. OBLIGATORIO (sin default): una recogida NO puede caer por olvido en
/// una devolución espontánea. El caso `.pickup` fija el cliente y precarga lo esperado como AYUDA.
enum ReturnFlowMode: Equatable {
    case spontaneous
    case pickup(DriverPickup, clientName: String)

    var kind: ReturnKind {
        switch self {
        case .spontaneous: return .spontaneous
        case .pickup(let p, _): return .pickup(requestUUID: p.requestUUID)
        }
    }
}

struct ReturnFlowView: View {
    @EnvironmentObject private var dispatch: DispatchService
    @Environment(\.dismiss) private var dismiss

    let mode: ReturnFlowMode

    @State private var stops: [DriverStop] = []
    @State private var selectedClientCode: String?
    @State private var items: [ProductReturnItemInput] = []
    @State private var note = ""
    @State private var clientReference = ""

    @State private var photoPath: String?
    @State private var showItemSearch = false
    @State private var showCamera = false
    @State private var showCameraDenied = false
    @State private var saved = false

    private var canSave: Bool {
        selectedClientCode != nil && !items.isEmpty
            && items.allSatisfy { $0.quantity > 0 } && photoPath != nil
    }

    var body: some View {
        Form {
            if saved {
                Section {
                    Label(isPickup ? "Recogida registrada. Se sincroniza sola."
                                   : "Retorno registrado. Se sincroniza sola.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } else {
                clientSection
                itemsSection
                photoSection
                Section("Opcional") {
                    TextField("Nota", text: $note, axis: .vertical)
                    TextField("Referencia del cliente (factura/remisión)", text: $clientReference)
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Label(isPickup ? "Guardar recogida" : "Guardar retorno",
                              systemImage: "tray.and.arrow.down.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                } footer: {
                    if photoPath == nil {
                        Text("La foto es obligatoria: sin ella no se puede guardar.")
                    }
                }
            }
        }
        .navigationTitle(isPickup ? "Registrar recogida" : "Retorno de producto")
        .navigationBarTitleDisplayModeInlineCompat()
        .task {
            stops = (try? dispatch.repo.stops()) ?? []
            setupPickupIfNeeded()
        }
        .sheet(isPresented: $showItemSearch) {
            ItemSearchView(search: { (try? dispatch.repo.searchCatalog($0)) ?? [] },
                           onSelect: addItem)
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showCamera) {
            ImageCaptureView { data in
                photoPath = try? dispatch.savePhoto(data)
            }
            .ignoresSafeArea()
        }
        #endif
        .alert("Cámara sin permiso", isPresented: $showCameraDenied) {
            #if canImport(UIKit)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #endif
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Habilita la cámara en Ajustes para tomar la foto de evidencia.")
        }
    }

    // MARK: - Secciones

    private var isPickup: Bool { if case .pickup = mode { return true }; return false }

    @ViewBuilder
    private var clientSection: some View {
        if case let .pickup(pickup, clientName) = mode {
            // Recogida: el cliente es FIJO (la parada), no se elige.
            Section("Cliente") {
                Text(clientName).font(.headline)
                if let note = pickup.pickupNote, !note.isEmpty {
                    Label(note, systemImage: "info.circle").font(.callout)
                }
            }
        } else {
            Section("Cliente") {
                // Solo clientes de SU ruta.
                Picker("Cliente", selection: $selectedClientCode) {
                    Text("Elige un cliente").tag(String?.none)
                    ForEach(stops) { stop in
                        Text(stop.clientName).tag(String?.some(stop.clientCode))
                    }
                }
            }
        }
    }

    private var itemsSection: some View {
        Section {
            itemsRows
        } header: {
            Text(isPickup ? "Lo que el cliente entrega" : "Ítems a devolver")
        } footer: {
            if isPickup {
                Text("Los ítems de arriba son la referencia de la solicitud. Registra lo que el cliente entrega, aunque sea menos, más o distinto.")
            }
        }
    }

    @ViewBuilder
    private var itemsRows: some View {
            ForEach($items) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.itemName).font(.body.weight(.medium))
                    Stepper(value: $item.quantity, in: 1...999, step: 1) {
                        Text("Cantidad: \(Fmt.qty(item.quantity))").font(.subheadline)
                    }
                    Picker("Motivo", selection: $item.reason) {
                        ForEach(ProductReturnReason.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 2)
            }
            .onDelete { items.remove(atOffsets: $0) }

            Button {
                showItemSearch = true
            } label: {
                Label("Agregar ítem", systemImage: "plus.circle.fill")
            }
    }

    private var photoSection: some View {
        Section("Foto (obligatoria)") {
            if let photoPath, let image = loadThumb(photoPath) {
                image.resizable().scaledToFill()
                    .frame(height: 180).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    self.photoPath = nil
                    requestPhoto()
                } label: { Label("Tomar otra", systemImage: "arrow.triangle.2.circlepath") }
            } else {
                Button {
                    requestPhoto()
                } label: {
                    Label("Tomar foto", systemImage: "camera.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Acciones

    private func addItem(_ catalog: CatalogItem) {
        guard !items.contains(where: { $0.itemCode == catalog.itemCode }) else { return }
        items.append(ProductReturnItemInput(itemCode: catalog.itemCode, itemName: catalog.itemName,
                                            quantity: 1, reason: .danado))
    }

    /// Recogida: fija el cliente de la parada y precarga los esperados como AYUDA (editables). Los
    /// esperados pueden venir vacíos (solicitud por monto): ahí el driver agrega lo que recibe.
    private func setupPickupIfNeeded() {
        guard case let .pickup(pickup, _) = mode, selectedClientCode == nil else { return }
        selectedClientCode = pickup.clientCode
        if items.isEmpty {
            items = pickup.expectedItems.map {
                ProductReturnItemInput(itemCode: $0.itemCode, itemName: $0.itemName ?? $0.itemCode,
                                       quantity: $0.quantity > 0 ? $0.quantity : 1, reason: .danado)
            }
        }
    }

    private func save() {
        guard let clientCode = selectedClientCode, let photoPath,
              let truckID = try? dispatch.repo.routeHeader()?.truckID else { return }
        dispatch.registerReturn(kind: mode.kind, truckID: truckID, clientCode: clientCode, items: items,
                                note: note.isEmpty ? nil : note,
                                clientReference: clientReference.isEmpty ? nil : clientReference,
                                photoPath: photoPath)
        saved = true
    }

    /// Pide permiso de cámara al momento y lo maneja bien si el driver lo niega (sin crash).
    private func requestPhoto() {
        #if canImport(UIKit)
        // Sin cámara (simulador) → fototeca directa, sin permiso de cámara.
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { showCamera = true; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in granted ? (showCamera = true) : (showCameraDenied = true) }
            }
        default:
            showCameraDenied = true
        }
        #endif
    }

    #if canImport(UIKit)
    private func loadThumb(_ path: String) -> Image? {
        guard let ui = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: ui)
    }
    #else
    private func loadThumb(_ path: String) -> Image? { nil }
    #endif
}
