import Foundation

/// Coders JSON compartidos para hablar con el middleware.
///
/// Fechas en ISO-8601 (contrato `format: date-time`). Se aceptan con y sin fracción
/// de segundo, porque distintos backends serializan de una u otra forma.
enum JSONCoding {

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            // date-time (con/sin fracción) y, como fallback, `format: date` (solo fecha,
            // p. ej. doc_date/due_date del estado de cuenta v0.4.0).
            if let date = iso8601WithFraction.date(from: raw)
                ?? iso8601Plain.date(from: raw)
                ?? dateOnly.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: d.codingPath, debugDescription: "Fecha inválida: \(raw)")
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, e in
            var container = e.singleValueContainer()
            try container.encode(iso8601WithFraction.string(from: date))
        }
        return encoder
    }()

    /// Formatea/parsea una fecha en ISO-8601 con la zona por defecto (formato del contrato).
    static func iso8601String(_ date: Date) -> String {
        iso8601WithFraction.string(from: date)
    }

    /// `ISO8601DateFormatter`, una vez configurado, es seguro para uso concurrente de
    /// solo-lectura (`date(from:)` / `string(from:)`). Se envuelve para declararlo Sendable.
    private struct ISO8601: @unchecked Sendable {
        private let formatter: ISO8601DateFormatter
        init(_ options: ISO8601DateFormatter.Options) {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            formatter = f
        }
        func date(from string: String) -> Date? { formatter.date(from: string) }
        func string(from date: Date) -> String { formatter.string(from: date) }
    }

    private static let iso8601WithFraction = ISO8601([.withInternetDateTime, .withFractionalSeconds])
    private static let iso8601Plain = ISO8601([.withInternetDateTime])

    /// `format: date` del contrato (solo fecha, sin hora). Locale POSIX y UTC fijos para
    /// un parseo estable. Devuelve medianoche UTC; se usa para mostrar y ordenar.
    private struct DateOnly: @unchecked Sendable {
        private let formatter: DateFormatter
        init() {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            formatter = f
        }
        func date(from string: String) -> Date? { formatter.date(from: string) }
    }
    private static let dateOnly = DateOnly()
}
