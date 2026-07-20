import SwiftUI

/// Enruta entre login y la app según el estado de sesión.
/// Es la vista raíz que se muestra en la ventana.
struct AuthGate: View {
    @EnvironmentObject private var environment: AppEnvironment
    // Observa `auth` DIRECTAMENTE: es un ObservableObject anidado en AppEnvironment,
    // así que sus cambios (state → signedIn) no llegarían vía `environment` solo.
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        Group {
            switch auth.state {
            case .unknown:
                ProgressView()
            case .signedOut:
                LoginView()
            case .signedIn:
                RootView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if !network.isOnline { OfflineBanner() }
            }
        }
        .task { auth.restore() }
    }
}
