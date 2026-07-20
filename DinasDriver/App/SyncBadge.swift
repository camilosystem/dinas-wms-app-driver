import SwiftUI

/// Indicador DISCRETO de sincronización (sin alarmismo). Al día = check tenue; con pendientes
/// = conteo ámbar. Le dice al driver si algo quedó sin enviar, sin asustarlo.
struct SyncBadge: View {
    @EnvironmentObject private var dispatch: DispatchService
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        Group {
            if dispatch.pendingCount > 0 {
                Label("\(dispatch.pendingCount) sin enviar", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if !network.isOnline {
                Label("Sin señal", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Al día", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
