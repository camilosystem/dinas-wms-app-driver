import SwiftUI

/// Historial de rutas cerradas (Dr4/Dr5, ★ v0.69.0). Lista paginada de `ClosedRouteEntry`; el detalle
/// pide el MISMO `RouteSummary` que el cierre. Es una vista VIVA (los números se calculan al pedirlos):
/// si la oficina corrige una entrega de una ruta ya cerrada, abrirla otra vez puede dar otros números,
/// y esa es la respuesta correcta a "¿qué pasó con estos pedidos?".
struct RouteHistoryView: View {
    @EnvironmentObject private var dispatch: DispatchService

    @State private var routes: [ClosedRouteEntry] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = false
    @State private var loaded = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let err = loadError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if routes.isEmpty && loaded && loadError == nil {
                ContentUnavailableViewCompat(
                    title: "Sin rutas cerradas",
                    message: "Cuando cierres una ruta, la vas a poder volver a ver acá.",
                    systemImage: "clock.arrow.circlepath")
            } else {
                ForEach(routes) { entry in
                    NavigationLink { RouteHistoryDetailView(entry: entry) } label: { row(entry) }
                }
                if routes.count < total {
                    Button { Task { await loadMore() } } label: {
                        HStack { Spacer(); if isLoading { ProgressView() } else { Text("Cargar más") }; Spacer() }
                    }.disabled(isLoading)
                }
            }
        }
        .navigationTitle("Historial de rutas")
        .task { if !loaded { await reload() } }
        .refreshable { await reload() }
    }

    private func row(_ entry: ClosedRouteEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.displayName).font(.body.weight(.medium))
                Spacer()
                Text(Self.dayLabel(entry.routeDate)).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(entry.deliveredCount)/\(entry.totalOrders) entregados · \(entry.notDeliveredCount) no entregados")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// `route_date` es una fecha pelada parseada en UTC → se formatea en UTC (round-trip, no se corre
    /// un día). `nil` = la ruta se cerró sin haberse iniciado nunca (dato en sí, no hueco).
    static func dayLabel(_ date: Date?) -> String {
        guard let date else { return "Sin iniciar" }
        let f = DateFormatter(); f.locale = Locale(identifier: "es")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: date)
    }

    @MainActor private func reload() async { page = 1; await fetch(replacing: true) }
    @MainActor private func loadMore() async { page += 1; await fetch(replacing: false) }

    @MainActor
    private func fetch(replacing: Bool) async {
        isLoading = true; defer { isLoading = false; loaded = true }
        do {
            let result = try await dispatch.closedRoutes(page: page)
            total = result.total
            if replacing { routes = result.routes } else { routes.append(contentsOf: result.routes) }
            loadError = nil
        } catch {
            loadError = (error as? APIError)?.serverMessage ?? "No se pudo cargar el historial."
        }
    }
}

/// Detalle de una ruta cerrada: el MISMO `RouteSummary` que el cierre, renderizado con la MISMA vista.
struct RouteHistoryDetailView: View {
    @EnvironmentObject private var dispatch: DispatchService
    let entry: ClosedRouteEntry

    @State private var summary: RouteSummary?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Form {
            Section {
                LabeledContentCompat("Camión", entry.displayName)   // nombre ACTUAL (vista viva)
                LabeledContentCompat("Jornada", RouteHistoryView.dayLabel(entry.routeDate))
            }
            if let s = summary {
                Section("Resumen") { RouteSummaryView(summary: s) }
            } else if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if let err = loadError {
                Section { Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayModeInlineCompat()
        .task { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true; defer { isLoading = false }
        do { summary = try await dispatch.routeDetail(truckID: entry.truckID); loadError = nil }
        catch { loadError = (error as? APIError)?.serverMessage ?? "No se pudo cargar el detalle de la ruta." }
    }
}

/// `LabeledContent` no existe antes de iOS 16; envoltura simple.
private struct LabeledContentCompat: View {
    let label: String; let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }
    }
}
