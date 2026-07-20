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
