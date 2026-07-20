import SwiftUI

/// Búsqueda en el catálogo descargado (offline), por código o nombre. Al elegir un ítem, se
/// agrega al retorno (cantidad y motivo se ajustan en la pantalla principal).
struct ItemSearchView: View {
    let search: (String) -> [CatalogItem]
    let onSelect: (CatalogItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var results: [CatalogItem] { search(query) }

    var body: some View {
        NavigationStack {
            List(results) { item in
                Button {
                    onSelect(item)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.itemName).font(.body).foregroundStyle(.primary)
                        Text(item.itemCode).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableViewCompat(
                        title: query.isEmpty ? "Busca un ítem" : "Sin resultados",
                        message: "Escribe el código o el nombre del producto.",
                        systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Código o nombre")
            .autocorrectionDisabled()
            .navigationTitle("Agregar ítem")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
