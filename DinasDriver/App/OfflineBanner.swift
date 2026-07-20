import SwiftUI

/// Franja que avisa que no hay conexión con el middleware. La app es offline-first: el
/// vendedor puede seguir trabajando; esto solo informa que la sincronización está en pausa.
///
/// Incluye "Reintentar": fuerza un sondeo de alcance en cualquier momento (respaldo cuando
/// el middleware volvió pero la red del dispositivo no cambió, así que el auto no dispara).
struct OfflineBanner: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text(network.isChecking
                 ? "Reintentando conexión…"
                 : "Sin conexión — trabajando offline")
            Spacer()
            Button {
                Task { await network.retry() }
            } label: {
                if network.isChecking {
                    ProgressView().tint(.white)
                } else {
                    Text("Reintentar").fontWeight(.semibold)
                }
            }
            .disabled(network.isChecking)
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(0.22))
            .clipShape(Capsule())
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange)
    }
}
