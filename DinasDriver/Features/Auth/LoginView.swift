import SwiftUI

/// Pantalla de login por usuario/contraseña contra `POST /auth/login`.
/// Al autenticar, el JWT se guarda en Keychain (vía `AuthSession`).
struct LoginView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var network: NetworkMonitor

    @State private var username = ""
    @State private var password = ""

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !auth.isAuthenticating
    }

    var body: some View {
        NavigationStack {
            Form {
                // ★ Logo de la app (solo en el login). Asset ADAPTATIVO: la variante de color en
                // modo claro y la blanca en modo oscuro — el login sigue al sistema, así que un solo
                // archivo se perdería en un modo. Fondo de fila transparente para que asiente sobre
                // el fondo del sistema y contraste en ambos. Derivado de DinasApp.png / _blanco.png.
                Section {
                    HStack {
                        Spacer()
                        Image("DinasLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 88)
                            .accessibilityLabel("Dinas App")
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)

                Section("Acceso") {
                    TextField("Usuario", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    SecureField("Contraseña", text: $password)
                        .textContentType(.password)
                }

                if let error = auth.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        Task {
                            await auth.login(username: username, password: password,
                                             isOnline: network.isOnline)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if auth.isAuthenticating {
                                ProgressView()
                            } else {
                                Text("Iniciar sesión")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Dinas — Driver")
        }
    }
}
