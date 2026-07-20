import Foundation

/// Formato compacto para la calle (números legibles, sin ruido).
enum Fmt {
    static func qty(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
    static func money(_ v: Double) -> String {
        "$" + String(format: "%.2f", v)
    }
}
