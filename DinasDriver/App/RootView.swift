import SwiftUI

/// Raíz de la app tras iniciar sesión: la pantalla "Mi ruta" del driver.
/// Un solo flujo (no pestañas): ruta → parada → pedido → terminar.
struct RootView: View {
    var body: some View {
        MyRouteView()
    }
}
