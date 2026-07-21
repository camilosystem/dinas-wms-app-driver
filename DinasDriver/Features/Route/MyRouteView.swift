import SwiftUI

/// "Mi ruta": el camión asignado y sus paradas en orden. Gobierna la descarga (aviso claro si
/// falta), el inicio de ruta, el reordenamiento LOCAL (con aviso, sin bloquear) y el acceso a
/// retornados y cierre. Todo trabaja sobre el snapshot local — nunca espera al servidor.
struct MyRouteView: View {
    @EnvironmentObject private var dispatch: DispatchService
    @EnvironmentObject private var auth: AuthSession
    @StateObject private var model = MyRouteViewModel()

    @State private var showReorderWarning = false
    /// Modo reordenar: mientras está activo se arrastra; apagado, las paradas se abren al tocar.
    @State private var reordering = false
    @State private var showLogoutConfirm = false
    @State private var showRefreshWarning = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch dispatch.downloadState {
                case .noRouteAssigned:
                    VStack(spacing: 16) {
                        Image(systemName: "truck.box").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("No tienes ruta asignada")
                            .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        Text("Cuando la oficina te asigne un camión, toca Actualizar para traerlo.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button { requestRefresh() } label: {
                            Label("Actualizar ruta", systemImage: "arrow.clockwise")
                                .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent).disabled(dispatch.isSyncing)
                    }
                    .padding(28)
                case .notDownloaded:
                    notDownloaded
                case .downloaded:
                    routeContent
                }
            }
            .navigationTitle("Mi ruta")
            .toolbar {
                // ★ SIEMPRE presente (todos los estados): traer/actualizar la ruta cuando el
                // driver quiera. No depende de que la app "crea" que hace falta.
                ToolbarItem(placement: .primaryAction) {
                    Button { requestRefresh() } label: {
                        Label("Actualizar ruta", systemImage: "arrow.clockwise")
                    }
                    .disabled(dispatch.isSyncing)
                }
                ToolbarItem(placement: .primaryAction) { SyncBadge() }
                ToolbarItem(placement: .cancellationAction) {
                    // ★ Guarda: no dejar "perder" pendientes (dinero incluido) sin darse cuenta.
                    Button("Salir") {
                        if dispatch.pendingCount > 0 { showLogoutConfirm = true } else { auth.logout() }
                    }
                }
            }
            .confirmationDialog("Tienes \(dispatch.pendingCount) registro(s) sin sincronizar",
                                isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Cerrar sesión de todos modos", role: .destructive) { auth.logout() }
                Button("Quedarme", role: .cancel) { }
            } message: {
                Text("Incluye pagos. No se pierden — se enviarán cuando vuelvas a conectarte y abras la app. Mejor revisa antes de salir.")
            }
            .confirmationDialog("Tienes \(dispatch.pendingCount) pendiente(s) sin sincronizar de la ruta anterior",
                                isPresented: $showRefreshWarning, titleVisibility: .visible) {
                Button("Sincronizar ahora") { Task { await dispatch.syncPending(); model.reload() } }
                Button("Traer ruta nueva de todos modos", role: .destructive) {
                    Task { await dispatch.downloadRoute(); model.reload() }
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Incluye pagos. Envíalos antes: una vez traes la ruta nueva, el camión anterior queda cerrado y podrían no poder registrarse.")
            }
            .task {
                model.attach(dispatch); model.reload()
                // ★ Si la ruta local está cerrada, verifica si el admin ya asignó una nueva.
                await dispatch.checkForNewRouteIfClosed(); model.reload()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task { await dispatch.checkForNewRouteIfClosed(); model.reload() }
                }
            }
        }
    }

    /// "Actualizar ruta": si hay pendientes de la ruta anterior, avisa antes de reemplazar el
    /// snapshot (no descartar trabajo sin sincronizar, sobre todo pagos). Si no, actualiza directo.
    private func requestRefresh() {
        if dispatch.pendingCount > 0 {
            showRefreshWarning = true
        } else {
            Task { await dispatch.downloadRoute(); model.reload() }
        }
    }

    // MARK: - Estados

    private var notDownloaded: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48)).foregroundStyle(.orange)
            Text("Descarga tu ruta antes de salir")
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("Sin la descarga no puedes trabajar sin señal. Hazla ahora, con conexión.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let err = dispatch.loadError {
                Text(err).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                Task { await dispatch.downloadRoute(); model.reload() }
            } label: {
                Label("Descargar ruta", systemImage: "arrow.down.circle.fill")
                    .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }

    private var routeContent: some View {
        List {
            if let header = model.header {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(header.truckName ?? "Camión").font(.headline)
                            Text("\(header.totalStops) paradas · \(header.totalOrders) pedidos")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if header.status == .rutaCerrada {
                        Label("Ruta cerrada.", systemImage: "flag.checkered")
                            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        // Acción prominente para traer la ruta nueva (además del toolbar).
                        Button { requestRefresh() } label: {
                            Label("Actualizar ruta", systemImage: "arrow.clockwise")
                                .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(dispatch.isSyncing)
                    } else if header.startedAt == nil {
                        Button {
                            dispatch.startRoute(truckID: header.truckID); model.reload()
                        } label: {
                            Label("Iniciar ruta", systemImage: "play.circle.fill")
                                .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label("Ruta en curso", systemImage: "location.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.green)
                    }
                }
            }

            Section {
                ForEach(model.stops) { stop in
                    NavigationLink {
                        StopView(stop: stop)
                    } label: {
                        StopRow(stop: stop, delivered: model.deliveredCount(stop),
                                total: model.orderCount(stop))
                    }
                }
                .onMove { from, to in
                    model.move(from: from, to: to)
                    showReorderWarning = true
                }
            } header: {
                HStack {
                    Text("Paradas")
                    Spacer()
                    // Reordenar es OPCIONAL y bajo demanda: por defecto las paradas se ABREN al
                    // tocar (el modo edición permanente rompía la navegación).
                    if model.stops.count > 1 {
                        Button(reordering ? "Listo" : "Reordenar") { reordering.toggle() }
                            .textCase(nil).font(.callout.weight(.semibold))
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(reordering ? .active : .inactive))
            #endif

            Section {
                NavigationLink { CollectPaymentView() } label: {
                    Label("Recoger pago", systemImage: "dollarsign.circle")
                        .foregroundStyle(model.header?.startedAt == nil ? Color.secondary : Color.primary)
                }
                .disabled(model.header?.startedAt == nil)
                NavigationLink { CashBoxView() } label: {
                    Label("Mi caja", systemImage: "tray.full")
                }
                NavigationLink { ReturnFlowView() } label: {
                    Label("Retorno de producto", systemImage: "arrow.uturn.backward.square")
                        .foregroundStyle(model.header?.startedAt == nil ? Color.secondary : Color.primary)
                }
                .disabled(model.header?.startedAt == nil)
                NavigationLink { ReturnsView() } label: {
                    Label("Retornados", systemImage: "arrow.uturn.left")
                }
                NavigationLink { FinishRouteView() } label: {
                    Label("Terminar ruta", systemImage: "flag.checkered")
                        .foregroundStyle(model.header?.startedAt == nil ? Color.secondary : Color.primary)
                }
                .disabled(model.header?.startedAt == nil)
            }
        }
        .alert("Cambiaste el orden", isPresented: $showReorderWarning) {
            Button("Entendido", role: .cancel) { }
        } message: {
            Text("Cambiar el orden puede afectar el orden en que están cargados los pallets. Es solo tu vista; no cambia la ruta de la oficina.")
        }
    }
}

/// Fila de una parada: número, cliente y avance de entregas.
private struct StopRow: View {
    let stop: DriverStop
    let delivered: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(stop.stopNumber)")
                .font(.headline).frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.15)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.clientName).font(.body.weight(.medium))
                if let address = stop.address, !address.isEmpty {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if total > 0 {
                Text("\(delivered)/\(total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(delivered == total ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class MyRouteViewModel: ObservableObject {
    @Published var header: RouteHeader?
    @Published var stops: [DriverStop] = []
    private var orderCounts: [String: Int] = [:]      // client_code → # pedidos
    private var deliveredCounts: [String: Int] = [:]  // client_code → # con estado
    private weak var dispatch: DispatchService?

    func attach(_ dispatch: DispatchService) { self.dispatch = dispatch }

    func reload() {
        guard let repo = dispatch?.repo else { return }
        header = try? repo.routeHeader()
        stops = (try? repo.stops()) ?? []
        let orders = (try? repo.allOrders()) ?? []
        let pending = (try? repo.pendingDelivers()) ?? []
        let pendingByOrder = Dictionary(pending.compactMap { a in a.orderUUID.map { ($0.lowercased(), a) } },
                                        uniquingKeysWith: { a, _ in a })
        orderCounts = [:]; deliveredCounts = [:]
        for o in orders {
            orderCounts[o.clientCode, default: 0] += 1
            let d = DispatchService.display(order: o, pending: pendingByOrder[o.orderUUID.lowercased()])
            if d.status != nil { deliveredCounts[o.clientCode, default: 0] += 1 }
        }
    }

    func orderCount(_ stop: DriverStop) -> Int { orderCounts[stop.clientCode] ?? 0 }
    func deliveredCount(_ stop: DriverStop) -> Int { deliveredCounts[stop.clientCode] ?? 0 }

    /// Reordena SOLO la vista y lo persiste local (device-only, nunca al servidor).
    func move(from: IndexSet, to: Int) {
        stops.move(fromOffsets: from, toOffset: to)
        guard let repo = dispatch?.repo, let truckID = header?.truckID else { return }
        try? repo.saveLocalOrder(truckID: truckID, clientCodes: stops.map(\.clientCode))
    }
}
