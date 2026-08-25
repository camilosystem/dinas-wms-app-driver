import Foundation

/// Formato compacto para la calle (números legibles, sin ruido).
enum Fmt {
    static func qty(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
    static func money(_ v: Double) -> String {
        "$" + String(format: "%.2f", v)
    }

    /// Fecha y hora corta, en la zona del dispositivo (para mostrar un instante concreto).
    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
